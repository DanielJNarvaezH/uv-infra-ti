#!/usr/bin/env bash
# =============================================================================
# clean_storage.sh — Limpieza idempotente de LVM y RAID antes de re-desplegar
# Infraestructura TI — Unidad para la Atención y Reparación Integral a las Víctimas
# Universidad del Quindío — Semestre 2026-1
# =============================================================================
#
# DESCRIPCIÓN:
#   Desmonta y elimina todos los Logical Volumes, Volume Groups, Physical Volumes
#   y arrays RAID creados por setup_lvm.sh y setup_raid.sh.
#   Deja el estado limpio para volver a ejecutar el despliegue completo.
#
#   Operaciones realizadas en orden inverso al de creación:
#     1. Desmontar /mnt/uv_db, /mnt/uv_files, /mnt/uv_logs
#     2. Eliminar entradas de /etc/fstab gestionadas por setup_lvm.sh
#     3. Eliminar LVs: lv_db, lv_files, lv_logs
#     4. Eliminar VGs: uv_vg (y alias conocidos vg_uv, vg_data)
#     5. Eliminar PV de /dev/md0
#     6. Detener y eliminar el RAID /dev/md0
#     7. Limpiar superbloques RAID en los discos proporcionados
#     8. Borrar firmas de los discos con wipefs
#
#   El script es totalmente idempotente: si algo ya no existe, lo salta.
#
# USO:
#   sudo bash scripts/storage/clean_storage.sh                # con discos por defecto
#   sudo bash scripts/storage/clean_storage.sh /dev/sdb /dev/sdc
#   sudo bash scripts/storage/clean_storage.sh /dev/nvme1n1 /dev/nvme2n1
#
# INTERACTIVO:
#   Si no se pasan argumentos, el script solicitará los discos con `read`.
#
# ADVERTENCIA:
#   ¡ESTE SCRIPT DESTRUYE DATOS! Todos los LVs y el RAID serán eliminados.
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
    err "Ejecutar como root: sudo bash $0 [/dev/sdb /dev/sdc]"
    exit 1
fi

