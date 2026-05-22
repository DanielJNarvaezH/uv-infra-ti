#!/bin/bash

# Creando RAID 1

set -e

if [[ $# -lt 2 ]]; then
    echo "Error: Se requieren al menos 2 discos para RAID 1" >&2
    echo "Uso: $0 /dev/sdb /dev/sdc [/dev/sdd ...]" >&2
    exit 1
fi

for disk in "$@"; do
    if [[ ! -b "$disk" ]]; then
        echo "Error: $disk no es un dispositivo de bloque válido" >&2
        exit 1
    fi
done

if ! command -v mdadm &> /dev/null; then
    sudo apt update
    sudo apt install mdadm -y
fi

num_disks=$#

echo "Creando RAID 1 con $num_disks discos: $*"
sudo mdadm --create /dev/md0 --level=1 --raid-devices="$num_disks" "$@"

echo "RAID creado exitosamente"
sudo mdadm --detail /dev/md0

echo "=== Instalando LVM si es necesario ==="
if ! command -v pvcreate &> /dev/null; then
    sudo apt update
    sudo apt install lvm2 -y
fi

echo "=== Creando Physical Volume (PV) ==="
sudo pvcreate /dev/md0
sudo pvs

echo "=== Creando Volume Group (VG) ==="
VG_NAME="vg_data"
sudo vgcreate "$VG_NAME" /dev/md0
sudo vgs

echo "=== Creando Logical Volume (LV) - usando 100% del VG ==="
LV_NAME="lv_data"
sudo lvcreate -l 100%FREE -n "$LV_NAME" "$VG_NAME"
sudo lvs

LV_PATH="/dev/$VG_NAME/$LV_NAME"
MOUNT_POINT="/mnt/data"

echo "=== Formateando con ext4 ==="
sudo mkfs.ext4 -F "$LV_PATH"

echo "=== Creando punto de montaje ==="
sudo mkdir -p "$MOUNT_POINT"

echo "=== Montando ==="
sudo mount "$LV_PATH" "$MOUNT_POINT"

echo "=== Agregando a /etc/fstab para montaje automático ==="
FSTAB_ENTRY="$LV_PATH  $MOUNT_POINT  ext4  defaults  0  2"
if sudo grep -qF "$MOUNT_POINT" /etc/fstab; then
    echo "Ya existe una entrada para $MOUNT_POINT en /etc/fstab, se omite"
else
    echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab > /dev/null
    echo "Entrada agregada a /etc/fstab"
fi

echo ""
echo "=== Verificando montaje ==="
df -h "$MOUNT_POINT"

echo ""
echo "=== Instalación completada ==="
echo "RAID 1     : /dev/md0"
echo "PV         : /dev/md0"
echo "VG         : $VG_NAME"
echo "LV         : $LV_PATH"
echo "Montaje    : $MOUNT_POINT"
echo "FSTAB      : $FSTAB_ENTRY"


