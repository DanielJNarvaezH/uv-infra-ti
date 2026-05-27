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
#   También formatea los LVs con ext4, los monta y persiste la
#   configuración en /etc/fstab (con opción nofail).
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
#   mount | grep uv_
#
# =============================================================================

set -euo pipefail

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[OK]${NC}  $*"; }
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()     { echo -e "${RED}[ERR]${NC}  $*" >&2; }
section() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# ── Verificar root ────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "Ejecutar como root: sudo bash $0"
    exit 1
fi

# ── Configuración ─────────────────────────────────────────────────────────────
RAID_DEV="/dev/md0"
VG_NAME="uv_vg"
FSTAB="/etc/fstab"
FSTAB_MARKER="# >>> UV-INFRA-TI LVM mounts — managed by setup_lvm.sh <<<"

# Logical Volumes — nombre, porcentaje, punto de montaje, label
declare -A LV_PCT=(  [lv_db]="40"  [lv_files]="40"  [lv_logs]="20" )
declare -A LV_MNT=(  [lv_db]="/mnt/uv_db"  [lv_files]="/mnt/uv_files"  [lv_logs]="/mnt/uv_logs" )
declare -A LV_LABEL=( [lv_db]="uv_db"  [lv_files]="uv_files"  [lv_logs]="uv_logs" )

# ── Verificar prerequisitos ───────────────────────────────────────────────────
section "0. Verificando prerequisitos"

for pkg_cmd in "pvcreate:lvm2" "mkfs.ext4:e2fsprogs"; do
    cmd="${pkg_cmd%%:*}"; pkg="${pkg_cmd##*:}"
    if ! command -v "$cmd" &>/dev/null; then
        warn "$cmd no encontrado — instalando $pkg..."
        apt-get install -y --no-install-recommends "$pkg" -q
    fi
done

if [[ ! -b "${RAID_DEV}" ]]; then
    err "${RAID_DEV} no existe."
    err "Ejecuta primero: sudo bash scripts/storage/setup_raid.sh"
    exit 1
fi
log "RAID device ${RAID_DEV} disponible."

# ── Validar /etc/fstab ────────────────────────────────────────────────────────
section "0b. Validando /etc/fstab"

if [[ ! -f "${FSTAB}" ]]; then
    err "${FSTAB} no existe. No se puede persistir montajes."
    exit 1
fi

if [[ ! -w "${FSTAB}" ]]; then
    err "${FSTAB} no es escribible. Ejecuta como root."
    exit 1
fi
log "${FSTAB} accesible para escritura."

# ── Hacer backup de /etc/fstab ────────────────────────────────────────────────
FSTAB_BAK="${FSTAB}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "${FSTAB}" "${FSTAB_BAK}"
log "Backup de fstab creado: ${FSTAB_BAK}"

# ── Limpiar estado previo (idempotente) ───────────────────────────────────────
section "1. Limpiando estado LVM previo"

# Desmontar si están montados
for lv in lv_db lv_files lv_logs; do
    mp="${LV_MNT[$lv]}"
    if mountpoint -q "$mp" 2>/dev/null; then
        umount "$mp" && warn "Desmontado $mp"
    fi
done

# Eliminar LVs existentes en cualquier VG conocido
for lv in lv_db lv_files lv_logs; do
    for vg in uv_vg vg_uv vg_data; do
        if lvs "${vg}/${lv}" &>/dev/null 2>&1; then
            lvremove -f "/dev/${vg}/${lv}" 2>/dev/null && warn "LV ${vg}/${lv} eliminado"
        fi
    done
done

# Eliminar VGs existentes
for vg in uv_vg vg_uv vg_data; do
    if vgs "${vg}" &>/dev/null 2>&1; then
        vgremove -f "${vg}" 2>/dev/null && warn "VG ${vg} eliminado"
    fi
done

# Eliminar PV existente
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

for lv in lv_db lv_files lv_logs; do
    label="${LV_LABEL[$lv]}"
    mkfs.ext4 -F -L "${label}" "/dev/${VG_NAME}/${lv}"
    log "${lv} formateado (ext4, label: ${label})"
done

# ── Crear puntos de montaje y montar ──────────────────────────────────────────
section "6. Montando Logical Volumes"

for lv in lv_db lv_files lv_logs; do
    mp="${LV_MNT[$lv]}"
    mkdir -p "${mp}"
    mount "/dev/${VG_NAME}/${lv}" "${mp}"
    log "${lv} montado en ${mp}"
done

df -h /mnt/uv_db /mnt/uv_files /mnt/uv_logs

# ── Persistir en /etc/fstab ───────────────────────────────────────────────────
section "7. Persistiendo montajes en /etc/fstab"

