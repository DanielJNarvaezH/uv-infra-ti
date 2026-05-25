# Almacenamiento — Integración LVM con Contenedores Docker
## ALM-3: Volúmenes Persistentes para srv-db-01 y srv-files-01
### Unidad para la Atención y Reparación Integral a las Víctimas — SIG

**Proyecto:** Administración de Infraestructura TI  
**Equipo:** Daniel Josué Narváez Hincapié · Juan Diego García Nieto · David Felipe Pedraza Bedoya  
**Universidad del Quindío — Semestre 2026-1**  
**Tareas relacionadas:** ALM-1 (RAID 1) · ALM-2 (LVM) · ALM-3 (Integración con Docker)  
**Sprint 3**

---

## 1. Objetivo

Integrar los Logical Volumes creados en ALM-2 con los contenedores de base de datos (`srv-db-01`) y archivos (`srv-files-01`), de forma que los datos persistan independientemente del ciclo de vida de los contenedores. Esta separación entre almacenamiento y cómputo garantiza que un reinicio, fallo o recreación de contenedor nunca resulte en pérdida de datos del SIG.

---

## 2. Arquitectura de Almacenamiento

```
Host Linux
│
├── /dev/loop0, /dev/loop1          ← Discos virtuales (ALM-1: setup_raid.sh)
│       │
│       └── /dev/md0  (RAID 1)     ← Espejo automático de ambos discos
│               │
│               └── uv_vg  (LVM)   ← Volume Group (ALM-2: setup_lvm.sh)
│                       │
│                       ├── lv_db    (40%) → /mnt/uv_db
│                       │       │
│                       │       └── bind mount → srv-db-01:/var/lib/postgresql/data
│                       │
│                       ├── lv_files (40%) → /mnt/uv_files
│                       │       │
│                       │       └── bind mount → srv-files-01:/srv/uv_docs
│                       │
│                       └── lv_logs  (20%) → /mnt/uv_logs
│                               └── Logs del sistema + backups automáticos
```

### Flujo de datos en operación normal

```
Aplicación PHP (srv-web-01/02)
    │  SQL query
    ▼
srv-db-01 (PostgreSQL)
    │  escribe en /var/lib/postgresql/data
    │      ↕  (bind mount)
    ▼
/mnt/uv_db  (host) ← lv_db sobre RAID 1
    │  escrito en ambos discos por md0
    ▼
/dev/loop0 + /dev/loop1
```

---

## 3. Configuración en docker-compose.yml

La integración se implementa con **bind mounts de tipo `bind`** en el `docker-compose.yml`. A diferencia de los volúmenes nombrados de Docker/Podman, los bind mounts apuntan directamente a rutas del host — en este caso, a los puntos de montaje LVM.

### 3.1 srv-db-01 — Base de Datos PostgreSQL

```yaml
srv-db-01:
  build:
    context: ./db
    dockerfile: Dockerfile
  # ...
  volumes:
    # ALM-3: /mnt/uv_db → lv_db sobre RAID 1 (LVM)
    # El directorio debe existir en el host antes de levantar:
    #   sudo mkdir -p /mnt/uv_db
    #   sudo chown 999:999 /mnt/uv_db   # UID/GID del usuario postgres
    - type: bind
      source: /mnt/uv_db
      target: /var/lib/postgresql/data

    # Scripts de inicialización (solo lectura — no persistente)
    - type: bind
      source: ./db/init
      target: /docker-entrypoint-initdb.d
      read_only: true
```

**Decisión técnica:** PostgreSQL almacena su directorio de datos en `/var/lib/postgresql/data` dentro del contenedor. Al mapearlo a `/mnt/uv_db` (LV sobre RAID 1), cada escritura de la BD queda espejada automáticamente en dos discos. El UID/GID `999` corresponde al usuario `postgres` de la imagen `postgres:16` oficial.

### 3.2 srv-files-01 — Servidor de Archivos Samba

```yaml
srv-files-01:
  build:
    context: ./files
    dockerfile: Dockerfile
  # ...
  volumes:
    # ALM-3: /mnt/uv_files → lv_files sobre RAID 1 (LVM)
    # El directorio debe existir en el host antes de levantar:
    #   sudo mkdir -p /mnt/uv_files
    #   sudo chown root:1050 /mnt/uv_files   # GID 1050 = g_files
    #   sudo chmod 2770 /mnt/uv_files
    - type: bind
      source: /mnt/uv_files
      target: /srv/uv_docs
```

