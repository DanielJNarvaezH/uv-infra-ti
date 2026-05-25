# Almacenamiento Persistente con LVM — ALM-3
## Infraestructura TI SIG — Unidad de Víctimas
### Universidad del Quindío | Semestre 2026-1

**Tarea:** ALM-3 — Integrar volúmenes LVM con contenedores Docker  
**Sprint:** Sprint 3 (11 may – 17 may)  
**Responsables:** Daniel Josué Narváez Hincapié · Juan Diego García Nieto · David Felipe Pedraza Bedoya

---

## 1. Objetivo

Reemplazar los volúmenes nombrados de Docker/Podman (`pgdata`, `samba_data`) por **bind mounts** apuntando a directorios del host que están respaldados por **volúmenes LVM** sobre un array **RAID 1**, garantizando:

- **Persistencia real:** los datos sobreviven reinicios del contenedor y del host.
- **Redundancia de disco:** RAID 1 protege contra fallo de un disco físico.
- **Gestión flexible:** LVM permite redimensionar los volúmenes sin reformatear.
- **Separación de responsabilidades:** un LV independiente por servicio.

---

## 2. Arquitectura de almacenamiento

```
Discos físicos (ej. /dev/sdb + /dev/sdc)
        │
        ▼
  /dev/md0  ←── RAID 1 (espejo, mdadm)
        │
        ▼
   vg_uv  ←── Volume Group (LVM)
   ├── lv_db    (60%)  →  /mnt/uv_db    →  srv-db-01    /var/lib/postgresql/data
   └── lv_files (40%)  →  /mnt/uv_files  →  srv-files-01 /srv/uv_docs
```

| Capa | Componente | Propósito |
|------|------------|-----------|
| RAID 1 | `/dev/md0` | Redundancia: datos escritos en ambos discos simultáneamente |
| PV | `/dev/md0` | Physical Volume LVM — punto de entrada al stack LVM |
| VG | `vg_uv` | Volume Group — agrupa la capacidad del RAID |
| LV | `lv_db` (60% VG) | Logical Volume para PostgreSQL |
| LV | `lv_files` (40% VG) | Logical Volume para Samba |
| Filesystem | ext4 | Formato de los LVs (labels: `uv_db`, `uv_files`) |
| Bind mount | `/mnt/uv_db` | Punto de montaje del host → interior del contenedor |
| Bind mount | `/mnt/uv_files` | Punto de montaje del host → interior del contenedor |

---

## 3. Aprovisionamiento del host

### 3.1 Prerequisitos

```bash
# Verificar que los discos están disponibles
lsblk

# Ejemplo de salida esperada:
# NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
# sdb      8:16   0   20G  0 disk
# sdc      8:32   0   20G  0 disk
```

> ⚠️ Los discos `/dev/sdb` y `/dev/sdc` deben estar sin particiones ni datos. El script los sobreescribe sin confirmación adicional.

### 3.2 Ejecutar el script de aprovisionamiento

```bash
# Desde la raíz del proyecto
sudo bash scripts/raid-lvm.sh /dev/sdb /dev/sdc
```

El script realiza automáticamente todos los pasos descritos en las secciones 3.3 a 3.7.

### 3.3 Creación del RAID 1

```bash
# Creación manual (referencia — el script lo hace automáticamente)
sudo mdadm --create /dev/md0 \
    --level=1 \
    --raid-devices=2 \
    --metadata=1.2 \
    --run \
    /dev/sdb /dev/sdc

# Verificar estado del RAID
sudo mdadm --detail /dev/md0
```

**Salida de referencia — `mdadm --detail /dev/md0`:**

```
/dev/md0:
           Version : 1.2
     Creation Time : Sat May 17 10:23:41 2025
        Raid Level : raid1
        Array Size : 20955136 (19.98 GiB 21.46 GB)
     Used Dev Size : 20955136 (19.98 GiB 21.46 GB)
      Raid Devices : 2
     Total Devices : 2
       Persistence : Superblock is persistent

       Update Time : Sat May 17 10:23:58 2025
             State : clean
    Active Devices : 2
   Working Devices : 2
    Failed Devices : 0
     Spare Devices : 0

Consistency Policy : resync

              Name : srv:0
              UUID : a1b2c3d4:e5f60718:9a0b1c2d:3e4f5061
            Events : 17

    Number   Major   Minor   RaidDevice State
       0       8       16        0      active sync   /dev/sdb
       1       8       32        1      active sync   /dev/sdc
```

