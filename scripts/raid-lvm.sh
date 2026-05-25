#!/bin/bash
# =============================================================================
# raid-lvm.sh — RAID 1 + LVM para almacenamiento del SIG
# Unidad para la Atención y Reparación Integral a las Víctimas
# Universidad del Quindío — Semestre 2026-1
# =============================================================================
# Crea:
#   /dev/md0          → RAID 1 sobre los discos indicados
#   vg_uv             → Volume Group sobre /dev/md0
#   lv_db    (60%)    → /mnt/uv_db    — datos de PostgreSQL (srv-db-01)
#   lv_files (40%)    → /mnt/uv_files — documentos Samba (srv-files-01)
#
# Uso:
#   sudo bash scripts/raid-lvm.sh /dev/sdb /dev/sdc [/dev/sdd ...]
# =============================================================================

set -euo pipefail

log()  { echo -e "\e[32m[$(date '+%H:%M:%S')][INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[$(date '+%H:%M:%S')][WARN]\e[0m $*"; }
err()  { echo -e "\e[31m[$(date '+%H:%M:%S')][ERR ]\e[0m $*" >&2; exit 1; }

# =============================================================================
# Verificación de argumentos y privilegios
# =============================================================================
[ "$(id -u)" -eq 0 ] || err "Ejecutar con sudo: sudo bash scripts/raid-lvm.sh ..."