**Decisión técnica:** El share Samba `[uv_docs]` sirve `/srv/uv_docs` dentro del contenedor. Al vincularlo con `/mnt/uv_files` en el host, los documentos institucionales del SIG quedan en almacenamiento redundante. El SETGID (`chmod 2770`) garantiza herencia de grupo para nuevos archivos.

---

## 4. Preparación del Host (prerrequisitos ALM-3)

Estos pasos deben ejecutarse **antes** de `docker-compose up` o `start.sh`. El script `deploy.sh` los ejecuta automáticamente en orden.

```bash
# ─── 1. Ejecutar RAID 1 (ALM-1) ───────────────────────────────────────────
sudo bash scripts/storage/setup_raid.sh 500
# Resultado: /dev/md0 activo (espejo de /dev/loop0 + /dev/loop1)

# ─── 2. Configurar LVM sobre RAID (ALM-2) ─────────────────────────────────
sudo bash scripts/storage/setup_lvm.sh
# Resultado:
#   /dev/uv_vg/lv_db    montado en /mnt/uv_db    (40%)
#   /dev/uv_vg/lv_files montado en /mnt/uv_files (40%)
#   /dev/uv_vg/lv_logs  montado en /mnt/uv_logs  (20%)

# ─── 3. Ajustar permisos del punto de montaje para PostgreSQL ─────────────
sudo chown 999:999 /mnt/uv_db
# El UID 999 es el usuario 'postgres' dentro de la imagen postgres:16

# ─── 4. Ajustar permisos para Samba/g_files ───────────────────────────────
sudo chown root:1050 /mnt/uv_files   # GID 1050 = g_files
sudo chmod 2770 /mnt/uv_files        # SETGID + rwx para root y g_files

# ─── 5. Verificar que los puntos de montaje están listos ──────────────────
mountpoint /mnt/uv_db && echo "OK"
mountpoint /mnt/uv_files && echo "OK"
df -h /mnt/uv_db /mnt/uv_files /mnt/uv_logs

# ─── 6. Levantar el stack ──────────────────────────────────────────────────
sudo bash scripts/start.sh
```

### Verificación de mounts antes de levantar contenedores

```
$ df -h /mnt/uv_db /mnt/uv_files /mnt/uv_logs
Filesystem                      Size  Used Avail Use% Mounted on
/dev/mapper/uv_vg-lv_db         193M  1.6M  178M   1% /mnt/uv_db
/dev/mapper/uv_vg-lv_files      193M  1.6M  178M   1% /mnt/uv_files
/dev/mapper/uv_vg-lv_logs        87M  1.6M   79M   2% /mnt/uv_logs
```

---

## 5. Verificación de Persistencia

El script `scripts/storage/verify_persistence.sh` automatiza el ciclo completo de verificación:

```bash
sudo bash scripts/storage/verify_persistence.sh
```

### Secuencia de la prueba

```
[1] Verificar prerequisitos
    ├── mountpoint /mnt/uv_db    → OK
    ├── mountpoint /mnt/uv_files → OK
    └── contenedores healthy     → OK

[2] Escribir datos de prueba
    ├── echo "..." > /mnt/uv_db/alm3_test_<ts>.marker
    ├── echo "..." > /mnt/uv_files/alm3_test_<ts>.marker
    └── INSERT INTO sig.alm3_persistence_test (valor)

[3] Reiniciar contenedores
    ├── podman stop srv-db-01 srv-files-01
    ├── (verificar: LVMs siguen montados sin contenedores)
    └── podman start srv-db-01 srv-files-01

[4] Verificar persistencia
    ├── cat /mnt/uv_db/alm3_test_<ts>.marker   → datos intactos
    ├── cat /mnt/uv_files/alm3_test_<ts>.marker → datos intactos
    ├── md5sum (checksum antes = checksum después)
    └── SELECT valor FROM sig.alm3_persistence_test

[5] Verificar esquema uv_sig
    ├── pg_isready                → OK
    ├── sig.victimas exists       → OK
    ├── sig.atenciones exists     → OK
    ├── sig.proceso_reparacion    → OK
    └── COUNT(*) sig.victimas     → 3 (seed cargado)
```