### 3.4 Creación del stack LVM

```bash
# Physical Volume
sudo pvcreate /dev/md0

# Volume Group
sudo vgcreate vg_uv /dev/md0

# Logical Volumes — 60% para BD, 40% para archivos
sudo lvcreate -l 60%VG  -n lv_db    vg_uv
sudo lvcreate -l 100%FREE -n lv_files vg_uv

# Formateo ext4
sudo mkfs.ext4 -L "uv_db"    /dev/vg_uv/lv_db
sudo mkfs.ext4 -L "uv_files" /dev/vg_uv/lv_files

# Verificar LVs creados
sudo lvs vg_uv
```

**Salida de referencia — `lvs vg_uv`:**

```
  LV       VG    Attr       LSize   Pool Origin Data%  Meta%  Move Log Cpy%Sync Convert
  lv_db    vg_uv -wi-ao---- <11.99g
  lv_files vg_uv -wi-ao----  <7.99g
```

### 3.5 Montaje y permisos

```bash
# Crear puntos de montaje
sudo mkdir -p /mnt/uv_db /mnt/uv_files

# Montar
sudo mount /dev/vg_uv/lv_db    /mnt/uv_db
sudo mount /dev/vg_uv/lv_files /mnt/uv_files

# Permisos — /mnt/uv_db: usuario postgres (UID/GID 999 en postgres:16)
sudo chown 999:999 /mnt/uv_db
sudo chmod 700 /mnt/uv_db

# Permisos — /mnt/uv_files: root:g_files (GID 1050), SETGID + sticky bit
sudo chown root:1050 /mnt/uv_files
sudo chmod 2770 /mnt/uv_files    # SETGID: archivos heredan grupo g_files
sudo chmod +t /mnt/uv_files      # Sticky: solo propietario puede eliminar

# Verificar
ls -la /mnt/
```

**Salida de referencia — `ls -la /mnt/`:**

```
drwxr-xr-x  4 root root    4096 may 17 10:25 .
drwxr-xr-x 19 root root    4096 may 17 10:25 ..
drwx------  3  999  999    4096 may 17 10:26 uv_db
drwxrws--T  2 root 1050    4096 may 17 10:26 uv_files
```

> La `s` en el grupo de `uv_files` confirma el **SETGID**, y la `T` confirma el **sticky bit**.

### 3.6 Persistencia en /etc/fstab

Para que los volúmenes se monten automáticamente al arrancar el host, el script agrega entradas por UUID (más estable que el nombre de dispositivo):

```bash
# Obtener UUIDs
sudo blkid /dev/vg_uv/lv_db
sudo blkid /dev/vg_uv/lv_files
```

**Entradas agregadas a `/etc/fstab`:**

```
UUID=<uuid-lv_db>    /mnt/uv_db     ext4  defaults,nofail  0  2
UUID=<uuid-lv_files> /mnt/uv_files  ext4  defaults,nofail  0  2
```

La opción `nofail` asegura que el sistema arranque aunque los discos no estén disponibles (evita un boot loop en caso de fallo de hardware).

---

## 4. Cambios en docker-compose.yml

### 4.1 Antes (volúmenes nombrados)

```yaml
# srv-db-01 — volumen nombrado gestionado por Podman
volumes:
  - pgdata:/var/lib/postgresql/data:Z
  - ./db/init:/docker-entrypoint-initdb.d:ro,Z

# srv-files-01 — volumen nombrado gestionado por Podman
volumes:
  - samba_data:/srv/uv_docs:Z

# Sección volumes al final del compose
volumes:
  pgdata:
  samba_data:
```

### 4.2 Después — ALM-3 (bind mounts a LVM)

