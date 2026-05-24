#!/usr/bin/env bash
# =============================================================================
# setup_raid.sh — ALM-1: Simulación de RAID 1 con discos virtuales (loop)
# Infraestructura TI — Unidad para la Atención y Reparación Integral a las Víctimas
# Universidad del Quindío — Semestre 2026-1
# =============================================================================
#
# DESCRIPCIÓN:
#   Simula un RAID 1 (espejo) usando dos archivos imagen montados como
#   dispositivos loop. No requiere discos físicos adicionales — funciona
#   en cualquier máquina Linux del equipo.
#
# USO:
#   sudo bash scripts/storage/setup_raid.sh           # discos de 500 MB
#   sudo bash scripts/storage/setup_raid.sh 1024      # discos de 1 GB
#
# REQUISITOS:
#   - mdadm     : sudo apt install mdadm
#   - lvm2      : sudo apt install lvm2
#   - Ejecutar como root o con sudo
#
# RESULTADO FINAL:
#   /dev/loop0, /dev/loop1  → discos virtuales (archivos imagen)
#   /dev/md0                → RAID 1 (mirror de loop0 + loop1)
#   /dev/vg_uv/lv_db        → Logical Volume sobre el RAID
#   /mnt/uv_db              → punto de montaje
#
# =============================================================================
# JUSTIFICACIÓN TÉCNICA — ¿Por qué RAID 1 para la BD de la Unidad de Víctimas?
#
# La Unidad gestiona el Registro Único de Víctimas (RUV) con datos de millones
# de personas afectadas por el conflicto armado colombiano. Una pérdida de datos
# en srv-db-01 (PostgreSQL) sería irreversible y violaría derechos fundamentales.
#
# COMPARATIVA DE NIVELES RAID:
#
#  ┌──────────┬───────────────┬──────────────────┬──────────────────────────┐
#  │ Nivel    │ Redundancia   │ Rendimiento      │ Cuándo usarlo            │
#  ├──────────┼───────────────┼──────────────────┼──────────────────────────┤
#  │ RAID 0   │ Ninguna ✗     │ Lectura/escrit.  │ Datos no críticos donde  │
#  │ (stripe) │ 1 disco falla │ doble — máximo   │ prima la velocidad.      │
#  │          │ = pérdida     │ rendimiento      │ Ej: caché, logs temp.    │
#  │          │ total         │                  │                          │
#  ├──────────┼───────────────┼──────────────────┼──────────────────────────┤
#  │ RAID 1   │ Alta ✓        │ Lectura: doble   │ ELEGIDO para srv-db-01.  │
#  │ (mirror) │ Tolera fallo  │ Escritura: igual │ Datos críticos, mínimo   │
#  │          │ de N-1 discos │ que 1 disco      │ 2 discos, recuperación   │
#  │          │               │                  │ inmediata sin pérdida.   │
#  ├──────────┼───────────────┼──────────────────┼──────────────────────────┤
#  │ RAID 5   │ Media ✓       │ Lectura alta     │ Almacenamiento masivo    │
#  │ (paridad │ Tolera fallo  │ Escritura con    │ con balance rendimiento/ │
#  │ distrib.)│ de 1 disco    │ overhead paridad │ redundancia. Mín. 3      │
#  │          │               │                  │ discos. Mayor complejidad│
#  └──────────┴───────────────┴──────────────────┴──────────────────────────┘
#
# CONCLUSIÓN: RAID 1 ofrece la máxima protección con solo 2 discos, recuperación
# transparente ante fallo de uno, y carga de lectura distribuida — ideal para
# PostgreSQL con mezcla de lecturas y escrituras transaccionales.
# =============================================================================

set -euo pipefail

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC}  $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*" >&2; }

# ── Verificar root ────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "Ejecutar como root: sudo bash $0"
    exit 1
fi

# ── Parámetros ────────────────────────────────────────────────────────────────
DISK_SIZE_MB=${1:-500}
IMG_DIR="/tmp/uv_raid_disks"
IMG_DISK0="${IMG_DIR}/disk0.img"
IMG_DISK1="${IMG_DIR}/disk1.img"
RAID_DEV="/dev/md0"
VG_NAME="vg_uv"
LV_NAME="lv_db"
MOUNT_POINT="/mnt/uv_db"

# ── Verificar dependencias ────────────────────────────────────────────────────
info "Verificando dependencias..."
for pkg_cmd in "mdadm:mdadm" "pvcreate:lvm2" "mkfs.ext4:e2fsprogs"; do
    cmd="${pkg_cmd%%:*}"; pkg="${pkg_cmd##*:}"
    if ! command -v "$cmd" &>/dev/null; then
        warn "$cmd no encontrado — instalando $pkg..."
        apt-get install -y --no-install-recommends "$pkg" -q
    fi
done
log "Dependencias verificadas."