### Salida esperada (ejecución exitosa)

```
━━━ 1. Verificando prerrequisitos ━━━
[OK]    /mnt/uv_db  montado
[OK]    /mnt/uv_files montado
[OK]    Contenedor srv-db-01 corriendo
[OK]    Contenedor srv-files-01 corriendo
[OK]    srv-db-01 health: healthy
[OK]    srv-files-01 health: healthy
[OK]    docker-compose.yml referencia /mnt/uv_db  (bind mount configurado)
[OK]    docker-compose.yml referencia /mnt/uv_files (bind mount configurado)

━━━ 2. Escribiendo datos de prueba (antes del reinicio) ━━━
[OK]    Marker escrito en /mnt/uv_db/alm3_test_1234567890.marker
[OK]    Marker escrito en /mnt/uv_files/alm3_test_1234567890.marker
[OK]    Registro de prueba insertado en sig.alm3_persistence_test

━━━ 3. Reiniciando contenedores ━━━
[OK]    Contenedores detenidos.
[OK]    /mnt/uv_db   persiste con contenedor detenido
[OK]    /mnt/uv_files persiste con contenedor detenido
[OK]    Contenedores reiniciados.
[OK]    Ambos contenedores healthy tras 35s

━━━ 4. Verificando persistencia tras el reinicio ━━━
[OK]    Marker en /mnt/uv_db    PERSISTE: ALM-3 persistence test — 2026-05-10 02:00:01
[OK]    Marker en /mnt/uv_files PERSISTE: ALM-3 persistence test — 2026-05-10 02:00:01
[OK]    Integridad del marker verificada (checksum MD5 coincide)

━━━ 5. Verificando integridad del esquema uv_sig ━━━
[OK]    PostgreSQL acepta conexiones (pg_isready)
[OK]    Tabla sig.victimas existe
[OK]    Tabla sig.atenciones existe
[OK]    Tabla sig.proceso_reparacion existe
[OK]    Tabla sig.eventos_participacion existe
[OK]    Datos de seed intactos: 3 víctima(s) en sig.victimas
[OK]    Registro de prueba ALM-3 persiste en BD

╔══════════════════════════════════════════════════════════════════╗
║   ✓  ALM-3 VERIFICADO — Persistencia confirmada               ║
║   Pruebas pasadas: 19  │  Fallidas: 0                         ║
╚══════════════════════════════════════════════════════════════════╝
```

---

## 6. Comparativa: Bind Mount vs Volumen Nombrado

En este proyecto se eligió **bind mount** sobre volumen nombrado por las siguientes razones:

| Criterio | Bind Mount (`/mnt/uv_db`) | Volumen nombrado (`podman volume`) |
|----------|--------------------------|-------------------------------------|
| Control del almacenamiento | Total — el path es el LV | Gestionado por Podman |
| Integración con LVM/RAID | Directa — el path ES el LV | Requiere configuración extra |
| Visibilidad desde el host | Inmediata — `ls /mnt/uv_db` | Requiere `podman volume inspect` |
| Backup (`pg_dump`, `tar`) | Acceso directo al path | Acceso a través del daemon |
| Portabilidad | Depende del path del host | El nombre es portable |
| Gestión de permisos | Explícita (`chown 999:999`) | Manejada por Podman |
| **Veredicto para el SIG** | **✓ Elegido — control total sobre RAID 1** | No elegido |

---

## 7. Persistencia del Montaje LVM al Reiniciar el Host

El script `setup_lvm.sh` agrega automáticamente las entradas a `/etc/fstab`:

```
# Contenido agregado por setup_lvm.sh (ALM-2)
/dev/uv_vg/lv_db    /mnt/uv_db    ext4  defaults  0  2
/dev/uv_vg/lv_files /mnt/uv_files ext4  defaults  0  2
/dev/uv_vg/lv_logs  /mnt/uv_logs  ext4  defaults  0  2
```

Sin embargo, como los discos virtuales (`/dev/loop*`) y el RAID (`/dev/md0`) se crean desde imágenes en `/tmp`, **no persisten al reiniciar el host**. En un entorno de producción con discos físicos dedicados, este paso no sería necesario — los LV se reconocen automáticamente al arrancar.

### Para hacer el entorno de desarrollo persistente al reboot

