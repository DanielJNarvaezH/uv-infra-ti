#!/usr/bin/env bash
# =============================================================================
# setup_raid.sh — ALM-1: Configuración de RAID 1 con discos físicos
# Infraestructura TI — Unidad para la Atención y Reparación Integral a las Víctimas
# Universidad del Quindío — Semestre 2026-1
# =============================================================================
#
# DESCRIPCIÓN:
#   Configura un RAID 1 (espejo) sobre dispositivos de bloque reales.
#   Los discos se pasan como argumentos — mínimo 2 para RAID 1.
#
#   Este script SOLO crea el RAID. La configuración de LVM, formateo
#   y montaje se realiza con setup_lvm.sh (ALM-2).
#
# USO:
#   sudo bash scripts/storage/setup_raid.sh /dev/sdb /dev/sdc
#   sudo bash scripts/storage/setup_raid.sh /dev/nvme1n1 /dev/nvme2n1
#
# REQUISITOS:
#   - mdadm : sudo apt install mdadm
#   - Ejecutar como root o con sudo
#
# RESULTADO FINAL:
#   /dev/md0 → RAID 1 (mirror de los discos proporcionados)
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
    err "Ejecutar como root: sudo bash $0 /dev/sdb /dev/sdc"
    exit 1
fi

# ── Leer discos (argumentos o interactivamente) ───────────────────────────────
if [[ $# -ge 2 ]]; then
    DISKS=("$@")
else
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  Configuración RAID 1 — Se requieren los discos${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo ""
    read -rp "Disco 1 (ej. /dev/sdb) [por defecto: /dev/sdb]: " DISK0
    DISK0="${DISK0:-/dev/sdb}"
    read -rp "Disco 2 (ej. /dev/sdc) [por defecto: /dev/sdc]: " DISK1
    DISK1="${DISK1:-/dev/sdc}"
    DISKS=("$DISK0" "$DISK1")
    echo ""
fi
for disk in "${DISKS[@]}"; do
    if [[ ! -b "$disk" ]]; then
        err "$disk no es un dispositivo de bloque válido."
        exit 1
    fi
done

# ── Parámetros ────────────────────────────────────────────────────────────────
RAID_DEV="/dev/md0"

# ── Verificar dependencias ─────────────────────────────────────────────────────
info "Verificando dependencias..."
if ! command -v mdadm &>/dev/null; then
    warn "mdadm no encontrado — instalando..."
    apt-get install -y --no-install-recommends mdadm -q
fi
log "Dependencias verificadas."

# ── Advertencia de destrucción de datos ────────────────────────────────────────
echo ""
warn "═══════════════════════════════════════════════════════"
warn "  ¡ATENCIÓN! Los siguientes discos serán LIMPIADOS:"
for disk in "${DISKS[@]}"; do
    warn "    → $disk"
done
warn "  Se borrará toda la información existente en ellos."
warn "═══════════════════════════════════════════════════════"
echo ""
read -rp "¿Continuar? (sí/no): " confirm
if [[ "$confirm" != "sí" && "$confirm" != "sí" && "$confirm" != "si" && "$confirm" != "SI" ]]; then
    err "Operación cancelada por el usuario."
    exit 1
fi

# ── Limpiar estado previo (idempotente) ────────────────────────────────────────
info "Limpiando estado previo si existe..."

# Detener RAID existente sobre el dispositivo md0
if [[ -b "${RAID_DEV}" ]]; then
    mdadm --stop "${RAID_DEV}" 2>/dev/null && warn "RAID ${RAID_DEV} detenido"
fi

# Detener RAID existente que use alguno de los discos
for disk in "${DISKS[@]}"; do
    existing_md=$(mdadm --examine "$disk" 2>/dev/null | grep -oP '/dev/md\d+' | head -1 || true)
    if [[ -n "$existing_md" ]]; then
        mdadm --stop "$existing_md" 2>/dev/null && warn "RAID existente detenido: $existing_md"
    fi
done

# Limpiar superbloques RAID previos en los discos
for disk in "${DISKS[@]}"; do
    mdadm --zero-superblock "$disk" 2>/dev/null && warn "Superbloque limpiado en $disk" || true
done

# ── Borrar tablas de particiones ───────────────────────────────────────────────
info "Borrando tablas de particiones existentes..."
for disk in "${DISKS[@]}"; do
    wipefs -a "$disk" &>/dev/null && warn "Firmas borradas en $disk" || true
done
log "Discos limpios."

# ── Crear RAID 1 ──────────────────────────────────────────────────────────────
info "Creando RAID 1 con ${#DISKS[@]} disco(s)..."
mdadm --create "${RAID_DEV}" \
      --level=1 \
      --raid-devices="${#DISKS[@]}" \
      --metadata=1.2 \
      --run \
      "${DISKS[@]}" <<< "yes"

sleep 2
log "RAID 1 creado en ${RAID_DEV} con ${#DISKS[@]} disco(s)"

# ── Verificar RAID ─────────────────────────────────────────────────────────────
info "Estado del RAID (/proc/mdstat):"
echo "────────────────────────────────────"
cat /proc/mdstat
echo "────────────────────────────────────"
mdadm --detail "${RAID_DEV}"

# ── Guardar configuración de mdadm ────────────────────────────────────────────
info "Guardando configuración de mdadm..."
mdadm --detail --scan >> /etc/mdadm/mdadm.conf 2>/dev/null || \
    mdadm --detail --scan >> /etc/mdadm.conf 2>/dev/null || true
update-initramfs -u &>/dev/null || true
log "Configuración de mdadm actualizada."

# ── Resumen ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            RAID 1 — Configuración completada         ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
i=0
for disk in "${DISKS[@]}"; do
    echo "  Disco $((++i))          : ${disk}"
done
echo "  RAID Device      : ${RAID_DEV}  (RAID 1 — mirror, ${#DISKS[@]} discos)"
echo ""
echo -e "${YELLOW}  Siguiente paso — ejecutar setup_lvm.sh para crear LVM sobre el RAID:${NC}"
echo "    sudo bash scripts/storage/setup_lvm.sh"
echo ""
echo -e "${YELLOW}  Para verificar el RAID en cualquier momento:${NC}"
echo "    cat /proc/mdstat"
echo "    sudo mdadm --detail ${RAID_DEV}"