# ── Leer discos (argumentos o interactivamente) ────────────────────────────────
if [[ $# -ge 2 ]]; then
    DISK0="$1"
    DISK1="$2"
    shift 2
else
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  Limpieza de almacenamiento — Se requieren los discos RAID${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo ""
    read -rp "Disco 1 (ej. /dev/sdb) [por defecto: /dev/sdb]: " DISK0
    DISK0="${DISK0:-/dev/sdb}"
    read -rp "Disco 2 (ej. /dev/sdc) [por defecto: /dev/sdc]: " DISK1
    DISK1="${DISK1:-/dev/sdc}"
    echo ""
fi

# ── Validar que los discos existen ────────────────────────────────────────────
for disk in "$DISK0" "$DISK1"; do
    if [[ ! -b "$disk" ]]; then
        err "$disk no es un dispositivo de bloque válido."
        exit 1
    fi
done

# ── Configuración ─────────────────────────────────────────────────────────────
RAID_DEV="/dev/md0"
VG_NAMES=("uv_vg" "vg_uv" "vg_data")
LV_NAMES=("lv_db" "lv_files" "lv_logs")
MOUNT_POINTS=("/mnt/uv_db" "/mnt/uv_files" "/mnt/uv_logs")
FSTAB="/etc/fstab"
FSTAB_MARKER="# >>> UV-INFRA-TI LVM mounts — managed by setup_lvm.sh <<<"

info "Discos RAID: ${DISK0}, ${DISK1}"
info "RAID device: ${RAID_DEV}"
info "VGs a eliminar: ${VG_NAMES[*]}"
info "LVs a eliminar: ${LV_NAMES[*]}"
info "Puntos de montaje: ${MOUNT_POINTS[*]}"

# ── Confirmación ──────────────────────────────────────────────────────────────
echo ""
warn "═════════════════════════════════════════════════════════"
warn "  ¡ATENCIÓN! Se eliminarán TODOS los datos en:"
warn "    - LVM: ${LV_NAMES[*]}"
warn "    - VG:  ${VG_NAMES[*]}"
warn "    - RAID: ${RAID_DEV} sobre ${DISK0}, ${DISK1}"
warn "  Esta operación es destructiva e irreversible."
warn "═════════════════════════════════════════════════════════"
echo ""
read -rp "¿Continuar con la limpieza? (sí/no): " confirm
if [[ "$confirm" != "sí" && "$confirm" != "sí" && "$confirm" != "si" && "$confirm" != "SI" ]]; then
    err "Operación cancelada por el usuario."
    exit 1
fi

# =============================================================================
# PASO 1 — Desmontar volúmenes lógicos
# =============================================================================
section "1. Desmontando volúmenes lógicos"

for mp in "${MOUNT_POINTS[@]}"; do
    if mountpoint -q "$mp" 2>/dev/null; then
        umount "$mp" && log "Desmontado ${mp}"
    else
        info "${mp} no está montado — omitiendo."
    fi
done

# Eliminar directorios de montaje vacíos
for mp in "${MOUNT_POINTS[@]}"; do
    if [[ -d "$mp" ]]; then
        rmdir "$mp" 2>/dev/null && log "Directorio ${mp} eliminado." || \
            warn "Directorio ${mp} no está vacío — se conserva."
    fi
done

# =============================================================================
# PASO 2 — Eliminar entradas de fstab
# =============================================================================
section "2. Limpiando /etc/fstab"

if [[ -f "${FSTAB}" ]]; then
    # Hacer backup
    FSTAB_BAK="${FSTAB}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${FSTAB}" "${FSTAB_BAK}"
    log "Backup de fstab: ${FSTAB_BAK}"

    # Eliminar bloque gestionado por setup_lvm.sh
    if grep -qF "${FSTAB_MARKER}" "${FSTAB}" 2>/dev/null; then
        sed -i "/${FSTAB_MARKER}/d" "${FSTAB}"
        log "Bloque LVM de fstab eliminado."
    fi

    # Eliminar entradas sueltas de los puntos de montaje
    for mp in "${MOUNT_POINTS[@]}"; do
        if grep -q " ${mp} " "${FSTAB}" 2>/dev/null; then
            sed -i "\| ${mp} |d" "${FSTAB}"
            warn "Entrada suelta para ${mp} eliminada de fstab."
        fi
    done

    # Validar fstab
    if ! mount --fake --all 2>/dev/null && ! findmnt --verify "${FSTAB}" &>/dev/null; then
        err "fstab quedó en estado inválido. Restaurando backup: ${FSTAB_BAK}"
        cp -a "${FSTAB_BAK}" "${FSTAB}"
        exit 1
    fi
    log "fstab limpiado y validado correctamente."
else
    warn "${FSTAB} no existe — omitiendo limpieza."
fi

# =============================================================================
# PASO 3 — Eliminar Logical Volumes
# =============================================================================
section "3. Eliminando Logical Volumes"

for lv in "${LV_NAMES[@]}"; do
    for vg in "${VG_NAMES[@]}"; do
        if lvs "${vg}/${lv}" &>/dev/null; then
            lvremove -f "/dev/${vg}/${lv}" 2>/dev/null && log "LV ${vg}/${lv} eliminado."
        else
            info "LV ${vg}/${lv} no existe — omitiendo."
        fi
    done
done

# =============================================================================
# PASO 4 — Eliminar Volume Groups
# =============================================================================
section "4. Eliminando Volume Groups"

for vg in "${VG_NAMES[@]}"; do
    if vgs "${vg}" &>/dev/null; then
        vgremove -f "${vg}" 2>/dev/null && log "VG ${vg} eliminado."
    else
        info "VG ${vg} no existe — omitiendo."
    fi
done

# =============================================================================
# PASO 5 — Eliminar Physical Volume
# =============================================================================
section "5. Eliminando Physical Volume"

if pvs "${RAID_DEV}" &>/dev/null; then
    pvremove -f "${RAID_DEV}" 2>/dev/null && log "PV ${RAID_DEV} eliminado."
else
    info "PV ${RAID_DEV} no existe — omitiendo."
fi

# =============================================================================
# PASO 6 — Detener y eliminar el RAID
# =============================================================================
section "6. Deteniendo y eliminando RAID"

if [[ -b "${RAID_DEV}" ]]; then
    # Intentar detener el RAID
    mdadm --stop "${RAID_DEV}" 2>/dev/null && log "RAID ${RAID_DEV} detenido." || \
        warn "No se pudo detener ${RAID_DEV} — puede que ya esté inactivo."
else
    info "${RAID_DEV} no existe como dispositivo de bloque."

    # Verificar si hay un RAID activo usando los discos
    for disk in "$DISK0" "$DISK1"; do
        existing_md=$(mdadm --examine "$disk" 2>/dev/null | grep -oP '/dev/md\d+' | head -1 || true)
        if [[ -n "$existing_md" ]]; then
            mdadm --stop "$existing_md" 2>/dev/null && warn "RAID existente detenido: ${existing_md}"
        fi
    done
fi

# =============================================================================
# PASO 7 — Limpiar superbloques RAID en los discos
# =============================================================================
section "7. Limpiando superbloques RAID en discos"

for disk in "$DISK0" "$DISK1"; do
    if [[ -b "$disk" ]]; then
        mdadm --zero-superblock "$disk" 2>/dev/null && log "Superbloque limpiado en ${disk}" || \
            info "Sin superbloque en ${disk} — omitiendo."
    fi
done

# =============================================================================
# PASO 8 — Borrar firmas de los discos
# =============================================================================
section "8. Borrando firmas de discos"

for disk in "$DISK0" "$DISK1"; do
    if [[ -b "$disk" ]]; then
        wipefs -a "$disk" &>/dev/null && log "Firmas borradas en ${disk}" || \
            info "Sin firmas en ${disk} — omitiendo."
    fi
done

# =============================================================================
# PASO 9 — Actualizar configuración de mdadm e initramfs
# =============================================================================
section "9. Actualizando configuración mdadm"

if [[ -f /etc/mdadm/mdadm.conf ]]; then
    # Regenerar sin el RAID eliminado
    mdadm --detail --scan > /etc/mdadm/mdadm.conf 2>/dev/null || true
    log "/etc/mdadm/mdadm.conf regenerado."
elif [[ -f /etc/mdadm.conf ]]; then
    mdadm --detail --scan > /etc/mdadm.conf 2>/dev/null || true
    log "/etc/mdadm.conf regenerado."
fi

update-initramfs -u &>/dev/null || true
log "initramfs actualizado."

# =============================================================================
# PASO 10 — Verificación final
# =============================================================================
section "10. Verificación de limpieza"

info "Estado de LVM:"
if [[ -f /etc/lvm/lvm.conf ]] || command -v lvs &>/dev/null; then
    lvs 2>/dev/null || info "No hay Logical Volumes."
fi

info "Estado de RAID:"
if [[ -f /proc/mdstat ]]; then
    cat /proc/mdstat
else
    info "/proc/mdstat no disponible."
fi

# ── Resumen ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      Limpieza de almacenamiento completada                    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Discos limpiados   : ${DISK0}, ${DISK1}"
echo "  RAID eliminado     : ${RAID_DEV}"
echo ""
echo "  Eliminado:"
echo "    - Logical Volumes: ${LV_NAMES[*]}"
echo "    - Volume Groups  : ${VG_NAMES[*]}"
echo "    - Physical Volume: ${RAID_DEV}"
echo "    - RAID 1 array   : ${RAID_DEV}"
echo "    - fstab entries  : LVM mounts eliminados"
echo ""
echo -e "${YELLOW}  Siguiente paso — re-ejecutar setup_raid.sh y setup_lvm.sh:${NC}"
echo "    sudo bash scripts/storage/setup_raid.sh ${DISK0} ${DISK1}"
echo "    sudo bash scripts/storage/setup_lvm.sh"
echo ""