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
    srv-smtp-01

# -----------------------------------------------------------------------------
# 2. Levantar srv-dhcp-01 en VLAN 10
# -----------------------------------------------------------------------------
log "Levantando srv-dhcp-01..."
podman-compose up -d ${BUILD_FLAG} srv-dhcp-01

# -----------------------------------------------------------------------------
# 3. Conectar srv-dhcp-01 a VLAN 20 y VLAN 30
#    (necesario porque podman-compose no soporta --ip con múltiples redes)
# -----------------------------------------------------------------------------
log "Conectando srv-dhcp-01 a vlan20 y vlan30..."

if ! podman network inspect vlan20_administracion --format '{{.Name}}' >/dev/null 2>&1; then
    warn "Red vlan20_administracion no existe — será creada por podman-compose."
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
# 4. Esperar a que los servicios estén healthy
# -----------------------------------------------------------------------------
log "Esperando que los servicios estén healthy (máx. 90s)..."

SERVICES=("srv-ntp-01" "srv-db-01" "srv-files-01" "srv-smtp-01" "srv-dhcp-01")
TIMEOUT=90
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
# 5. Estado final
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
    log "MailHog UI    → http://localhost:8025 (solo desde VLAN 20)"
else
    warn "Algunos servicios aún no están healthy. Verifica con:"
    warn "  podman ps -a"
    warn "  podman logs <contenedor>"
fi