if [[ $# -lt 2 ]]; then
    err "Se requieren al menos 2 discos para RAID 1.\nUso: $0 /dev/sdb /dev/sdc [/dev/sdd ...]"
fi

for disk in "$@"; do
    [[ -b "$disk" ]] || err "$disk no es un dispositivo de bloque válido."
done

NUM_DISKS=$#
VG_NAME="vg_uv"
MD_DEVICE="/dev/md0"

# Puntos de montaje y LVs
LV_DB="lv_db"
LV_FILES="lv_files"
MOUNT_DB="/mnt/uv_db"
MOUNT_FILES="/mnt/uv_files"

# UID/GID postgres en la imagen postgres:16
POSTGRES_UID=999
POSTGRES_GID=999

# GID g_files en srv-files-01
SAMBA_GID=1050

# =============================================================================
# Instalar dependencias
# =============================================================================
log "=== Verificando dependencias ==="

if ! command -v mdadm &>/dev/null; then
    log "Instalando mdadm..."
    apt-get update -qq && apt-get install -y --no-install-recommends mdadm
fi

if ! command -v pvcreate &>/dev/null; then
    log "Instalando lvm2..."
    apt-get update -qq && apt-get install -y --no-install-recommends lvm2
fi

# =============================================================================
# 1. RAID 1
# =============================================================================
log "=== Creando RAID 1 con $NUM_DISKS discos: $* ==="

if [[ -e "$MD_DEVICE" ]]; then
    warn "$MD_DEVICE ya existe. Deteniendo y recreando..."
    mdadm --stop "$MD_DEVICE" || true
fi

mdadm --create "$MD_DEVICE" \
    --level=1 \
    --raid-devices="$NUM_DISKS" \
    --metadata=1.2 \
    --run \
    "$@"

log "RAID 1 creado en $MD_DEVICE"
mdadm --detail "$MD_DEVICE"

# Guardar configuración del RAID para que persista tras reinicios
log "Guardando configuración RAID en /etc/mdadm/mdadm.conf..."
mkdir -p /etc/mdadm
mdadm --detail --scan >> /etc/mdadm/mdadm.conf
update-initramfs -u 2>/dev/null || warn "update-initramfs no disponible, omitiendo."

# =============================================================================
# 2. Physical Volume
# =============================================================================
log "=== Creando Physical Volume (PV) ==="
pvcreate -ff -y "$MD_DEVICE"
pvs "$MD_DEVICE"

# =============================================================================
# 3. Volume Group
# =============================================================================
log "=== Creando Volume Group $VG_NAME ==="
vgcreate "$VG_NAME" "$MD_DEVICE"
vgs "$VG_NAME"

# =============================================================================
# 4. Logical Volumes
# =============================================================================
log "=== Creando Logical Volumes ==="

# lv_db — 60% del VG para PostgreSQL
lvcreate -l 60%VG -n "$LV_DB" "$VG_NAME"
log "  ✓ $LV_DB → 60% del VG (aprox. $(lvdisplay /dev/$VG_NAME/$LV_DB | awk '/LV Size/{print $3,$4}'))"

# lv_files — 40% restante para Samba
lvcreate -l 100%FREE -n "$LV_FILES" "$VG_NAME"
log "  ✓ $LV_FILES → 40% del VG (aprox. $(lvdisplay /dev/$VG_NAME/$LV_FILES | awk '/LV Size/{print $3,$4}'))"

lvs "$VG_NAME"

# =============================================================================
# 5. Formateo ext4
# =============================================================================
log "=== Formateando volúmenes con ext4 ==="
mkfs.ext4 -F -L "uv_db"    "/dev/$VG_NAME/$LV_DB"
mkfs.ext4 -F -L "uv_files" "/dev/$VG_NAME/$LV_FILES"
log "  ✓ Formato ext4 aplicado a ambos volúmenes"

# =============================================================================
# 6. Puntos de montaje
# =============================================================================
log "=== Creando puntos de montaje ==="
mkdir -p "$MOUNT_DB" "$MOUNT_FILES"

# Montar
mount "/dev/$VG_NAME/$LV_DB"    "$MOUNT_DB"
mount "/dev/$VG_NAME/$LV_FILES" "$MOUNT_FILES"

log "  ✓ $MOUNT_DB montado"
log "  ✓ $MOUNT_FILES montado"

# =============================================================================
# 7. Permisos de directorios para los contenedores
# =============================================================================
log "=== Aplicando permisos ==="

# /mnt/uv_db — PostgreSQL corre con UID 999 / GID 999 en la imagen postgres:16
chown "${POSTGRES_UID}:${POSTGRES_GID}" "$MOUNT_DB"
chmod 700 "$MOUNT_DB"
log "  ✓ $MOUNT_DB → UID:GID ${POSTGRES_UID}:${POSTGRES_GID}, chmod 700"

# /mnt/uv_files — Samba usa root:g_files (GID 1050), SETGID y sticky
chown root:"${SAMBA_GID}" "$MOUNT_FILES"
chmod 2770 "$MOUNT_FILES"    # SETGID: archivos heredan grupo g_files
chmod +t   "$MOUNT_FILES"    # Sticky: solo propietario puede eliminar
log "  ✓ $MOUNT_FILES → root:${SAMBA_GID}, chmod 2770 +t (SETGID + sticky)"

# =============================================================================
# 8. /etc/fstab — montaje automático al arrancar el host
# =============================================================================
log "=== Agregando entradas a /etc/fstab ==="

# Obtener UUIDs para referencias estables (independientes del nombre de dispositivo)
UUID_DB=$(blkid -s UUID -o value "/dev/$VG_NAME/$LV_DB")
UUID_FILES=$(blkid -s UUID -o value "/dev/$VG_NAME/$LV_FILES")

FSTAB_DB="UUID=${UUID_DB}  ${MOUNT_DB}     ext4  defaults,nofail  0  2"
FSTAB_FILES="UUID=${UUID_FILES}  ${MOUNT_FILES}  ext4  defaults,nofail  0  2"

if grep -qF "$MOUNT_DB" /etc/fstab; then
    warn "Ya existe entrada para $MOUNT_DB en /etc/fstab — omitiendo."
else
    echo "$FSTAB_DB" >> /etc/fstab
    log "  ✓ Entrada agregada: $FSTAB_DB"
fi

if grep -qF "$MOUNT_FILES" /etc/fstab; then
    warn "Ya existe entrada para $MOUNT_FILES en /etc/fstab — omitiendo."
else
    echo "$FSTAB_FILES" >> /etc/fstab
    log "  ✓ Entrada agregada: $FSTAB_FILES"
fi

# =============================================================================
# 9. Verificación final
# =============================================================================
log ""
log "=== Verificación de montaje ==="
df -h "$MOUNT_DB" "$MOUNT_FILES"

log ""
log "=== Configuración RAID ==="
mdadm --detail "$MD_DEVICE"

log ""
log "=== Configuración LVM ==="
pvs && echo "" && vgs && echo "" && lvs

echo ""
log "============================================================"
log " ALM-3 — Aprovisionamiento completado"
log "============================================================"
log ""
log " RAID 1     : $MD_DEVICE"
log " VG         : $VG_NAME"
log ""
log " srv-db-01  (PostgreSQL)"
log "   LV       : /dev/$VG_NAME/$LV_DB"
log "   UUID     : $UUID_DB"
log "   Montaje  : $MOUNT_DB"
log "   Permisos : UID ${POSTGRES_UID}:${POSTGRES_GID} chmod 700"
log ""
log " srv-files-01 (Samba)"
log "   LV       : /dev/$VG_NAME/$LV_FILES"
log "   UUID     : $UUID_FILES"
log "   Montaje  : $MOUNT_FILES"
log "   Permisos : root:${SAMBA_GID} chmod 2770+t (SETGID + sticky)"
log ""
log " Próximo paso:"
log "   cd docker && podman-compose up -d --build srv-db-01 srv-files-01"
log "============================================================"
