# Alta Disponibilidad — Estrategia para la Infraestructura TI del SIG

**Proyecto:** Administración de Infraestructura TI — Unidad para la Atención y Reparación Integral a las Víctimas  
**Tarea:** HA-1  
**Equipo:** Daniel Josué Narváez · Juan Diego García Nieto · David Felipe Pedraza Bedoya  
**Universidad del Quindío — Semestre 2026-1**

---

## Contexto: ¿Por qué la Alta Disponibilidad es crítica aquí?

La Unidad para las Víctimas administra el Registro Único de Víctimas (RUV), que contiene información de más de nueve millones de personas afectadas por el conflicto armado colombiano. Una interrupción del servicio no es un inconveniente técnico — es una barrera para que una víctima acceda a su derecho a la reparación integral. Por eso, cada decisión de HA en este proyecto está justificada desde el impacto humano y social, no solo desde la eficiencia técnica.

---

## 1. Balanceo de Carga con Nginx Reverse Proxy

### Diseño

El `srv-proxy-01` (Nginx Proxy Manager) actúa como punto de entrada único para todas las solicitudes HTTP/HTTPS. Detrás de él se distribuye la carga entre tres instancias web:

```
                        ┌─────────────────────┐
   Ciudadano/Internet   │   srv-proxy-01       │  Puerto 80/443
   ──────────────────►  │   Nginx Proxy Manager│  10.0.40.6
                        └──────────┬──────────┘
                                   │  upstream (round-robin)
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
             srv-web-01      srv-web-02      srv-web-03
           Portal ciudadano  Portal RNI    Intranet SUMA
            10.0.40.2        10.0.40.5      10.0.10.5
                    │              │
                    └──────┬───────┘
                           ▼
                     srv-php-fpm
                      10.0.10.8
                    (backend PHP)
```

### Configuración upstream (conceptual para Nginx)

```nginx
upstream uv_web_cluster {
    least_conn;                          # algoritmo: menor conexiones activas
    server srv-web-01:80 weight=1;
    server srv-web-02:80 weight=1;
    server srv-web-03:80 weight=1 backup; # intranet como backup
    keepalive 32;
}

server {
    listen 80;
    location / {
        proxy_pass http://uv_web_cluster;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_next_upstream error timeout http_502 http_503;
    }
}
```

### Justificación

La Unidad atiende ciudadanos en todo el territorio nacional con picos de demanda durante eventos como audiencias de reparación o fechas de pago de indemnizaciones. Un solo servidor web sería un punto único de fallo. Con tres instancias, si `srv-web-01` cae, el proxy redirige automáticamente a `srv-web-02` sin que el ciudadano note la interrupción. La directiva `proxy_next_upstream` garantiza reintentos transparentes ante errores 502/503.

---

## 2. Replicación de PostgreSQL (Primary/Standby)

### Diseño conceptual

```
  srv-db-01 (PRIMARY)          srv-db-02 (STANDBY) — conceptual
  10.0.10.2                    10.0.10.9
  PostgreSQL 16                PostgreSQL 16
  VLAN 10                      VLAN 10
       │                            │
       │  WAL streaming (async)     │
       └────────────────────────────┘
              puerto 5432
```

### Parámetros de configuración (postgresql.conf en PRIMARY)

```ini
wal_level = replica
max_wal_senders = 3
wal_keep_size = 256MB
synchronous_commit = off          # async para no penalizar escrituras
archive_mode = on
archive_command = 'cp %p /mnt/uv_logs/wal_archive/%f'
```

### Parámetros (recovery.conf en STANDBY)

```ini
standby_mode = on
primary_conninfo = 'host=10.0.10.2 port=5432 user=replicator'
restore_command = 'cp /mnt/uv_logs/wal_archive/%f %p'
trigger_file = '/tmp/promote_standby'
```

### Proceso de failover

1. Se detecta que `srv-db-01` no responde (healthcheck falla 3 veces)
2. Administrador ejecuta: `touch /tmp/promote_standby` en el standby
3. El standby se promueve a primary automáticamente
4. Las aplicaciones reconectan a `10.0.10.9`
5. Tiempo de recuperación objetivo (RTO): < 2 minutos

### Justificación

El RUV no puede perder transacciones. La replicación WAL (Write-Ahead Log) garantiza que cada registro confirmado en el primary se replica al standby antes de ser visible. Para la Unidad, esto significa que incluso ante un fallo de hardware en `srv-db-01`, no se pierde ninguna solicitud de atención o registro de reparación completado. El modo asíncrono es aceptable aquí porque el archivado WAL en `/mnt/uv_logs` provee una red de seguridad adicional.

---

## 3. RAID 1 como Redundancia de Almacenamiento

### Diseño (implementado en ALM-1 y ALM-2)

