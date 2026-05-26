#!/usr/bin/env bash
# =============================================================================
# setup_lvm.sh — ALM-2: Configuración de LVM sobre RAID 1
# Infraestructura TI — Unidad para la Atención y Reparación Integral a las Víctimas
# Universidad del Quindío — Semestre 2026-1
# =============================================================================
#
# DESCRIPCIÓN:
#   Configura LVM sobre el RAID 1 (/dev/md0) creado por setup_raid.sh.
#   Crea 3 Logical Volumes con propósitos distintos:
#
#     lv_db    (40%) → /mnt/uv_db    Base de datos PostgreSQL
#     lv_files (40%) → /mnt/uv_files Archivos Samba compartidos
#     lv_logs  (20%) → /mnt/uv_logs  Logs del sistema y backups
#
# PREREQUISITO:
#   Haber ejecutado setup_raid.sh primero (/dev/md0 debe existir).
#   Si el RAID ya tiene un VG de ALM-1 (vg_uv), este script lo reemplaza
#   con el VG correcto (uv_vg) y los 3 LVs requeridos.
#
# USO:
#   sudo bash scripts/storage/setup_lvm.sh
#
# VERIFICACIÓN:
#   sudo pvdisplay
#   sudo vgdisplay
#   sudo lvdisplay
#
# =============================================================================

set -euo pipefail

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[OK]${NC}  $*"; }
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
section() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# ── Verificar root ────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERR]${NC}  Ejecutar como root: sudo bash $0" >&2
    exit 1
fi

# ── Configuración ─────────────────────────────────────────────────────────────
RAID_DEV="/dev/md0"
VG_NAME="uv_vg"

# Logical Volumes — nombre, porcentaje, punto de montaje
declare -A LV_PCT=( [lv_db]="40" [lv_files]="40" [lv_logs]="20" )
declare -A LV_MNT=( [lv_db]="/mnt/uv_db" [lv_files]="/mnt/uv_files" [lv_logs]="/mnt/uv_logs" )

# ── Verificar prerequisitos ───────────────────────────────────────────────────
section "0. Verificando prerequisitos"

if ! command -v pvcreate &>/dev/null; then
    warn "lvm2 no encontrado — instalando..."
    apt-get install -y --no-install-recommends lvm2 -q
fi

if [[ ! -b "${RAID_DEV}" ]]; then
    echo -e "${RED}[ERR]${NC}  ${RAID_DEV} no existe." >&2
    echo -e "${RED}[ERR]${NC}  Ejecuta primero: sudo bash scripts/storage/setup_raid.sh" >&2
    exit 1
fi
log "RAID device ${RAID_DEV} disponible."

# ── Limpiar estado previo (idempotente) ───────────────────────────────────────
section "1. Limpiando estado LVM previo"

for lv in lv_db lv_files lv_logs; do
    for vg in uv_vg vg_uv vg_data; do
        if lvs "${vg}/${lv}" &>/dev/null 2>&1; then
            mp="${LV_MNT[$lv]:-}"
            [[ -n "$mp" ]] && mountpoint -q "$mp" 2>/dev/null && umount "$mp" && warn "Desmontado $mp"
            lvremove -f "/dev/${vg}/${lv}" 2>/dev/null && warn "LV ${vg}/${lv} eliminado"
        fi
    done
done

for vg in uv_vg vg_uv vg_data; do
    if vgs "${vg}" &>/dev/null 2>&1; then
        vgremove -f "${vg}" 2>/dev/null && warn "VG ${vg} eliminado"
    fi
done

if pvs "${RAID_DEV}" &>/dev/null 2>&1; then
    pvremove -f "${RAID_DEV}" 2>/dev/null && warn "PV ${RAID_DEV} eliminado"
fi

log "Estado previo limpiado."

# ── Physical Volume ───────────────────────────────────────────────────────────
section "2. Creando Physical Volume (PV)"

pvcreate "${RAID_DEV}"
log "PV creado: ${RAID_DEV}"
pvdisplay "${RAID_DEV}"

# ── Volume Group ──────────────────────────────────────────────────────────────
section "3. Creando Volume Group (VG): ${VG_NAME}"

vgcreate "${VG_NAME}" "${RAID_DEV}"
log "VG creado: ${VG_NAME}"
vgdisplay "${VG_NAME}"