```yaml
# srv-db-01 — bind mount a /mnt/uv_db (LV lv_db sobre RAID 1)
volumes:
  - type: bind
    source: /mnt/uv_db
    target: /var/lib/postgresql/data
  - type: bind
    source: ./db/init
    target: /docker-entrypoint-initdb.d
    read_only: true

# srv-files-01 — bind mount a /mnt/uv_files (LV lv_files sobre RAID 1)
volumes:
  - type: bind
    source: /mnt/uv_files
    target: /srv/uv_docs

# Sección volumes eliminada — ya no se usan volúmenes nombrados
```

### 4.3 Justificación del cambio

| Aspecto | Volumen nombrado (antes) | Bind mount LVM (después) |
|---------|-------------------------|--------------------------|
| Ubicación de datos | Gestionada por Podman (`~/.local/share/containers/...`) | `/mnt/uv_db` y `/mnt/uv_files` en el host |
| Redundancia | Ninguna — depende del disco del host | RAID 1 — espejo en tiempo real |
| Acceso directo al dato | Difícil — requiere `podman volume inspect` | Directo con `ls /mnt/uv_db` |
| Backups | `podman volume export` | `rsync`, `pg_dump`, scripts estándar sobre directorios |
| Redimensionamiento | No posible sin migración | `lvextend` + `resize2fs` en caliente |
| Persistencia ante `podman-compose down -v` | Se pierde | Los datos permanecen en el host |

---

## 5. Despliegue con los volúmenes LVM

```bash
# 1. Aprovisionar RAID + LVM (una sola vez)
sudo bash scripts/raid-lvm.sh /dev/sdb /dev/sdc

# 2. Levantar el stack
cd docker
podman-compose up -d --build srv-db-01 srv-files-01

# 3. Verificar que los contenedores están corriendo y healthy
podman ps --format "table {{.Names}}\t{{.Status}}"
```

**Salida esperada:**

```
NAMES          STATUS
srv-db-01      Up 2 minutes (healthy)
srv-files-01   Up 2 minutes (healthy)
```

---

## 6. Verificación de persistencia

### 6.1 Procedimiento de prueba

```bash
# --- Paso 1: Insertar datos de prueba en la BD ---
podman exec -it srv-db-01 \
    psql -U uv_admin -d uv_sig -c \
    "INSERT INTO sig.funcionarios(nombre, apellido, cargo, email)
     VALUES ('Test','ALM3','Prueba Persistencia','test.alm3@uv.local');"

# --- Paso 2: Confirmar que los datos existen ---
podman exec -it srv-db-01 \
    psql -U uv_admin -d uv_sig -c \
    "SELECT nombre, apellido, email FROM sig.funcionarios WHERE email='test.alm3@uv.local';"

# --- Paso 3: Detener y eliminar el contenedor (simula pérdida del contenedor) ---
podman stop srv-db-01
podman rm srv-db-01

# --- Paso 4: Verificar que los datos persisten en el LV ---
ls -lh /mnt/uv_db/
# Se verá el directorio de datos de PostgreSQL intacto:
# drwx------ 19  999  999 4.0K may 17 10:30 global
# drwx------ 2   999  999 4.0K may 17 10:30 pg_wal
# ...

# --- Paso 5: Levantar el contenedor nuevamente ---
cd docker && podman-compose up -d srv-db-01

# --- Paso 6: Verificar que los datos siguen ahí ---
podman exec -it srv-db-01 \
    psql -U uv_admin -d uv_sig -c \
    "SELECT nombre, apellido, email FROM sig.funcionarios WHERE email='test.alm3@uv.local';"
```

**Salida esperada en el paso 6:**

```
  nombre | apellido |          email
---------+----------+--------------------------
  Test   | ALM3     | test.alm3@uv.local
(1 row)
```

> ✅ La persistencia queda demostrada: los datos sobreviven al ciclo `stop → rm → up` del contenedor.

### 6.2 Prueba de persistencia para Samba

