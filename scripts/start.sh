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
# Argumento opcional --build
# -----------------------------------------------------------------------------
BUILD_FLAG=""
if [[ "${1:-}" == "--build" ]]; then
    BUILD_FLAG="--build"
    log "Modo rebuild activado."
fi

# -----------------------------------------------------------------------------
# 1. Levantar servicios base (sin DHCP primero para evitar timing issues)
# -----------------------------------------------------------------------------
log "Levantando servicios base..."
cd "${DOCKER_DIR}"
podman-compose up -d ${BUILD_FLAG} \
    srv-ntp-01 \
    srv-db-01 \
    srv-files-01 \
    srv-smtp-01 \
    srv-php-fpm \
    srv-dns-01

# -----------------------------------------------------------------------------
# 2. Levantar pila de monitoreo (antes que el proxy porque depende de Grafana)
# -----------------------------------------------------------------------------
log "Levantando pila de monitoreo..."
podman-compose up -d ${BUILD_FLAG} \
    srv-cadvisor-01 \
    srv-prometheus-01 \
    srv-grafana-01

# -----------------------------------------------------------------------------
# 3. Levantar servidores web y proxy (dependen de la pila de monitoreo)
# -----------------------------------------------------------------------------
log "Levantando servidores web y proxy..."
podman-compose up -d ${BUILD_FLAG} \
    srv-web-01 \
    srv-web-02 \
    srv-web-03 \
    srv-proxy-01

# -----------------------------------------------------------------------------
# 4. Levantar srv-dhcp-01 en VLAN 10
# -----------------------------------------------------------------------------
log "Levantando srv-dhcp-01..."
podman-compose up -d ${BUILD_FLAG} srv-dhcp-01

# -----------------------------------------------------------------------------
# 5. Conectar srv-dhcp-01 a VLAN 20 y VLAN 30
#    (necesario porque podman-compose no soporta --ip con múltiples redes)
# -----------------------------------------------------------------------------
log "Conectando srv-dhcp-01 a vlan20 y vlan30..."

# Crear redes si no existen (podman-compose no las crea si no están en uso)
if ! podman network inspect vlan20_administracion --format '{{.Name}}' >/dev/null 2>&1; then
    log "Creando red vlan20_administracion..."
    podman network create --driver bridge --subnet 10.0.20.0/24 --gateway 10.0.20.1 vlan20_administracion
fi

if ! podman network inspect vlan30_usuarios --format '{{.Name}}' >/dev/null 2>&1; then
    log "Creando red vlan30_usuarios..."
    podman network create --driver bridge --subnet 10.0.30.0/24 --gateway 10.0.30.1 vlan30_usuarios
fi

# Conectar solo si no está ya conectado
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
# 6. Esperar a que los servicios estén healthy (máx. 120s)
# -----------------------------------------------------------------------------
log "Esperando que los servicios estén healthy (máx. 120s)..."

SERVICES=("srv-ntp-01" "srv-db-01" "srv-files-01" "srv-smtp-01" "srv-dhcp-01" "srv-php-fpm" "srv-cadvisor-01" "srv-prometheus-01" "srv-grafana-01" "srv-web-01" "srv-web-02" "srv-web-03" "srv-proxy-01" "srv-dns-01")
TIMEOUT=120
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    ALL_HEALTHY=true
    for svc in "${SERVICES[@]}"; do
        STATUS=$(podman inspect "${svc}" --format '{{.State.Health.Status}}' 2>/dev/null || echo "missing")
        if [[ "$STATUS" != "healthy" ]]; then
            ALL_HEALTHY=false
            break
        fi
    done
    if $ALL_HEALTHY; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

# -----------------------------------------------------------------------------
# 7. Estado final
# -----------------------------------------------------------------------------
echo ""
log "=== Estado del stack ==="
podman ps --filter "label=io.podman.compose.project=docker" \
    --format "table {{.Names}}\t{{.Status}}"
echo ""

if $ALL_HEALTHY; then
    log "✅ Todos los servicios están healthy."
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
else
    warn "Algunos servicios aún no están healthy. Verifica con:"
    warn "  podman ps -a"
    warn "  podman logs <contenedor>"
fi