# ── Limpiar estado previo (idempotente) ───────────────────────────────────────
info "Limpiando estado previo si existe..."
mountpoint -q "${MOUNT_POINT}" 2>/dev/null && umount "${MOUNT_POINT}" && warn "Desmontado ${MOUNT_POINT}"
lvs "${VG_NAME}/${LV_NAME}" &>/dev/null && lvremove -f "/dev/${VG_NAME}/${LV_NAME}" && warn "LV eliminado"
vgs "${VG_NAME}" &>/dev/null            && vgremove -f "${VG_NAME}"                 && warn "VG eliminado"
pvs "${RAID_DEV}" &>/dev/null           && pvremove -f "${RAID_DEV}"                && warn "PV eliminado"
[[ -b "${RAID_DEV}" ]]                  && mdadm --stop "${RAID_DEV}" 2>/dev/null   && warn "RAID detenido"
for img in "${IMG_DISK0}" "${IMG_DISK1}"; do
    for loop in $(losetup -j "$img" 2>/dev/null | cut -d: -f1); do
        losetup -d "$loop" && warn "Loop liberado: $loop"
    done
done

# ── Crear imágenes de disco ───────────────────────────────────────────────────
info "Creando discos virtuales de ${DISK_SIZE_MB} MB cada uno en ${IMG_DIR}..."
mkdir -p "${IMG_DIR}"
dd if=/dev/zero of="${IMG_DISK0}" bs=1M count="${DISK_SIZE_MB}" status=none
dd if=/dev/zero of="${IMG_DISK1}" bs=1M count="${DISK_SIZE_MB}" status=none
log "Imágenes creadas: disk0.img y disk1.img (${DISK_SIZE_MB} MB c/u)"

# ── Montar como loop devices ──────────────────────────────────────────────────
info "Asociando loop devices..."
LOOP0=$(losetup --find --show "${IMG_DISK0}")
LOOP1=$(losetup --find --show "${IMG_DISK1}")
log "Loop devices: ${LOOP0} → disk0.img | ${LOOP1} → disk1.img"

# ── Crear RAID 1 ──────────────────────────────────────────────────────────────
info "Creando RAID 1 con mdadm..."
mdadm --create "${RAID_DEV}" \
      --level=1 \
      --raid-devices=2 \
      --metadata=1.2 \
      --run \
      "${LOOP0}" "${LOOP1}" <<< "yes"

sleep 2
log "RAID 1 creado en ${RAID_DEV}"

# ── Verificar RAID ────────────────────────────────────────────────────────────
info "Estado del RAID (/proc/mdstat):"
echo "────────────────────────────────────"
cat /proc/mdstat
echo "────────────────────────────────────"
mdadm --detail "${RAID_DEV}"

# ── LVM sobre RAID ────────────────────────────────────────────────────────────
info "Configurando LVM sobre ${RAID_DEV}..."

pvcreate "${RAID_DEV}"
log "Physical Volume: ${RAID_DEV}"

vgcreate "${VG_NAME}" "${RAID_DEV}"
log "Volume Group: ${VG_NAME}"

# 90% del espacio libre — margen para snapshots futuros
lvcreate --extents 90%FREE --name "${LV_NAME}" "${VG_NAME}"
log "Logical Volume: /dev/${VG_NAME}/${LV_NAME}"

# ── Formatear y montar ────────────────────────────────────────────────────────
info "Formateando con ext4..."
mkfs.ext4 -F -L "uv_db_data" "/dev/${VG_NAME}/${LV_NAME}"

info "Montando en ${MOUNT_POINT}..."
mkdir -p "${MOUNT_POINT}"
mount "/dev/${VG_NAME}/${LV_NAME}" "${MOUNT_POINT}"
log "Montado correctamente."

# ── Resumen ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       RAID 1 + LVM — Configuración completada       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Disco virtual 0 : ${IMG_DISK0} → ${LOOP0}"
echo "  Disco virtual 1 : ${IMG_DISK1} → ${LOOP1}"
echo "  RAID Device      : ${RAID_DEV}  (RAID 1 — mirror)"
echo "  Volume Group     : ${VG_NAME}"
echo "  Logical Volume   : /dev/${VG_NAME}/${LV_NAME}"
echo "  Punto de montaje : ${MOUNT_POINT}"
echo ""
df -h "${MOUNT_POINT}"
echo ""
echo -e "${YELLOW}  Para verificar el RAID en cualquier momento:${NC}"
echo "    cat /proc/mdstat"
echo "    sudo mdadm --detail ${RAID_DEV}"
echo ""
echo -e "${YELLOW}  Nota: configuración en archivos temporales (/tmp).${NC}"
echo -e "${YELLOW}  Para hacer el montaje persistente agregar a /etc/fstab:${NC}"
echo "  /dev/${VG_NAME}/${LV_NAME}  ${MOUNT_POINT}  ext4  defaults  0  2"