# ── Logical Volumes ───────────────────────────────────────────────────────────
section "4. Creando Logical Volumes"

# lv_db — 40% para PostgreSQL
lvcreate --extents "40%VG" --name "lv_db"    "${VG_NAME}"
log "lv_db    creado (40% del VG → /mnt/uv_db)"

# lv_files — 40% para Samba
lvcreate --extents "40%VG" --name "lv_files" "${VG_NAME}"
log "lv_files creado (40% del VG → /mnt/uv_files)"

# lv_logs — 20% restante para logs y backups
lvcreate --extents "100%FREE" --name "lv_logs" "${VG_NAME}"
log "lv_logs  creado (20% del VG → /mnt/uv_logs)"

lvdisplay

# ── Formatear con ext4 ────────────────────────────────────────────────────────
section "5. Formateando con ext4"

mkfs.ext4 -F -L "uv_db"    "/dev/${VG_NAME}/lv_db"
log "lv_db    formateado (ext4, label: uv_db)"

mkfs.ext4 -F -L "uv_files" "/dev/${VG_NAME}/lv_files"
log "lv_files formateado (ext4, label: uv_files)"

mkfs.ext4 -F -L "uv_logs"  "/dev/${VG_NAME}/lv_logs"
log "lv_logs  formateado (ext4, label: uv_logs)"

# ── Crear puntos de montaje y montar ──────────────────────────────────────────
section "6. Montando Logical Volumes"

for lv in lv_db lv_files lv_logs; do
    mp="${LV_MNT[$lv]}"
    mkdir -p "${mp}"
    mount "/dev/${VG_NAME}/${lv}" "${mp}"
    log "${lv} montado en ${mp}"
done

df -h /mnt/uv_db /mnt/uv_files /mnt/uv_logs

# ── /etc/fstab — NO se modifica automáticamente ──────────────────────────────
section "7. Nota sobre persistencia en /etc/fstab"

# ⚠️  IMPORTANTE: Este script NO modifica /etc/fstab intencionalmente.
#
# Agregar los LVs al fstab en una máquina HOST REAL puede bloquear el arranque
# si los dispositivos loop o el RAID no están disponibles al inicio del sistema
# (lo cual es el caso aquí, ya que los discos virtuales viven en /tmp).
#
# Este script está diseñado para ENTORNOS VIRTUALES o EJECUCIÓN MANUAL.
# Los montajes son temporales y se pierden al reiniciar — eso es correcto.
#
# Si deseas montaje persistente en una VM o entorno controlado,
# agrega manualmente estas líneas a /etc/fstab:
#
#   /dev/uv_vg/lv_db     /mnt/uv_db     ext4  defaults,nofail  0  2
#   /dev/uv_vg/lv_files  /mnt/uv_files  ext4  defaults,nofail  0  2
#   /dev/uv_vg/lv_logs   /mnt/uv_logs   ext4  defaults,nofail  0  2
#
# Nota: usar la opción 'nofail' para que el sistema arranque aunque
# los dispositivos no estén disponibles.

warn "Montajes activos solo para esta sesión — no se modifica /etc/fstab"
warn "Para persistencia manual ver comentario en el script (sección 7)"

# ── Documentación final ───────────────────────────────────────────────────────
section "8. Documentación — pvdisplay / vgdisplay / lvdisplay"

echo ""
echo "═══ pvdisplay ═══"
pvdisplay

echo ""
echo "═══ vgdisplay ═══"
vgdisplay

echo ""
echo "═══ lvdisplay ═══"
lvdisplay

# ── Resumen ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          LVM sobre RAID 1 — Configuración completada        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  RAID Device  : ${RAID_DEV}"
echo "  VG           : ${VG_NAME}"
echo ""
echo "  lv_db    (40%) → /mnt/uv_db    — PostgreSQL"
echo "  lv_files (40%) → /mnt/uv_files — Samba"
echo "  lv_logs  (20%) → /mnt/uv_logs  — Logs y backups"
echo ""
df -h /mnt/uv_db /mnt/uv_files /mnt/uv_logs
echo ""
echo -e "${YELLOW}  Verificar:${NC}"
echo "    sudo pvdisplay"
echo "    sudo vgdisplay"
echo "    sudo lvdisplay"