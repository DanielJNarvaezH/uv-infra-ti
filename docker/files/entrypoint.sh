#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [srv-files-01] $*"
}

: "${SAMBA_USER:?Debes definir SAMBA_USER en .env}"
: "${SAMBA_PASSWORD:?Debes definir SAMBA_PASSWORD en .env}"
: "${SAMBA_GROUP:=g_files}"
: "${SAMBA_SHARE_PATH:=/srv/uv_docs}"

# ============================================================
# Sincronización horaria con servidor NTP (opcional)
# ============================================================
log "Sincronizando hora con servidor NTP (10.0.10.4)..."
if command -v ntpdate >/dev/null 2>&1; then
    ntpdate -u 10.0.10.4 2>/dev/null \
        && log "Sincronización exitosa" \
        || log "ADVERTENCIA: No se pudo sincronizar la hora (el servicio continuará)"
else
    log "ADVERTENCIA: ntpdate no está instalado. Se omite sincronización."
fi

log "Preparando share ${SAMBA_SHARE_PATH}..."

mkdir -p "${SAMBA_SHARE_PATH}"
chown root:"${SAMBA_GROUP}" "${SAMBA_SHARE_PATH}"
chmod 2770 "${SAMBA_SHARE_PATH}"

log "Configurando usuario Samba ${SAMBA_USER}..."
if pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "${SAMBA_USER}"; then
  printf '%s\n%s\n' "${SAMBA_PASSWORD}" "${SAMBA_PASSWORD}" | smbpasswd -s "${SAMBA_USER}"
else
  printf '%s\n%s\n' "${SAMBA_PASSWORD}" "${SAMBA_PASSWORD}" | smbpasswd -a -s "${SAMBA_USER}"
fi
smbpasswd -e "${SAMBA_USER}" >/dev/null 2>&1 || true

log "Validando smb.conf..."
testparm -s /etc/samba/smb.conf >/dev/null

log "Iniciando smbd..."
exec smbd --foreground --no-process-group --configfile=/etc/samba/smb.conf