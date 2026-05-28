#!/bin/bash
# =============================================================================
# start.sh — Levanta el stack completo de uv-infra-ti
# Unidad para la Atención y Reparación Integral a las Víctimas — SIG
# =============================================================================
# Uso:
#   bash scripts/start.sh          # levantar todo
#   bash scripts/start.sh --build  # rebuild de imágenes antes de levantar
# =============================================================================

set -euo pipefail

log()  { echo -e "\e[32m[$(date '+%H:%M:%S')][INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[$(date '+%H:%M:%S')][WARN]\e[0m $*"; }
err()  { echo -e "\e[31m[$(date '+%H:%M:%S')][ERR ]\e[0m $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Directorio raíz del proyecto (dos niveles arriba de scripts/)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="${PROJECT_ROOT}/docker"

# -----------------------------------------------------------------------------
# Verificaciones previas
# -----------------------------------------------------------------------------
command -v podman         >/dev/null 2>&1 || err "podman no está instalado."
command -v podman-compose >/dev/null 2>&1 || err "podman-compose no está instalado."

[ -f "${DOCKER_DIR}/.env" ] || err "Falta docker/.env — pídelo al equipo por WhatsApp."
[ -f "${DOCKER_DIR}/docker-compose.yml" ] || err "No se encontró docker/docker-compose.yml"

# -----------------------------------------------------------------------------
# Verificar / agregar entradas en /etc/hosts
# -----------------------------------------------------------------------------
ETC_HOSTS="/etc/hosts"
REQUIRED_HOSTS=(
    "127.0.0.1   unidadvictimas.corp"
    "127.0.0.1   rni.unidadvictimas.corp"
    "127.0.0.1   intranet.unidadvictimas.corp"
    "127.0.0.1   proxy.unidadvictimas.corp"
)

HOSTS_CHANGED=false
for entry in "${REQUIRED_HOSTS[@]}"; do
    domain=$(echo "$entry" | awk '{print $2}')
    if ! grep -qE "^127\.0\.0\.1[[:space:]]+${domain}\b" "$ETC_HOSTS" 2>/dev/null; then
        if [ "$HOSTS_CHANGED" = false ]; then
            log "Agregando dominios locales a $ETC_HOSTS (requiere sudo)..."
        fi
        echo "$entry" | sudo tee -a "$ETC_HOSTS" >/dev/null
        log "  → $domain"
        HOSTS_CHANGED=true
    fi
done

if [ "$HOSTS_CHANGED" = true ]; then
    log "$ETC_HOSTS actualizado correctamente."
else
    log "Todos los dominios locales ya están presentes en $ETC_HOSTS."
fi

# -----------------------------------------------------------------------------
# Crear directorios de almacenamiento persistente si no existen
# -----------------------------------------------------------------------------
log "Verificando directorios de almacenamiento persistente..."

PERSISTENT_DIRS=(
    "/mnt/uv_db/pgdata"
    "/mnt/uv_files"
)

for dir in "${PERSISTENT_DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        sudo mkdir -p "$dir"
        log "  → Creado $dir"
    else
        log "  → $dir ya existe"
    fi
done

# PostgreSQL exige que el data dir no sea world-readable
sudo chmod 700 /mnt/uv_db/pgdata 2>/dev/null || true
sudo chmod 755 /mnt/uv_files 2>/dev/null || true

# -----------------------------------------------------------------------------
# Argumento opcional --build
# -----------------------------------------------------------------------------
BUILD_FLAG=""
if [[ "${1:-}" == "--build" ]]; then
    BUILD_FLAG="--build"
    log "Modo rebuild activado."
fi

# -----------------------------------------------------------------------------
# 0. Idempotencia: limpiar contenedores previos
# -----------------------------------------------------------------------------
log "Asegurando estado limpio..."
cd "${DOCKER_DIR}"
podman-compose down --remove-orphans 2>/dev/null || true
log "Estado limpio confirmado."

# -----------------------------------------------------------------------------
# Helper: esperar a que una lista de servicios esté healthy
# -----------------------------------------------------------------------------
wait_for_healthy() {
    local label="$1"
    shift
    local svcs=("$@")
    local timeout=120
    local elapsed=0

    log "[$label] Esperando healthcheck de: ${svcs[*]}"

    while [ $elapsed -lt $timeout ]; do
        local all_ok=true
        for s in "${svcs[@]}"; do
            local st
            st=$(podman inspect "$s" --format '{{.State.Health.Status}}' 2>/dev/null || echo "missing")
            if [[ "$st" != "healthy" ]]; then
                all_ok=false
                break
            fi
        done
        if $all_ok; then
            log "[$label] Healthy"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    err "[$label] Timeout esperando healthcheck de: ${svcs[*]}"
}

# -----------------------------------------------------------------------------
# 1. Levantar servicios base (sin DHCP primero para evitar timing issues)
# -----------------------------------------------------------------------------
log "Levantando servicios base..."
cd "${DOCKER_DIR}"
podman-compose up -d --no-deps ${BUILD_FLAG} \
    srv-dns-01 \
    srv-ntp-01 \
    srv-smtp-01 \
    srv-web-03 \
    srv-dhcp-01

# Conectar srv-dns-01 a vlan10 (no se puede con --ip en múltiples redes)
if ! podman inspect srv-dns-01 --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' | grep -q "vlan10_servidores"; then
    podman network connect --ip 10.0.10.9 vlan10_servidores srv-dns-01
    log "srv-dns-01 conectado a vlan10_servidores (10.0.10.9)."
fi

wait_for_healthy "Tier 0" srv-dns-01 srv-ntp-01

# -----------------------------------------------------------------------------
# 2. Conectar srv-dhcp-01 a VLAN 20 y VLAN 30
# -----------------------------------------------------------------------------
log "Conectando srv-dhcp-01 a vlan20 y vlan30..."

if ! podman network inspect vlan20_administracion --format '{{.Name}}' >/dev/null 2>&1; then
    log "Creando red vlan20_administracion..."
    podman network create --driver bridge --subnet 10.0.20.0/24 --gateway 10.0.20.1 vlan20_administracion
fi

if ! podman network inspect vlan30_usuarios --format '{{.Name}}' >/dev/null 2>&1; then
    log "Creando red vlan30_usuarios..."
    podman network create --driver bridge --subnet 10.0.30.0/24 --gateway 10.0.30.1 vlan30_usuarios
fi

if ! podman inspect srv-dhcp-01 --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' | grep -q "vlan20_administracion"; then
    podman network connect vlan20_administracion srv-dhcp-01
    log "Conectado a vlan20_administracion."
else
    warn "srv-dhcp-01 ya está en vlan20_administracion — omitiendo."
fi

if ! podman inspect srv-dhcp-01 --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' | grep -q "vlan30_usuarios"; then
    podman network connect vlan30_usuarios srv-dhcp-01
    log "Conectado a vlan30_usuarios."
else
    warn "srv-dhcp-01 ya está en vlan30_usuarios — omitiendo."
fi

# -----------------------------------------------------------------------------
# 3. Tier 1 — DB, Files, PHP-FPM, cAdvisor
# -----------------------------------------------------------------------------
log "Tier 1 — Levantando DB, Files, PHP-FPM, cAdvisor..."
podman-compose up -d --no-deps ${BUILD_FLAG} \
    srv-db-01 \
    srv-files-01 \
    srv-php-fpm \
    srv-cadvisor-01

wait_for_healthy "Tier 1" srv-db-01 srv-files-01 srv-php-fpm srv-cadvisor-01

# -----------------------------------------------------------------------------
# 4. Tier 2 — Prometheus, Web-01, Web-02
# -----------------------------------------------------------------------------
log "Tier 2 — Levantando Prometheus y servidores web..."
podman-compose up -d --no-deps ${BUILD_FLAG} \
    srv-prometheus-01 \
    srv-web-01 \
    srv-web-02

wait_for_healthy "Tier 2" srv-prometheus-01 srv-web-01 srv-web-02

# -----------------------------------------------------------------------------
# 5. Tier 3 — Grafana, Proxy
# -----------------------------------------------------------------------------
log "Tier 3 — Levantando Grafana y Proxy..."
podman-compose up -d --no-deps ${BUILD_FLAG} \
    srv-grafana-01 \
    srv-proxy-01

# Conectar srv-proxy-01 a vlan10 (no se puede con --ip en múltiples redes)
if ! podman inspect srv-proxy-01 --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' | grep -q "vlan10_servidores"; then
    podman network connect --ip 10.0.10.10 vlan10_servidores srv-proxy-01
    log "srv-proxy-01 conectado a vlan10_servidores (10.0.10.10)."
fi

wait_for_healthy "Tier 3" srv-grafana-01 srv-proxy-01

# -----------------------------------------------------------------------------
# 6. Verificación final de todo el stack
# -----------------------------------------------------------------------------
log "Verificación final de todo el stack..."
ALL_SERVICES=("srv-ntp-01" "srv-db-01" "srv-files-01" "srv-smtp-01" "srv-dhcp-01" "srv-php-fpm" "srv-cadvisor-01" "srv-prometheus-01" "srv-grafana-01" "srv-web-01" "srv-web-02" "srv-web-03" "srv-proxy-01" "srv-dns-01")
wait_for_healthy "Final" "${ALL_SERVICES[@]}"

# -----------------------------------------------------------------------------
# 7. Estado final
# -----------------------------------------------------------------------------
echo ""
log "=== Estado del stack ==="
podman ps --filter "label=io.podman.compose.project=docker" \
    --format "table {{.Names}}\t{{.Status}}"
echo ""

log "Todos los servicios están healthy."
log ""
log "Acceso SSH:"
log "  srv-db-01    → ssh -p 2222 uv_dbadmin@localhost"
log "  srv-files-01 → ssh -p 2223 uv_admin@localhost"
log ""
log "NPM Admin UI  → http://proxy.unidadvictimas.corp:8081"
log "MailHog UI    → http://localhost:8025 (solo desde VLAN 20)"
log ""
log "Dominios locales:"
log "  http://unidadvictimas.corp      → Portal Ciudadano"
log "  http://rni.unidadvictimas.corp  → RNI"
log "  http://intranet.unidadvictimas.corp  → Intranet SUMA"
log "  http://proxy.unidadvictimas.corp     → NPM Admin Panel"
log ""
log "Nota: en entornos rootless (Podman sin root) los puertos 80/443"
log "      requieren sysctl. Para usar puertos estándar ejecuta:"
log "      sudo sysctl net.ipv4.ip_unprivileged_port_start=80"
log ""
log "Acceso directo srv-web-01 → http://localhost:8082"