# Verificar que los dispositivos estén activos antes de escribir fstab
info "Validando dispositivos LV antes de escribir fstab..."
for lv in lv_db lv_files lv_logs; do
    lv_dev="/dev/${VG_NAME}/${lv}"
    if [[ ! -b "${lv_dev}" ]]; then
        err "Dispositivo ${lv_dev} no existe. Abortando escritura de fstab."
        err "Restaurar fstab desde backup: cp ${FSTAB_BAK} ${FSTAB}"
        exit 1
    fi

    # Verificar que el LV está montado correctamente
    mp="${LV_MNT[$lv]}"
    if ! mountpoint -q "$mp" 2>/dev/null; then
        err "${lv_dev} no está montado en ${mp}. Abortando escritura de fstab."
        err "Restaurar fstab desde backup: cp ${FSTAB_BAK} ${FSTAB}"
        exit 1
    fi
done
log "Todos los dispositivos LV validados y montados correctamente."

# Verificar que /etc/fstab no esté vacío después del backup (integridad)
if [[ ! -s "${FSTAB}" ]]; then
    err "${FSTAB} está vacío. Restaurando backup."
    cp -a "${FSTAB_BAK}" "${FSTAB}"
    exit 1
fi

# Obtener UUIDs para fstab (más robusto que rutas /dev/)
declare -A LV_UUID
for lv in lv_db lv_files lv_logs; do
    LV_UUID[$lv]=$(blkid -s UUID -o value "/dev/${VG_NAME}/${lv}" 2>/dev/null || true)
done

# Eliminar entradas previas gestionadas por este script
if grep -qF "${FSTAB_MARKER}" "${FSTAB}" 2>/dev/null; then
    # Eliminar el bloque entre marcadores (inclusive)
    sed -i "/${FSTAB_MARKER}/d" "${FSTAB}"
    log "Entradas previas de LVM eliminadas de fstab."
fi

# También eliminar entradas sueltas que coincidan con los puntos de montaje
for lv in lv_db lv_files lv_logs; do
    mp="${LV_MNT[$lv]}"
    if grep -q " ${mp} " "${FSTAB}" 2>/dev/null; then
        sed -i "\| ${mp} |d" "${FSTAB}"
        warn "Entrada suelta para ${mp} eliminada de fstab."
    fi
done

# Agregar nuevas entradas con UUID si están disponibles, si no con ruta /dev/
echo "" >> "${FSTAB}"
echo "${FSTAB_MARKER}" >> "${FSTAB}"

for lv in lv_db lv_files lv_logs; do
    mp="${LV_MNT[$lv]}"
    uuid="${LV_UUID[$lv]}"
    if [[ -n "${uuid}" ]]; then
        fstab_entry="UUID=${uuid}  ${mp}  ext4  defaults,nofail  0  2"
    else
        fstab_entry="/dev/${VG_NAME}/${lv}  ${mp}  ext4  defaults,nofail  0  2"
    fi
    echo "${fstab_entry}" >> "${FSTAB}"
    log "Agregado a fstab: ${fstab_entry}"
done

echo "${FSTAB_MARKER}" >> "${FSTAB}"
log "Entradas de fstab escritas correctamente."

# Validar fstab antes de continuar
info "Validando sintaxis de /etc/fstab..."
if ! mount --fake --all 2>/dev/null && ! findmnt --verify "${FSTAB}" &>/dev/null; then
    err "Validación de fstab fallida. Restaurando backup."
    cp -a "${FSTAB_BAK}" "${FSTAB}"
    exit 1
fi
log "Sintaxis de /etc/fstab validada correctamente."

# ── Verificar montaje persistente ────────────────────────────────────────────
info "Verificando que los montajes son persistentes..."
for lv in lv_db lv_files lv_logs; do
    mp="${LV_MNT[$lv]}"
    if ! findmnt --source "/dev/${VG_NAME}/${lv}" --target "${mp}" &>/dev/null; then
        err "Error: ${lv} no se encuentra montado en ${mp}."
        exit 1
    fi
done
log "Todos los Logical Volumes están montados y persistentes en fstab."

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
echo -e "${GREEN}║      LVM sobre RAID 1 — Configuración completada             ║${NC}"
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
echo -e "${YELLOW}  Montajes persistentes en /etc/fstab:${NC}"
grep -A4 "${FSTAB_MARKER}" "${FSTAB}" | head -6
echo ""
echo -e "${YELLOW}  Verificar:${NC}"
echo "    sudo pvdisplay"
echo "    sudo vgdisplay"
echo "    sudo lvdisplay"
echo "    mount | grep uv_"
echo "    sudo findmnt --verify"