```
  /dev/loop0 (disk0.img)  ◄──── espejo ────►  /dev/loop1 (disk1.img)
          │                                           │
          └─────────────── /dev/md0 (RAID 1) ─────────┘
                                    │
                              uv_vg (LVM)
                         ┌──────────┼──────────┐
                         ▼          ▼          ▼
                      lv_db      lv_files   lv_logs
                    /mnt/uv_db  /mnt/uv_files  /mnt/uv_logs
                    PostgreSQL    Samba       Backups/Logs
```

### Comportamiento ante fallo

| Evento | Respuesta del sistema | Impacto para el usuario |
|---|---|---|
| Fallo de `loop0` | RAID 1 continúa con `loop1` | Ninguno — servicio continúa |
| Fallo de `loop1` | RAID 1 continúa con `loop0` | Ninguno — servicio continúa |
| Fallo de ambos | Pérdida de datos | Crítico — requiere restaurar desde backup |
| Degradado detectado | `mdadm` envía alerta | Administrador reemplaza disco y reconstruye |

### Reconstrucción tras fallo (comandos)

```bash
# Reemplazar disco fallido
mdadm /dev/md0 --remove /dev/loop0        # remover disco fallido
mdadm /dev/md0 --add /dev/loop_nuevo      # agregar disco nuevo
cat /proc/mdstat                           # monitorear reconstrucción
```

### Justificación

Los datos del RUV son la evidencia documental de los hechos victimizantes de millones de colombianos. Su pérdida sería irreversible — no existe una fuente alternativa para reconstruirlos. El RAID 1 garantiza que un fallo de hardware en un disco no cause interrupción del servicio ni pérdida de datos. Comparado con RAID 0 (sin redundancia) o RAID 5 (requiere mínimo 3 discos y tiene overhead de paridad), RAID 1 es la opción más directa y confiable para proteger datos críticos con dos discos.

---

## 4. Política de Backups como Recuperación ante Fallos

### Estrategia 3-2-1

| Capa | Qué | Dónde | Frecuencia |
|---|---|---|---|
| **3 copias** | PostgreSQL dump + archivos Samba + configs | Local (`/mnt/uv_logs/backups/`) | Diaria (2:00 AM) |
| **2 medios** | LVM sobre RAID + copia externa | RAID local + nube/NAS externo | Diaria |
| **1 offsite** | Backup cifrado en ubicación remota | Servidor externo o nube | Semanal |

### Objetivos de recuperación

| Métrica | Valor | Descripción |
|---|---|---|
| **RPO** (Recovery Point Objective) | 24 horas | Máxima pérdida de datos aceptable |
| **RTO** (Recovery Time Objective) | 2 horas | Tiempo máximo para restablecer el servicio |

### Proceso de restauración ante desastre total

```bash
# 1. Restaurar infraestructura base
sudo bash scripts/storage/setup_raid.sh
sudo bash scripts/storage/setup_lvm.sh

# 2. Levantar contenedores
sudo bash scripts/automation/deploy.sh

# 3. Restaurar base de datos desde último backup
psql -U uv_admin -d uv_sig < /mnt/uv_logs/backups/db/backup_YYYYMMDD.sql

# 4. Restaurar archivos Samba
tar -xzf /mnt/uv_logs/backups/files/samba_YYYYMMDD.tar.gz -C /mnt/uv_files/

# 5. Verificar integridad
sudo bash scripts/storage/verify_persistence.sh
```

### Justificación

El backup automatizado diario a las 2:00 AM (cron job de AUT-1) garantiza un RPO de 24 horas. Para una entidad del Estado colombiano como la Unidad de Víctimas, esto cumple con los lineamientos del MINTIC para sistemas de información críticos. La política de retención de 7 días permite recuperar datos de hasta una semana atrás, cubriendo escenarios de corrupción silenciosa de datos que no se detectan inmediatamente.

---

## 5. Resumen de la Estrategia HA

| Componente | Estrategia | Nivel de HA | Estado |
|---|---|---|---|
| Capa web | Nginx upstream con 3 instancias | Activo-Activo | ✅ Implementado |
| Base de datos | PostgreSQL primary/standby | Activo-Pasivo | 📋 Conceptual |
| Almacenamiento | RAID 1 (espejo de discos) | Redundancia automática | ✅ Implementado |
| Recuperación | Backups diarios + script de restauración | RPO 24h / RTO 2h | ✅ Implementado |
| Firewall | UFW con políticas por VLAN | Protección perimetral | ✅ Implementado |

---

## 6. Diagrama de Flujo de Failover

```
     ┌─────────────────────────────────────────────────┐
     │          Detección de fallo                      │
     │  (healthcheck falla 3 veces consecutivas)        │
     └──────────────────────┬──────────────────────────┘
                            │
            ┌───────────────┼───────────────┐
            ▼               ▼               ▼
       Fallo web        Fallo DB        Fallo disco
            │               │               │
     Proxy redirige   Promover standby  RAID continúa
     a otra instancia  (touch trigger)  con disco sano
            │               │               │
     ✅ Automático     ⚠️ Manual (< 2min)  ✅ Automático
```