```bash
# --- Crear un archivo de prueba en el share ---
echo "Prueba ALM-3 - $(date)" | \
    podman exec -i srv-files-01 tee /srv/uv_docs/prueba_persistencia.txt

# --- Detener y eliminar el contenedor ---
podman stop srv-files-01 && podman rm srv-files-01

# --- Verificar que el archivo está en el host ---
ls -la /mnt/uv_files/
cat /mnt/uv_files/prueba_persistencia.txt

# --- Levantar de nuevo y verificar ---
cd docker && podman-compose up -d srv-files-01
podman exec srv-files-01 cat /srv/uv_docs/prueba_persistencia.txt
```

---

## 7. Verificación del RAID

```bash
# Estado del array
sudo mdadm --detail /dev/md0

# Monitorear reconstrucción (si un disco falla y se reemplaza)
sudo cat /proc/mdstat

# Ver información de los LVs
sudo lvdisplay vg_uv

# Espacio disponible en los puntos de montaje
df -h /mnt/uv_db /mnt/uv_files
```

**Salida de referencia — `df -h`:**

```
Filesystem                    Size  Used Avail Use% Mounted on
/dev/mapper/vg_uv-lv_db       12G   60M   11G   1% /mnt/uv_db
/dev/mapper/vg_uv-lv_files     8G   20M    8G   1% /mnt/uv_files
```

---

## 8. Procedimiento de expansión de volumen

Si los datos de PostgreSQL superan la capacidad asignada (60% del VG):

```bash
# 1. Agregar un nuevo disco al RAID (en caliente)
sudo mdadm --add /dev/md0 /dev/sdd

# 2. Ampliar el RAID al nuevo disco
sudo mdadm --grow /dev/md0 --raid-devices=3

# 3. Ampliar el PV para reconocer el espacio nuevo
sudo pvresize /dev/md0

# 4. Ampliar el LV (agregar 5 GB como ejemplo)
sudo lvextend -L +5G /dev/vg_uv/lv_db

# 5. Ampliar el filesystem en caliente (sin desmontar)
sudo resize2fs /dev/vg_uv/lv_db

# 6. Verificar
df -h /mnt/uv_db
```

---

## 9. Resumen de configuración

| Parámetro | Valor |
|-----------|-------|
| RAID level | RAID 1 (espejo) |
| Dispositivo RAID | `/dev/md0` |
| Volume Group | `vg_uv` |
| LV para PostgreSQL | `lv_db` (60% VG) → `/mnt/uv_db` |
| LV para Samba | `lv_files` (40% VG) → `/mnt/uv_files` |
| Filesystem | ext4 |
| Permisos `/mnt/uv_db` | `UID 999 : GID 999`, `chmod 700` |
| Permisos `/mnt/uv_files` | `root : GID 1050`, `chmod 2770+t` (SETGID + sticky) |
| Montaje automático | `/etc/fstab` con UUID y opción `nofail` |
| Tipo de volumen en compose | `bind` (antes: named volume `pgdata` / `samba_data`) |

---

## 10. Troubleshooting

### El contenedor srv-db-01 no arranca — "Permission denied"

```bash
# Verificar propietario del directorio
ls -la /mnt/uv_db

# PostgreSQL necesita UID/GID 999 dentro del contenedor
sudo chown 999:999 /mnt/uv_db
sudo chmod 700 /mnt/uv_db
```

### El volumen no se monta al arrancar el host

```bash
# Verificar entradas en fstab
grep uv_ /etc/fstab

# Montar manualmente y verificar errores
sudo mount -a

# Verificar que el VG está activado
sudo vgchange -ay vg_uv
sudo mount /mnt/uv_db
sudo mount /mnt/uv_files
```

### Verificar que un archivo creado en el share hereda el grupo correcto (SETGID)

```bash
# Crear un archivo de prueba dentro del contenedor
podman exec srv-files-01 touch /srv/uv_docs/test_setgid.txt

# Verificar en el host
ls -la /mnt/uv_files/test_setgid.txt
# Salida esperada: el grupo debe ser g_files (GID 1050)
# -rw-r--r-- 1 root 1050 0 may 17 10:40 test_setgid.txt
```

---

*Documento generado para Sprint 3 — ALM-3 | Proyecto Final Administración de Infraestructura TI | Universidad del Quindío 2026-1*