```bash
# Agregar al crontab de root o a un servicio systemd:
@reboot sudo bash /ruta/al/proyecto/scripts/storage/setup_raid.sh 500
@reboot sudo bash /ruta/al/proyecto/scripts/storage/setup_lvm.sh
@reboot sudo bash /ruta/al/proyecto/scripts/start.sh
```

---

## 8. Monitoreo del Almacenamiento

### Comandos de verificación rápida

```bash
# Estado del RAID
cat /proc/mdstat
sudo mdadm --detail /dev/md0

# Espacio en LVs
df -h /mnt/uv_db /mnt/uv_files /mnt/uv_logs

# Logical Volumes
sudo lvdisplay
sudo lvs

# Bind mounts activos en cada contenedor
podman inspect srv-db-01 \
    --format '{{range .Mounts}}{{.Source}} → {{.Destination}}{{"\n"}}{{end}}'

podman inspect srv-files-01 \
    --format '{{range .Mounts}}{{.Source}} → {{.Destination}}{{"\n"}}{{end}}'

# Health de los contenedores
podman ps --format "table {{.Names}}\t{{.Status}}"
```

### Alertas de espacio (integrado en backup.sh)

El script `scripts/automation/backup.sh` registra el espacio disponible en `/mnt/uv_logs` al final de cada ejecución. Si el espacio cae por debajo del umbral, la alerta se envía por SMTP a `srv-smtp-01`.

---

## 9. Tabla de Evidencia de Configuración

| Elemento | Valor configurado | Script/Archivo |
|----------|-------------------|----------------|
| LV de BD | `/dev/uv_vg/lv_db` (40% del VG) | `setup_lvm.sh` |
| Mount BD | `/mnt/uv_db` (ext4) | `setup_lvm.sh` |
| Bind mount BD | `/mnt/uv_db` → `srv-db-01:/var/lib/postgresql/data` | `docker-compose.yml` |
| LV de Archivos | `/dev/uv_vg/lv_files` (40% del VG) | `setup_lvm.sh` |
| Mount Archivos | `/mnt/uv_files` (ext4, SETGID 2770) | `setup_lvm.sh` + `samba-setup.sh` |
| Bind mount Archivos | `/mnt/uv_files` → `srv-files-01:/srv/uv_docs` | `docker-compose.yml` |
| LV de Logs | `/dev/uv_vg/lv_logs` (20% del VG) | `setup_lvm.sh` |
| Respaldo | `pg_dump` diario en `/mnt/uv_logs/backups/` | `backup.sh` |
| Verificación | Ciclo stop → start → check | `verify_persistence.sh` |
| Persistencia fstab | 3 entradas en `/etc/fstab` | `setup_lvm.sh` |

---

## 10. Troubleshooting

### El contenedor srv-db-01 no arranca (permisos en /mnt/uv_db)

```bash
# Síntoma: FATAL: data directory has wrong ownership
sudo chown 999:999 /mnt/uv_db
podman restart srv-db-01
```

### El directorio /mnt/uv_db no existe o no está montado

```bash
# Verificar si el LV está activo
sudo lvs
# Si no hay salida, el RAID no se inicializó
sudo bash scripts/storage/setup_raid.sh 500
sudo bash scripts/storage/setup_lvm.sh
```

### PostgreSQL reinicia pero el esquema uv_sig no existe

```bash
# El esquema solo se crea la PRIMERA vez que el contenedor arranca con /mnt/uv_db vacío.
# Si el volumen ya tiene datos previos de PG sin el esquema:
podman exec -it srv-db-01 psql -U uv_admin -d uv_sig -f /docker-entrypoint-initdb.d/01_schema.sql
podman exec -it srv-db-01 psql -U uv_admin -d uv_sig -f /docker-entrypoint-initdb.d/02_seed.sql
```

### Samba no puede escribir en /mnt/uv_files

```bash
# Verificar grupo y permisos SETGID
ls -ld /mnt/uv_files
# Esperado: drwxrws--- root g_files ...  (la 's' indica SETGID)
sudo chown root:1050 /mnt/uv_files
sudo chmod 2770 /mnt/uv_files
podman restart srv-files-01
```

---

*Documento generado para Sprint 3 — ALM-3 | Proyecto Final Administración de Infraestructura TI | Universidad del Quindío 2026-1*