#!/bin/bash
# =============================================================================
# samba-setup.sh — Preparación del host para srv-files-01
# =============================================================================

set -euo pipefail

log()  { echo -e "\e[32m[$(date '+%H:%M:%S')][INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[$(date '+%H:%M:%S')][WARN]\e[0m $*"; }
err()  { echo -e "\e[31m[$(date '+%H:%M:%S')][ERR ]\e[0m $*" >&2; exit 1; }
# -----------------------------------------------------------------------------
# Cargar variables desde .env
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

ENV_FILE="${PROJECT_ROOT}/docker/.env"

if [ -f "${ENV_FILE}" ]; then
    set -a
    source "${ENV_FILE}"
    set +a
else
    err "Archivo .env no encontrado en ${ENV_FILE}"
fi

# -----------------------------------------------------------------------------
# Configuración
# -----------------------------------------------------------------------------
SAMBA_GID="${SAMBA_GID}"
SAMBA_UID="${SAMBA_UID}"
SAMBA_GROUP="g_files"
SAMBA_USER="${SAMBA_USER}"
# -----------------------------------------------------------------------------
# Directorio compartido
# -----------------------------------------------------------------------------
SHARE_DIR="${PROJECT_ROOT}/data/files"
log "Creando directorio ${SHARE_DIR}..."

mkdir -p "${SHARE_DIR}"

chmod 755 "${PROJECT_ROOT}"
chmod 755 "${PROJECT_ROOT}/data"

chown root:"${SAMBA_GROUP}" "${SHARE_DIR}"

chmod 2770 "${SHARE_DIR}"

log "Permisos aplicados."
# -----------------------------------------------------------------------------
# Verificar root
# -----------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || err "Ejecutar con sudo."

log "=== Preparando host para Samba ==="

# -----------------------------------------------------------------------------
# Grupo
# -----------------------------------------------------------------------------
if getent group "${SAMBA_GROUP}" >/dev/null 2>&1; then
    warn "Grupo ${SAMBA_GROUP} ya existe."
else
    groupadd -g "${SAMBA_GID}" "${SAMBA_GROUP}"
    log "Grupo ${SAMBA_GROUP} creado."
fi

# -----------------------------------------------------------------------------
# Usuario
# -----------------------------------------------------------------------------
if id "${SAMBA_USER}" >/dev/null 2>&1; then
    warn "Usuario ${SAMBA_USER} ya existe."
else
    useradd \
        -u "${SAMBA_UID}" \
        -g "${SAMBA_GROUP}" \
        -s /sbin/nologin \
        -c "Samba Service User" \
        "${SAMBA_USER}"

    log "Usuario ${SAMBA_USER} creado."
fi

# -----------------------------------------------------------------------------
# Directorio compartido
# -----------------------------------------------------------------------------
log "Creando directorio ${SHARE_DIR}..."

mkdir -p "${SHARE_DIR}"

# root propietario, grupo compartido
chown root:"${SAMBA_GROUP}" "${SHARE_DIR}"

# SETGID para heredar grupo
chmod 2770 "${SHARE_DIR}"

log "Permisos aplicados."

# -----------------------------------------------------------------------------
# SELinux
# -----------------------------------------------------------------------------
if command -v chcon >/dev/null 2>&1; then
    log "Aplicando contexto SELinux para contenedores..."

    chcon -Rt container_file_t "${SHARE_DIR}"

    log "SELinux configurado."
else
    warn "chcon no disponible."
fi

# -----------------------------------------------------------------------------
# Verificación Podman
# -----------------------------------------------------------------------------
if command -v podman >/dev/null 2>&1; then
    log "Podman detectado: $(podman --version)"
else
    warn "Podman no encontrado."
fi

log ""
log "=== Configuración completada ==="
log ""

ls -ldZ "${SHARE_DIR}"

log "=== Siguiente paso ==="
log "cd ${PROJECT_ROOT}/docker && podman-compose up -d --build"