#!/usr/bin/env bash
# =============================================================================
# backup.sh — AUT-1: Backup Automático
# Infraestructura TI — Unidad para la Atención y Reparación Integral a las Víctimas
# Universidad del Quindío — Semestre 2026-1
# =============================================================================
#
# DESCRIPCIÓN:
#   Script de respaldo automático que cubre:
#     1. Dump de PostgreSQL (base de datos uv_sig)
#     2. Compresión de archivos Samba (/mnt/uv_files)
#     3. Configuraciones de servicios (DHCP, DNS, SMTP)
#     4. Limpieza de backups con más de 7 días
#     5. Registro de resultados en log
#
# ─── CONFIGURACIÓN ADAPTABLE ──────────────────────────────────────────────────
# PROJECT_DIR se detecta automáticamente desde la ubicación del script.
# Si necesitas sobreescribirla, expórtala antes de correr:
#   export PROJECT_DIR=/home/TU_USUARIO/ruta/a/uv-infra-ti
#   sudo -E bash scripts/automation/backup.sh
#
# Ejemplos por integrante:
#   Daniel  → /home/daniel/Documents/uv-infra-ti
#   David   → /home/david/uv-infra-ti
#   Juan    → /home/juan/proyectos/uv-infra-ti
# ─────────────────────────────────────────────────────────────────────────────
#
# USO MANUAL:
#   sudo bash scripts/automation/backup.sh
#
# CRON JOB (2:00 AM todos los días):
#   0 2 * * * /RUTA/AL/PROYECTO/scripts/automation/backup.sh >> /var/log/uv_backup.log 2>&1
#
# PREREQUISITOS:
#   - ALM-2 completado: /mnt/uv_logs montado (setup_lvm.sh ejecutado)
#   - Contenedor srv-db-01 corriendo (podman-compose up)
# =============================================================================

set -euo pipefail

# =============================================================================
# RUTA DEL PROYECTO — detección automática, sobreescribible con export
# =============================================================================
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Colores (solo terminal interactiva) ───────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# ── Verificar root ────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERR]${NC}  Ejecutar como root: sudo bash $0" >&2
    exit 1
fi

# ── Configuración ─────────────────────────────────────────────────────────────
FECHA=$(date +%Y%m%d)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

BACKUP_DIR="/mnt/uv_logs/backups"
LOG_FILE="/var/log/uv_backup.log"

PG_CONTAINER="srv-db-01"
PG_DB="uv_sig"
PG_USER="uv_admin"
PG_DUMP="${BACKUP_DIR}/db/backup_${FECHA}.sql"

SAMBA_SRC="/mnt/uv_files"
SAMBA_DUMP="${BACKUP_DIR}/files/samba_${FECHA}.tar.gz"

CONF_DUMP="${BACKUP_DIR}/configs/configs_${FECHA}.tar.gz"

RETENTION_DAYS=7

# ── Funciones de log ──────────────────────────────────────────────────────────
log_msg() {
    local level="$1"; shift
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${ts}] [${level}] $*" >> "${LOG_FILE}"
    case "$level" in
        OK)   echo -e "${GREEN}[OK]${NC}  $*" ;;
        INFO) echo -e "${BLUE}[INFO]${NC} $*" ;;
        WARN) echo -e "${YELLOW}[WARN]${NC} $*" ;;
        ERR)  echo -e "${RED}[ERR]${NC}  $*" ;;
    esac
}
ok()   { log_msg "OK"   "$*"; }
info() { log_msg "INFO" "$*"; }
warn() { log_msg "WARN" "$*"; }
err()  { log_msg "ERR"  "$*"; }

# ── Header en log ─────────────────────────────────────────────────────────────
{
echo ""
echo "========================================================"
echo "  BACKUP UV-SIG — $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Proyecto: ${PROJECT_DIR}"
echo "========================================================"
} >> "${LOG_FILE}"

info "Iniciando backup — ${TIMESTAMP}"
info "PROJECT_DIR = ${PROJECT_DIR}"

# ── Verificar prerequisitos ───────────────────────────────────────────────────
if [[ ! -d "/mnt/uv_logs" ]]; then
    err "/mnt/uv_logs no está montado — ejecuta setup_lvm.sh primero"
    exit 1
fi

if [[ ! -d "${PROJECT_DIR}/docker" ]]; then
    err "PROJECT_DIR incorrecto: ${PROJECT_DIR}"
    err "Ajusta con: export PROJECT_DIR=/ruta/a/uv-infra-ti"
    exit 1
fi

mkdir -p "${BACKUP_DIR}/db" "${BACKUP_DIR}/files" "${BACKUP_DIR}/configs"
ok "Directorios de backup listos en ${BACKUP_DIR}"

