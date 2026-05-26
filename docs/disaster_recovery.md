# Runbook de Recuperación ante Fallos — Disaster Recovery

**Proyecto:** Infraestructura TI — Sistema Integrado de Gestión (SIG)  
**Unidad para la Atención y Reparación Integral a las Víctimas**  
**Tarea:** HA-3 | Universidad del Quindío — Semestre 2026-1

---

## Objetivos de Recuperación

| Métrica | Valor | Descripción |
|---|---|---|
| **RPO** (Recovery Point Objective) | 24 horas | Máxima pérdida de datos aceptable |
| **RTO** (Recovery Time Objective) | 2 horas | Tiempo máximo para restablecer el servicio completo |

---

## Escenario 1 — Fallo de Contenedor Web

**Síntomas:** `localhost:8082` o `localhost:8083` no responden. `podman ps` muestra el contenedor como `Exited` o `unhealthy`.

**Tiempo estimado de recuperación:** 2–5 minutos

### Diagnóstico

```bash
# Ver estado de todos los contenedores
podman ps -a --format "table {{.Names}}\t{{.Status}}"

# Ver logs del contenedor fallido
podman logs srv-web-01 --tail=50
podman logs srv-web-02 --tail=50
```

### Recuperación

```bash
# Reiniciar el contenedor específico
podman restart srv-web-01
# o
podman restart srv-web-02

# Si el contenedor no responde al restart, recrearlo
cd /home/daniel/Documents/uv-infra-ti/docker
podman-compose up -d srv-web-01
```

### Verificación

```bash
# Confirmar que está healthy
podman ps --filter name=srv-web-01 --format "{{.Status}}"
# Debe mostrar: Up X minutes (healthy)

# Probar respuesta HTTP
wget -qO- http://localhost:8082 | head -5
```

---

## Escenario 2 — Fallo de Base de Datos

**Síntomas:** Aplicaciones web muestran error de conexión. `podman ps` muestra `srv-db-01` como `Exited` o `unhealthy`. `pg_isready` falla.

**Tiempo estimado de recuperación:** 15–30 minutos (sin pérdida de datos) / hasta 2 horas (restauración desde backup)

### Diagnóstico

```bash
# Ver estado del contenedor
podman ps -a --filter name=srv-db-01

# Ver logs de PostgreSQL
podman logs srv-db-01 --tail=100

# Verificar conectividad
podman exec srv-db-01 pg_isready -U uv_admin -d uv_sig
```

### Recuperación — Opción A: Reinicio simple

```bash
# Si el contenedor simplemente se cayó
podman restart srv-db-01

# Esperar a que esté healthy (máx. 60s)
watch -n 5 'podman ps --filter name=srv-db-01 --format "{{.Status}}"'
```

### Recuperación — Opción B: Restauración desde backup

```bash
# 1. Identificar el backup más reciente
ls -lht /mnt/uv_logs/backups/db/

# 2. Levantar el contenedor limpio
cd /home/daniel/Documents/uv-infra-ti/docker
podman-compose up -d srv-db-01

# 3. Esperar a que PostgreSQL esté listo
sleep 30
podman exec srv-db-01 pg_isready -U uv_admin -d uv_sig

# 4. Restaurar desde el backup
podman exec -i srv-db-01 psql -U uv_admin -d uv_sig \
    < /mnt/uv_logs/backups/db/backup_YYYYMMDD.sql

# 5. Verificar integridad
podman exec srv-db-01 psql -U uv_admin -d uv_sig \
    -c "SELECT COUNT(*) FROM sig.victimas;"
```

### Verificación

```bash
podman exec srv-db-01 pg_isready -U uv_admin -d uv_sig
# Respuesta esperada: /var/run/postgresql:5432 - accepting connections
```

---

## Escenario 3 — Fallo de Disco (RAID degradado)

**Síntomas:** `/proc/mdstat` muestra `[U_]` o `[_U]` (un disco fallido). Alerta de mdadm en logs del sistema.

**Tiempo estimado de recuperación:** 10 minutos (comandos) + tiempo de resincronización (~5 min por GB)

### Diagnóstico

```bash
# Ver estado del RAID
cat /proc/mdstat

# Detalle completo
sudo mdadm --detail /dev/md0

# Ver qué disco falló
sudo mdadm --detail /dev/md0 | grep -E "State|Failed|Active"
```

