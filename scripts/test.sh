#!/bin/bash
# =============================================================================
# test.sh — Verificación del stack uv-infra-ti
# Pruebas de DNS, conectividad, health-checks y servicios
# =============================================================================
# Uso:
#   bash scripts/test.sh          # ejecutar todas las pruebas
#   bash scripts/test.sh --dns    # solo pruebas DNS
#   bash scripts/test.sh --web    # solo pruebas web
# =============================================================================

set -euo pipefail

log()   { echo -e "\e[32m[TEST][PASS]\e[0m $*"; }
fail()  { echo -e "\e[31m[TEST][FAIL]\e[0m $*" >&2; }
warn()  { echo -e "\e[33m[TEST][WARN]\e[0m $*"; }
info()  { echo -e "\e[34m[TEST][INFO]\e[0m $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="${PROJECT_ROOT}/docker"

# --- Verificaciones previas --------------------------------------------------
command -v podman >/dev/null 2>&1 || { fail "podman no está instalado."; exit 1; }

# --- Helpers -----------------------------------------------------------------
container_ip() {
    podman inspect "$1" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo ""
}

dns_query() {
    local host="$1"
    # Usamos un contenedor efímero (busybox) dentro de la red vlan40 para consultar al DNS
    # (el host no tiene acceso directo a la IP interna del contenedor DNS en rootless mode)
    local output
    output=$(podman run --rm --network vlan40_dmz busybox nslookup "$host" srv-dns-01 2>&1)
    if echo "$output" | grep -qE "can't find|NXDOMAIN|REFUSED|SERVFAIL"; then
        echo ""
    else
        echo "$output" | awk '/Name:/{getline; if($1=="Address:") print $2}'
    fi
}

http_test() {
    local url="$1"
    local expected="${2:-200}"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
    if [[ "$code" == "$expected" ]]; then
        log "HTTP $code → $url"
        return 0
    else
        fail "HTTP $code (esperado $expected) → $url"
        return 1
    fi
}

# --- 1. Estado de contenedores -----------------------------------------------
test_containers() {
    info "=== Estado de contenedores ==="
    local services=(srv-ntp-01 srv-db-01 srv-files-01 srv-smtp-01 srv-dhcp-01 srv-php-fpm srv-web-01 srv-web-02 srv-web-03 srv-proxy-01 srv-dns-01)
    local all_ok=true
    for svc in "${services[@]}"; do
        if podman ps --format '{{.Names}}' | grep -q "^${svc}$"; then
            local status
            status=$(podman inspect "$svc" --format '{{.State.Status}}' 2>/dev/null)
            local health
            health=$(podman inspect "$svc" --format '{{.State.Health.Status}}' 2>/dev/null || echo "N/A")
            if [[ "$status" == "running" ]]; then
                log "$svc → running (health: $health)"
            else
                fail "$svc → $status"
                all_ok=false
            fi
        else
            fail "$svc → no está corriendo"
            all_ok=false
        fi
    done
    $all_ok
}

# --- 2. Pruebas DNS ----------------------------------------------------------
test_dns() {
    info "=== Pruebas DNS (srv-dns-01) ==="
    local dns_ip
    dns_ip=$(container_ip srv-dns-01)
    if [[ -z "$dns_ip" ]]; then
        fail "No se pudo obtener la IP de srv-dns-01"
        return 1
    fi
    info "DNS server IP: $dns_ip"

    # Verificar que named responde
    if ! podman exec srv-dns-01 sh -c "pgrep named >/dev/null" 2>/dev/null; then
        fail "Proceso named no está corriendo en srv-dns-01"
        return 1
    fi
    log "Proceso named corriendo"

    # Zona uv.local
    local tests_uvlocal=(
        "srv-web-01.uv.local:10.0.40.2"
        "srv-web-02.uv.local:10.0.40.5"
        "srv-web-03.uv.local:10.0.10.5"
        "srv-db-01.uv.local:10.0.10.2"
        "srv-files-01.uv.local:10.0.10.3"
        "srv-dns-01.uv.local:10.0.40.3"
        "srv-proxy-01.uv.local:10.0.40.6"
    )
    for t in "${tests_uvlocal[@]}"; do
        local host="${t%%:*}"
        local expected="${t##*:}"
        local result
        result=$(dns_query "$host")
        if [[ "$result" == "$expected" ]]; then
            log "DNS $host → $result"
        else
            fail "DNS $host → '$result' (esperado $expected)"
        fi
    done

    # Zona unidadvictimas.co (nueva configuración)
    local tests_public=(
        "unidadvictimas.co:10.0.40.2"
        "proxy.unidadvictimas.co:10.0.40.6"
        "rni.unidadvictimas.co:10.0.40.5"
        "internal.unidadvictimas.co:10.0.10.5"
    )
    for t in "${tests_public[@]}"; do
        local host="${t%%:*}"
        local expected="${t##*:}"
        local result
        result=$(dns_query "$host")
        if [[ "$result" == "$expected" ]]; then
            log "DNS $host → $result"
        else
            fail "DNS $host → '$result' (esperado $expected)"
        fi
    done
}

# --- 3. Conectividad de red --------------------------------------------------
test_network() {
    info "=== Pruebas de conectividad de red ==="
    # Desde srv-web-01 (VLAN 10 y 40) hacia srv-db-01 (VLAN 10)
    if podman exec srv-web-01 ping -c 2 -W 2 10.0.10.2 >/dev/null 2>&1; then
        log "srv-web-01 → srv-db-01 (10.0.10.2) OK"
    else
        fail "srv-web-01 → srv-db-01 (10.0.10.2) FAIL"
    fi

    # Desde srv-web-01 hacia srv-files-01 (VLAN 10)
    if podman exec srv-web-01 ping -c 2 -W 2 10.0.10.3 >/dev/null 2>&1; then
        log "srv-web-01 → srv-files-01 (10.0.10.3) OK"
    else
        fail "srv-web-01 → srv-files-01 (10.0.10.3) FAIL"
    fi

    # Desde srv-proxy-01 (VLAN 10 y 40) hacia srv-web-01 (VLAN 40)
    # srv-proxy-01 (nginx:alpine) no tiene ping; usamos curl al puerto 80
    if podman exec srv-proxy-01 curl -sf --max-time 2 http://10.0.40.2 >/dev/null 2>&1; then
        log "srv-proxy-01 → srv-web-01 (10.0.40.2:80) OK"
    else
        fail "srv-proxy-01 → srv-web-01 (10.0.40.2) FAIL"
    fi

    # Desde srv-dns-01 (VLAN 40) hacia srv-smtp-01 (VLAN 40)
    # srv-dns-01 (ubuntu/bind9) no tiene ping ni curl; usamos bash /dev/tcp
    if podman exec srv-dns-01 bash -c "timeout 2 bash -c 'echo > /dev/tcp/10.0.40.4/8025'" >/dev/null 2>&1; then
        log "srv-dns-01 → srv-smtp-01 (10.0.40.4:8025) OK"
    else
        fail "srv-dns-01 → srv-smtp-01 (10.0.40.4) FAIL"
    fi
}

# --- 4. Pruebas de servicios HTTP -------------------------------------------
test_web() {
    info "=== Pruebas HTTP ==="
    http_test "http://localhost:8082" "200" || true
    http_test "http://localhost:8083" "200" || true
    # Proxy/NPM
    http_test "http://localhost:8080" "200" || true
    # MailHog UI
    http_test "http://localhost:8025" "200" || true
    # NPM Admin
    http_test "http://localhost:8081" "200" || true
}

# --- 5. Pruebas de base de datos ---------------------------------------------
test_db() {
    info "=== Pruebas de Base de Datos ==="
    if podman exec srv-db-01 pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" >/dev/null 2>&1; then
        log "PostgreSQL está aceptando conexiones"
    else
        fail "PostgreSQL no responde a pg_isready"
    fi
}

# --- 6. Pruebas SSH ----------------------------------------------------------
test_ssh() {
    info "=== Pruebas SSH ==="
    # Solo verificar que el puerto está abierto, no hacer login
    if timeout 2 bash -c "echo >/dev/tcp/localhost/2222" 2>/dev/null; then
        log "Puerto SSH 2222 (srv-db-01) abierto"
    else
        warn "Puerto SSH 2222 (srv-db-01) no accesible"
    fi

    if timeout 2 bash -c "echo >/dev/tcp/localhost/2223" 2>/dev/null; then
        log "Puerto SSH 2223 (srv-files-01) abierto"
    else
        warn "Puerto SSH 2223 (srv-files-01) no accesible"
    fi
}

# --- 7. Pruebas Samba --------------------------------------------------------
test_samba() {
    info "=== Pruebas Samba ==="
    if podman exec srv-files-01 smbclient -L \\localhost -U "%" -N >/dev/null 2>&1 || \
       podman exec srv-files-01 testparm -s /etc/samba/smb.conf >/dev/null 2>&1; then
        log "Servicio Samba responde"
    else
        warn "No se pudo verificar Samba"
    fi
}

# --- 8. Pruebas SMTP ---------------------------------------------------------
test_smtp() {
    info "=== Pruebas SMTP ==="
    if timeout 3 bash -c "echo >/dev/tcp/localhost/1025" 2>/dev/null; then
        log "Puerto SMTP 1025 (srv-smtp-01) abierto"
    else
        warn "Puerto SMTP 1025 no accesible"
    fi
}

# --- 9. Pruebas NTP ----------------------------------------------------------
test_ntp() {
    info "=== Pruebas NTP ==="
    if podman exec srv-ntp-01 chronyc tracking >/dev/null 2>&1; then
        log "chronyd responde en srv-ntp-01"
    else
        warn "chronyd no responde"
    fi
}

# --- 10. Pruebas DHCP --------------------------------------------------------
test_dhcp() {
    info "=== Pruebas DHCP ==="
    if podman exec srv-dhcp-01 pgrep dhcpd >/dev/null 2>&1; then
        log "dhcpd corriendo en srv-dhcp-01"
    else
        warn "dhcpd no está corriendo"
    fi
}

# --- Ejecución principal -----------------------------------------------------
main() {
    echo ""
    info "========================================"
    info "Iniciando pruebas de infraestructura..."
    info "========================================"
    echo ""

    local mode="${1:-all}"

    case "$mode" in
        --dns)
            test_dns
            ;;
        --web)
            test_web
            ;;
        --network)
            test_network
            ;;
        all|*)
            test_containers || true
            test_dns || true
            test_network || true
            test_web || true
            test_db || true
            test_ssh || true
            test_samba || true
            test_smtp || true
            test_ntp || true
            test_dhcp || true
            ;;
    esac

    echo ""
    info "========================================"
    info "Pruebas finalizadas."
    info "========================================"
    echo ""
    info "Consejo: si las pruebas DNS fallan, reconstruye el contenedor:"
    info "  cd docker && podman-compose up -d --build srv-dns-01"
}

main "$@"
