#!/bin/bash
# =============================================================================
# samba-setup.sh — Preparación del host para srv-files-01
# =============================================================================
#
# DESCRIPCIÓN:
#   Prepara el host para el contenedor srv-files-01 (Samba):
#     1. Crea el grupo g_files y el usuario Samba en el host (mismos UID/GID
#        que dentro del contenedor, necesario para que los bind mounts funcionen)
#     2. Aplica permisos correctos sobre /mnt/uv_files (el LV montado por
#        setup_lvm.sh, que es el bind mount real del compose)
#     3. Aplica contexto SELinux/container si está disponible
#
# PREREQUISITO:
#   setup_lvm.sh debe haberse ejecutado antes — /mnt/uv_files debe estar montado.
#
# USO:
#   sudo bash scripts/samba-setup.sh
#
# =============================================================================

set -euo pipefail

log()  { echo -e "\e[32m[$(date '+%H:%M:%S')][INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[$(date '+%H:%M:%S')][WARN]\e[0m $*"; }
err()  { echo -e "\e[31m[$(date '+%H:%M:%S')][ERR ]\e[0m $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Verificar root
# -----------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || err "Ejecutar con sudo: sudo bash $0"

# -----------------------------------------------------------------------------
# Cargar variables desde .env
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_ROOT}/docker/.env"

[ -f "${ENV_FILE}" ] || err "Archivo .env no encontrado en ${ENV_FILE}"

set -a
source "${ENV_FILE}"
set +a

# -----------------------------------------------------------------------------
# Configuración — valores con fallback explícito
# -----------------------------------------------------------------------------
SAMBA_GROUP="g_files"
SAMBA_GID="${SAMBA_GID:-1050}"
SAMBA_UID="${SAMBA_UID:-1050}"
SAMBA_USER="${SAMBA_USER:?La variable SAMBA_USER no está definida en .env}"

# El directorio compartido en el HOST es el punto de montaje del LV,
# que es el bind mount que docker-compose pasa al contenedor como /srv/uv_docs.
# NO es un directorio local del repositorio.
SHARE_DIR="/mnt/uv_files"

log "=== Preparando host para Samba (srv-files-01) ==="
log "SHARE_DIR  : ${SHARE_DIR}"
log "SAMBA_USER : ${SAMBA_USER} (UID ${SAMBA_UID})"
log "SAMBA_GROUP: ${SAMBA_GROUP} (GID ${SAMBA_GID})"

# -----------------------------------------------------------------------------
# Verificar prerequisito: /mnt/uv_files debe estar montado (LVM)
# -----------------------------------------------------------------------------
if ! mountpoint -q "${SHARE_DIR}" 2>/dev/null; then
    err "${SHARE_DIR} no está montado.
  Ejecuta primero:
    sudo bash scripts/storage/setup_raid.sh /dev/sdb /dev/sdc
    sudo bash scripts/storage/setup_lvm.sh"
fi
log "Prerequisito OK: ${SHARE_DIR} está montado."

# -----------------------------------------------------------------------------
# Grupo g_files
# -----------------------------------------------------------------------------
if getent group "${SAMBA_GROUP}" >/dev/null 2>&1; then
    EXISTING_GID=$(getent group "${SAMBA_GROUP}" | cut -d: -f3)
    if [ "${EXISTING_GID}" != "${SAMBA_GID}" ]; then
        err "El grupo ${SAMBA_GROUP} existe con GID ${EXISTING_GID} pero .env define GID ${SAMBA_GID}.
  Corrige SAMBA_GID en docker/.env o elimina el grupo: sudo groupdel ${SAMBA_GROUP}"
    fi
    warn "Grupo ${SAMBA_GROUP} (GID ${SAMBA_GID}) ya existe — omitiendo creación."
else
    groupadd -g "${SAMBA_GID}" "${SAMBA_GROUP}"
    log "Grupo ${SAMBA_GROUP} creado con GID ${SAMBA_GID}."
fi

# -----------------------------------------------------------------------------
# Usuario Samba (sin shell de login, sin home)
# -----------------------------------------------------------------------------
if id "${SAMBA_USER}" >/dev/null 2>&1; then
    EXISTING_UID=$(id -u "${SAMBA_USER}")
    if [ "${EXISTING_UID}" != "${SAMBA_UID}" ]; then
        err "El usuario ${SAMBA_USER} existe con UID ${EXISTING_UID} pero .env define UID ${SAMBA_UID}.
  Corrige SAMBA_UID en docker/.env o elimina el usuario: sudo userdel ${SAMBA_USER}"
    fi
    warn "Usuario ${SAMBA_USER} (UID ${SAMBA_UID}) ya existe — omitiendo creación."
else
    useradd \
        -u "${SAMBA_UID}" \
        -g "${SAMBA_GROUP}" \
        -s /usr/sbin/nologin \
        -M \
        -c "Samba Service User — srv-files-01" \
        "${SAMBA_USER}"
    log "Usuario ${SAMBA_USER} creado con UID ${SAMBA_UID}."
fi

# -----------------------------------------------------------------------------
# Permisos sobre /mnt/uv_files (el LV real que usa docker-compose)
#   - propietario: root:g_files
#   - SETGID (2770): los archivos nuevos heredan el grupo g_files
#   - sticky bit incluido en 2770 se aplica aparte para proteger borrados
# -----------------------------------------------------------------------------
log "Aplicando permisos sobre ${SHARE_DIR}..."
chown root:"${SAMBA_GROUP}" "${SHARE_DIR}"
chmod 2770 "${SHARE_DIR}"
log "Permisos aplicados: root:${SAMBA_GROUP} 2770 (SETGID)."

# Sticky bit separado — solo el propietario puede borrar sus archivos
chmod +t "${SHARE_DIR}"
log "Sticky bit aplicado sobre ${SHARE_DIR}."

# -----------------------------------------------------------------------------
# Contexto SELinux / container_file_t
# Necesario en Fedora/RHEL; en Debian/Ubuntu suele ser no-op pero no falla
# -----------------------------------------------------------------------------
if command -v chcon >/dev/null 2>&1; then
    chcon -Rt container_file_t "${SHARE_DIR}" 2>/dev/null \
        && log "Contexto SELinux aplicado: container_file_t" \
        || warn "chcon disponible pero no aplicó (SELinux puede estar desactivado)."
else
    warn "chcon no disponible — SELinux no configurado (normal en Debian/Ubuntu/Mint)."
fi

# -----------------------------------------------------------------------------
# Verificación Podman
# -----------------------------------------------------------------------------
if command -v podman >/dev/null 2>&1; then
    log "Podman detectado: $(podman --version)"
else
    warn "Podman no encontrado — instálalo antes de levantar el stack."
fi

# -----------------------------------------------------------------------------
# Resumen final
# -----------------------------------------------------------------------------
log ""
log "=== Configuración completada ==="
log ""
log "Directorio compartido (host → contenedor):"
log "  ${SHARE_DIR}  →  /srv/uv_docs (dentro de srv-files-01)"
log ""
ls -ldZ "${SHARE_DIR}" 2>/dev/null || ls -ld "${SHARE_DIR}"
log ""
log "=== Siguiente paso ==="
log "  cd ${PROJECT_ROOT}/docker && sudo podman-compose up -d --build srv-files-01"