### Recuperación

```bash
# 1. Identificar el disco fallido (aparece como 'faulty')
sudo mdadm --detail /dev/md0 | grep faulty

# 2. Remover el disco fallido
sudo mdadm /dev/md0 --remove /dev/loop0   # ajustar según cuál falló

# 3. Crear nuevo disco virtual de reemplazo
dd if=/dev/zero of=/tmp/uv_raid_disks/disk0_new.img bs=1M count=500 status=progress

# 4. Montar como nuevo loop device
LOOP_NEW=$(sudo losetup --find --show /tmp/uv_raid_disks/disk0_new.img)
echo "Nuevo loop device: $LOOP_NEW"

# 5. Agregar al RAID
sudo mdadm /dev/md0 --add $LOOP_NEW

# 6. Monitorear reconstrucción
watch -n 10 'cat /proc/mdstat'
# Esperar hasta ver [UU] — ambos discos activos y sincronizados
```

### Verificación

```bash
cat /proc/mdstat
# Debe mostrar: md0 : active raid1 ... [2/2] [UU]

sudo mdadm --detail /dev/md0 | grep "State"
# Debe mostrar: State : clean
```

---

## Escenario 4 — Fallo Total (Despliegue desde cero)

**Síntomas:** Máquina no arranca, pérdida total del entorno, o migración a nuevo servidor.

**Tiempo estimado de recuperación:** 45–90 minutos

### Procedimiento completo

```bash
# 1. Clonar el repositorio
git clone https://github.com/DanielJNarvaezH/uv-infra-ti.git
cd uv-infra-ti

# 2. Configurar variables de entorno
cp docker/.env.example docker/.env
# Editar docker/.env con las credenciales del equipo (compartidas por WhatsApp)
nano docker/.env

# 3. Colocar keys.json del proxy manualmente
# docker/web/proxy/data/keys.json  ← obtener del equipo

# 4. Despliegue completo automatizado
sudo bash scripts/automation/deploy.sh

# El script ejecuta en orden:
#   - Reglas de firewall (UFW)
#   - RAID 1 con discos virtuales        ← EN VM, no en host real
#   - LVM sobre RAID
#   - Usuarios, grupos y permisos
#   - Configuración Samba
#   - Stack de contenedores (podman-compose up)
#   - Cron job de backup (2:00 AM diario)
```

### Restaurar datos desde backup

```bash
# 5. Una vez que los contenedores están healthy, restaurar BD
podman exec -i srv-db-01 psql -U uv_admin -d uv_sig \
    < /ruta/al/backup/db/backup_YYYYMMDD.sql

# 6. Restaurar archivos Samba
tar -xzf /ruta/al/backup/files/samba_YYYYMMDD.tar.gz -C /mnt/uv_files/

# 7. Verificar todo el stack
podman ps --format "table {{.Names}}\t{{.Status}}"
sudo bash scripts/storage/verify_persistence.sh
sudo ufw status verbose
```

### Verificación final

```bash
# Todos los servicios healthy
podman ps --format "table {{.Names}}\t{{.Status}}"

# Páginas web respondiendo
wget -qO- http://localhost:8082 | head -3
wget -qO- http://localhost:8083 | head -3

# Firewall activo
sudo ufw status verbose | head -5

# RAID y LVM activos
cat /proc/mdstat
df -h /mnt/uv_db /mnt/uv_files /mnt/uv_logs
```

---

## Resumen de Tiempos de Recuperación

| Escenario | RTO estimado | RPO | Automatización |
|---|---|---|---|
| Fallo de contenedor web | 2–5 min | 0 (sin pérdida) | `podman restart` |
| Fallo de BD — reinicio | 15 min | 0 (sin pérdida) | `podman restart` |
| Fallo de BD — restauración | 30–60 min | 24 horas (último backup) | Script backup.sh |
| Fallo de disco RAID | 10 min + resync | 0 (RAID espejo) | `mdadm --add` |
| Fallo total | 45–90 min | 24 horas (último backup) | `deploy.sh` + restauración manual |

---

## Contactos de Escalamiento

| Rol | Responsable | Acción |
|---|---|---|
| Administrador principal | Daniel Josué Narváez | Coordinar recuperación |
| Administrador BD | Juan Diego García | Recuperación PostgreSQL |
| Administrador infraestructura | David Felipe Pedraza | RAID, LVM, contenedores |