# =============================================================================
# 1. DUMP DE POSTGRESQL
# =============================================================================
info "1/4 — Dump de PostgreSQL (${PG_DB})..."

CONTAINER_CMD=""
if command -v podman &>/dev/null && podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^${PG_CONTAINER}$"; then
    CONTAINER_CMD="podman"
elif command -v docker &>/dev/null && docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${PG_CONTAINER}$"; then
    CONTAINER_CMD="docker"
fi

if [[ -n "${CONTAINER_CMD}" ]]; then
    ${CONTAINER_CMD} exec "${PG_CONTAINER}" \
        pg_dump -U "${PG_USER}" "${PG_DB}" > "${PG_DUMP}"
    ok "PostgreSQL dump: ${PG_DUMP} ($(du -sh "${PG_DUMP}" | cut -f1))"
else
    warn "Contenedor ${PG_CONTAINER} no encontrado — saltando backup de BD"
    echo "CONTENEDOR NO DISPONIBLE — ${TIMESTAMP}" > "${PG_DUMP}.skip"
fi

# =============================================================================
# 2. COMPRIMIR ARCHIVOS SAMBA
# =============================================================================
info "2/4 — Comprimiendo archivos Samba (${SAMBA_SRC})..."

if [[ -d "${SAMBA_SRC}" ]]; then
    tar -czf "${SAMBA_DUMP}" \
        -C "$(dirname "${SAMBA_SRC}")" \
        "$(basename "${SAMBA_SRC}")" 2>/dev/null || true
    ok "Samba backup: ${SAMBA_DUMP} ($(du -sh "${SAMBA_DUMP}" | cut -f1))"
else
    warn "${SAMBA_SRC} no existe o no está montado — saltando"
fi

# =============================================================================
# 3. RESPALDAR CONFIGURACIONES DE SERVICIOS
# =============================================================================
info "3/4 — Respaldando configuraciones de servicios..."

CONFIG_FILES=(
    "docker/dhcp/dhcpd.conf"
    "docker/dns/named.conf"
    "docker/dns/zones/db.127"
    "docker/dns/zones/db.unidadvictimas.co"
    "docker/dns/zones/db.uv.local"
    "docker/smtp/Dockerfile"
    "docker/docker-compose.yml"
)

CONF_TMP=$(mktemp -d)
trap 'rm -rf "${CONF_TMP}"' EXIT

for rel in "${CONFIG_FILES[@]}"; do
    src="${PROJECT_DIR}/${rel}"
    if [[ -f "${src}" ]]; then
        dest="${CONF_TMP}/${rel}"
        mkdir -p "$(dirname "${dest}")"
        cp "${src}" "${dest}"
    else
        warn "Config no encontrada: ${rel}"
    fi
done

tar -czf "${CONF_DUMP}" -C "${CONF_TMP}" .
ok "Configs backup: ${CONF_DUMP} ($(du -sh "${CONF_DUMP}" | cut -f1))"

# =============================================================================
# 4. ELIMINAR BACKUPS CON MÁS DE 7 DÍAS
# =============================================================================
info "4/4 — Limpiando backups con más de ${RETENTION_DAYS} días..."

DELETED=0
while IFS= read -r -d '' old_file; do
    rm -f "${old_file}"
    warn "Eliminado: ${old_file}"
    ((DELETED++)) || true
done < <(find "${BACKUP_DIR}" -type f \
    \( -name "*.sql" -o -name "*.tar.gz" -o -name "*.skip" \) \
    -mtime "+${RETENTION_DAYS}" -print0 2>/dev/null)

if [[ $DELETED -eq 0 ]]; then
    ok "No hay backups antiguos que eliminar"
else
    ok "Eliminados ${DELETED} archivo(s) con más de ${RETENTION_DAYS} días"
fi

# =============================================================================
# RESUMEN FINAL
# =============================================================================
{
echo ""
echo "  Archivos generados (${FECHA}):"
find "${BACKUP_DIR}" -name "*${FECHA}*" -type f 2>/dev/null | \
    while read -r f; do echo "    $(du -sh "$f" | cut -f1)  $f"; done
echo ""
echo "  Espacio en /mnt/uv_logs:"
df -h /mnt/uv_logs | tail -1
echo "========================================================"
echo "  BACKUP COMPLETADO — $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"
} >> "${LOG_FILE}"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           Backup completado exitosamente             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
find "${BACKUP_DIR}" -name "*${FECHA}*" -type f 2>/dev/null | \
    while read -r f; do echo "  $(du -sh "$f" | cut -f1)  $f"; done
echo ""
echo "  Log: ${LOG_FILE}"
echo ""
df -h /mnt/uv_logs
