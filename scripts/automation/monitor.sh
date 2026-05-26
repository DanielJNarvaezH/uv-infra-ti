#!/usr/bin/env bash
# =============================================================================
# monitor.sh — AUT-3: Monitoreo Básico del Sistema
# Infraestructura TI — Unidad para la Atención y Reparación Integral a las Víctimas
# Universidad del Quindío — Semestre 2026-1
# =============================================================================
#
# DESCRIPCIÓN:
#   Script de monitoreo del sistema que recopila y registra:
#     1.  Uso de CPU (top -bn1)
#     2.  Memoria libre y en uso
#     3.  Espacio en disco (df -h) — incluye /mnt/uv_db, /mnt/uv_files, /mnt/uv_logs
#     4.  Estado de todos los contenedores Podman del stack
#     5.  Health-checks de contenedores (healthy / unhealthy)
#     6.  Conectividad HTTP a Nginx (srv-web-01, srv-web-02, srv-web-03, srv-proxy-01)
#     7.  Conectividad a PostgreSQL (pg_isready)
#     8.  Conectividad a MailHog SMTP (puerto 1025) y UI (puerto 8025)
#     9.  Estado del RAID 1 (/proc/mdstat)
#     10. Estado de los volúmenes LVM (/mnt/uv_*)
#     11. Alertas por SMTP (srv-smtp-01) cuando se detectan anomalías
#
# ─── CONFIGURACIÓN ADAPTABLE ──────────────────────────────────────────────────
# PROJECT_DIR se detecta automáticamente desde la ubicación del script.
# Para sobreescribirla:
#   export PROJECT_DIR=/home/TU_USUARIO/ruta/a/uv-infra-ti
#   bash scripts/automation/monitor.sh
#
# Umbrales de alerta sobreescribibles con variables de entorno:
#   export CPU_THRESHOLD=90        # % de CPU — default 85
#   export MEM_THRESHOLD=90        # % de RAM — default 85
#   export DISK_THRESHOLD=90       # % de disco — default 85
#   export ALERT_EMAIL=ops@uv.co   # destinatario de alertas
# ─────────────────────────────────────────────────────────────────────────────
#
# USO MANUAL:
#   bash scripts/automation/monitor.sh
#   bash scripts/automation/monitor.sh --alert-only   # solo enviar si hay alertas
#   bash scripts/automation/monitor.sh --no-smtp       # sin alertas por correo
#   bash scripts/automation/monitor.sh --quiet         # log sin salida en terminal
#
# CRON JOB (cada 15 minutos):
#   */15 * * * * /RUTA/AL/PROYECTO/scripts/automation/monitor.sh --quiet >> /dev/null 2>&1
#
# PREREQUISITOS:
#   - Stack de contenedores levantado (scripts/start.sh ejecutado)
#   - curl y podman instalados en el host
#   - Para métricas de LVM: setup_lvm.sh ejecutado (ALM-2)
#
# LOGS:
#   /var/log/uv_monitor.log  — log principal de monitoreo
#   /mnt/uv_logs/monitor/    — copias de reportes con timestamp (si LVM montado)
#
# =============================================================================

# set -euo pipefail no se usa aquí intencionalmente:
# el monitor NO debe abortar ante fallos parciales — debe reportarlos todos.
set -uo pipefail

# =============================================================================
# RUTA DEL PROYECTO — detección automática, sobreescribible con export
# =============================================================================
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# =============================================================================
# CONFIGURACIÓN — umbrales de alerta (sobreescribibles con variables de entorno)
# =============================================================================
CPU_THRESHOLD="${CPU_THRESHOLD:-85}"
MEM_THRESHOLD="${MEM_THRESHOLD:-85}"
DISK_THRESHOLD="${DISK_THRESHOLD:-85}"
ALERT_EMAIL="${ALERT_EMAIL:-uv_admin@uv.local}"

LOG_FILE="/var/log/uv_monitor.log"
SMTP_HOST="localhost"
SMTP_PORT="1025"

# Runtime de contenedores (Podman o Docker según entorno)
CONTAINER_CMD=""
if command -v podman &>/dev/null; then
    CONTAINER_CMD="podman"
elif command -v docker &>/dev/null; then
    CONTAINER_CMD="docker"
fi

# Todos los contenedores del stack
STACK_SERVICES=(
    "srv-ntp-01"
    "srv-db-01"
    "srv-files-01"
    "srv-smtp-01"
    "srv-dhcp-01"
    "srv-php-fpm"
    "srv-web-01"
    "srv-web-02"
    "srv-web-03"
    "srv-proxy-01"
    "srv-dns-01"
)

# Endpoints HTTP a verificar: nombre|URL|código_esperado
HTTP_CHECKS=(
    "srv-web-01 (portal ciudadano)|http://localhost:8082|200"
    "srv-web-02 (RNI)|http://localhost:8083|200"
    "srv-proxy-01 (NPM admin)|http://localhost:8081|200"
    "srv-smtp-01 (MailHog UI)|http://localhost:8025|200"
)

# =============================================================================
# FLAGS DE EJECUCIÓN
# =============================================================================
ALERT_ONLY=false
NO_SMTP=false
QUIET=false

for arg in "$@"; do
    case "$arg" in
        --alert-only) ALERT_ONLY=true ;;
        --no-smtp)    NO_SMTP=true ;;
        --quiet)      QUIET=true ;;
    esac
done

# =============================================================================
# FUNCIONES DE LOG Y PRESENTACIÓN
# =============================================================================

# Colores solo en terminal interactiva
if [[ -t 1 ]] && ! $QUIET; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME_VAL=$(hostname -s 2>/dev/null || echo "host")

# Contadores globales de alertas
ALERTS=()
WARN_COUNT=0
CRIT_COUNT=0

_log_line() {
    local line="$1"
    # Siempre escribir en el log file
    echo "$line" >> "${LOG_FILE}" 2>/dev/null || true
    # En terminal solo si no es --quiet
    $QUIET || echo -e "$line"
}

log_ok()   { _log_line "${GREEN}[OK]   ${NC}$*"; }
log_warn() { _log_line "${YELLOW}[WARN] ${NC}$*"; ((WARN_COUNT++)) || true; }
log_crit() { _log_line "${RED}[CRIT] ${NC}$*"; ((CRIT_COUNT++)) || true; }
log_info() { _log_line "${BLUE}[INFO] ${NC}$*"; }
log_sect() { _log_line "\n${CYAN}${BOLD}━━━ $* ━━━${NC}"; }
log_raw()  { _log_line "$*"; }

add_alert() {
    local level="$1"; shift
    ALERTS+=("[${level}] $*")
}

# =============================================================================
# CABECERA DEL REPORTE
# =============================================================================
{
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║   MONITOR UV-SIG — ${TIMESTAMP}                  ║"
    echo "║   Host: ${HOSTNAME_VAL} | Proyecto: ${PROJECT_DIR}  ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
} >> "${LOG_FILE}" 2>/dev/null || true

if ! $QUIET; then
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║   MONITOR UV-SIG — ${TIMESTAMP}                  ║${NC}"
    echo -e "${CYAN}${BOLD}║   Host: ${HOSTNAME_VAL}                                               ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"
fi

# =============================================================================
# SECCIÓN 1 — USO DE CPU
# =============================================================================
log_sect "1. USO DE CPU"

# Extraer % de CPU idle con top -bn1 (compatible POSIX/Linux)
if command -v top &>/dev/null; then
    TOP_OUTPUT=$(top -bn1 2>/dev/null || echo "")
    # La línea de %Cpu(s) en top -bn1 varía según distribución
    # Intentamos dos formatos: "Cpu(s): X.X us" y "%Cpu(s): X.X us"
    CPU_IDLE=$(echo "$TOP_OUTPUT" | grep -E "^(%?)Cpu\(s\)" | head -1 \
        | grep -oP '\d+[\.,]\d+\s*(?:id|ni)' | head -1 \
        | grep -oP '[\d]+[\.,][\d]+' || echo "")

    if [[ -n "$CPU_IDLE" ]]; then
        CPU_IDLE_INT=$(echo "$CPU_IDLE" | sed 's/,/./' | cut -d. -f1)
        CPU_USED=$((100 - CPU_IDLE_INT))
        log_info "Uso de CPU: ${CPU_USED}% (idle: ${CPU_IDLE}%)"
        if [[ $CPU_USED -ge $CPU_THRESHOLD ]]; then
            log_crit "CPU al ${CPU_USED}% — supera umbral de ${CPU_THRESHOLD}%"
            add_alert "CRIT" "CPU al ${CPU_USED}% en ${HOSTNAME_VAL}"
        else
            log_ok "CPU: ${CPU_USED}% (umbral: ${CPU_THRESHOLD}%)"
        fi
    else
        # Fallback: usar /proc/stat
        if [[ -f /proc/stat ]]; then
            CPU_LINE=$(grep "^cpu " /proc/stat)
            read -r _ user nice system idle iowait irq softirq steal _ <<< "$CPU_LINE"
            TOTAL=$((user + nice + system + idle + iowait + irq + softirq + steal))
            IDLE_TOTAL=$((idle + iowait))
            if [[ $TOTAL -gt 0 ]]; then
                CPU_USED=$(( (TOTAL - IDLE_TOTAL) * 100 / TOTAL ))
                log_info "Uso de CPU (via /proc/stat): ${CPU_USED}%"
                if [[ $CPU_USED -ge $CPU_THRESHOLD ]]; then
                    log_crit "CPU al ${CPU_USED}% — supera umbral de ${CPU_THRESHOLD}%"
                    add_alert "CRIT" "CPU al ${CPU_USED}% en ${HOSTNAME_VAL}"
                else
                    log_ok "CPU: ${CPU_USED}% (umbral: ${CPU_THRESHOLD}%)"
                fi
            fi
        else
            log_warn "No se pudo determinar el uso de CPU"
        fi
    fi

    # Mostrar resumen de top (las 5 primeras líneas son informativas)
    log_raw "$(echo "$TOP_OUTPUT" | head -5)"
else
    log_warn "top no disponible en este entorno"
fi

# Carga promedio del sistema (uptime)
if command -v uptime &>/dev/null; then
    UPTIME_INFO=$(uptime 2>/dev/null)
    log_info "Uptime/carga: ${UPTIME_INFO}"
fi

# =============================================================================
# SECCIÓN 2 — MEMORIA
# =============================================================================
log_sect "2. MEMORIA"

if [[ -f /proc/meminfo ]]; then
    MEM_TOTAL_KB=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}')
    MEM_FREE_KB=$(grep "^MemFree:" /proc/meminfo | awk '{print $2}')
    MEM_AVAIL_KB=$(grep "^MemAvailable:" /proc/meminfo | awk '{print $2}')
    MEM_BUFFERS_KB=$(grep "^Buffers:" /proc/meminfo | awk '{print $2}' || echo 0)
    MEM_CACHED_KB=$(grep "^Cached:" /proc/meminfo | awk '{print $2}' || echo 0)

    # Convertir a MB para presentación
    MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
    MEM_FREE_MB=$((MEM_FREE_KB / 1024))
    MEM_AVAIL_MB=$((MEM_AVAIL_KB / 1024))
    MEM_USED_MB=$(( MEM_TOTAL_MB - MEM_AVAIL_MB ))

    if [[ $MEM_TOTAL_MB -gt 0 ]]; then
        MEM_PCT=$(( MEM_USED_MB * 100 / MEM_TOTAL_MB ))
    else
        MEM_PCT=0
    fi

    log_info "Memoria total  : ${MEM_TOTAL_MB} MB"
    log_info "Memoria usada  : ${MEM_USED_MB} MB (${MEM_PCT}%)"
    log_info "Memoria libre  : ${MEM_FREE_MB} MB"
    log_info "Memoria disp.  : ${MEM_AVAIL_MB} MB (incluye caché reclam.)"

    if [[ $MEM_PCT -ge $MEM_THRESHOLD ]]; then
        log_crit "Memoria al ${MEM_PCT}% — supera umbral de ${MEM_THRESHOLD}%"
        add_alert "CRIT" "Memoria al ${MEM_PCT}% en ${HOSTNAME_VAL} (${MEM_USED_MB}/${MEM_TOTAL_MB} MB)"
    else
        log_ok "Memoria: ${MEM_PCT}% usada (umbral: ${MEM_THRESHOLD}%)"
    fi
elif command -v free &>/dev/null; then
    FREE_OUTPUT=$(free -m 2>/dev/null)
    log_raw "$FREE_OUTPUT"
    MEM_TOTAL_MB=$(echo "$FREE_OUTPUT" | awk '/^Mem:/{print $2}')
    MEM_USED_MB=$(echo "$FREE_OUTPUT" | awk '/^Mem:/{print $3}')
    if [[ -n "$MEM_TOTAL_MB" ]] && [[ $MEM_TOTAL_MB -gt 0 ]]; then
        MEM_PCT=$(( MEM_USED_MB * 100 / MEM_TOTAL_MB ))
        if [[ $MEM_PCT -ge $MEM_THRESHOLD ]]; then
            log_crit "Memoria al ${MEM_PCT}% — supera umbral de ${MEM_THRESHOLD}%"
            add_alert "CRIT" "Memoria al ${MEM_PCT}% en ${HOSTNAME_VAL}"
        else
            log_ok "Memoria: ${MEM_PCT}% usada (umbral: ${MEM_THRESHOLD}%)"
        fi
    fi
else
    log_warn "No se pudo obtener información de memoria"
fi

# =============================================================================
# SECCIÓN 3 — ESPACIO EN DISCO
# =============================================================================
log_sect "3. ESPACIO EN DISCO"

if command -v df &>/dev/null; then
    log_info "Sistemas de archivos montados:"
    log_raw "$(df -h 2>/dev/null)"
    log_raw ""

    # Verificar puntos de montaje críticos del SIG (LVM)
    CRITICAL_MOUNTS=("/" "/mnt/uv_db" "/mnt/uv_files" "/mnt/uv_logs")

    for mp in "${CRITICAL_MOUNTS[@]}"; do
        if mountpoint -q "$mp" 2>/dev/null || [[ "$mp" == "/" ]]; then
            DISK_INFO=$(df -h "$mp" 2>/dev/null | tail -1)
            DISK_PCT=$(df "$mp" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
            DISK_AVAIL=$(echo "$DISK_INFO" | awk '{print $4}')
            DISK_USED=$(echo "$DISK_INFO" | awk '{print $3}')
            DISK_SIZE=$(echo "$DISK_INFO" | awk '{print $2}')

            log_info "Punto de montaje: ${mp}"
            log_info "  Tamaño: ${DISK_SIZE} | Usado: ${DISK_USED} | Libre: ${DISK_AVAIL} | Uso: ${DISK_PCT}%"

            if [[ -n "$DISK_PCT" ]] && [[ $DISK_PCT -ge $DISK_THRESHOLD ]]; then
                log_crit "DISCO ${mp} al ${DISK_PCT}% — supera umbral de ${DISK_THRESHOLD}%"
                add_alert "CRIT" "Disco ${mp} al ${DISK_PCT}% en ${HOSTNAME_VAL} (libre: ${DISK_AVAIL})"
            else
                log_ok "Disco ${mp}: ${DISK_PCT}% usado (umbral: ${DISK_THRESHOLD}%)"
            fi
        else
            log_warn "Punto de montaje LVM no activo: ${mp} (¿setup_lvm.sh ejecutado?)"
        fi
    done
else
    log_warn "df no disponible"
fi

# =============================================================================
# SECCIÓN 4 — ESTADO DE CONTENEDORES PODMAN
# =============================================================================
log_sect "4. ESTADO DE CONTENEDORES PODMAN"

if [[ -z "$CONTAINER_CMD" ]]; then
    log_warn "Podman/Docker no encontrado — omitiendo verificación de contenedores"
else
    log_info "Runtime detectado: ${CONTAINER_CMD}"
    log_raw ""

    # Listar todos los contenedores del stack con su estado
    ALL_RUNNING=true
    for svc in "${STACK_SERVICES[@]}"; do
        STATUS=$($CONTAINER_CMD inspect "$svc" \
            --format '{{.State.Status}}' 2>/dev/null || echo "missing")
        HEALTH=$($CONTAINER_CMD inspect "$svc" \
            --format '{{.State.Health.Status}}' 2>/dev/null || echo "N/A")
        IMAGE=$($CONTAINER_CMD inspect "$svc" \
            --format '{{.Config.Image}}' 2>/dev/null || echo "N/A")
        STARTED=$($CONTAINER_CMD inspect "$svc" \
            --format '{{.State.StartedAt}}' 2>/dev/null || echo "N/A")

        case "$STATUS" in
            running)
                if [[ "$HEALTH" == "healthy" ]] || [[ "$HEALTH" == "N/A" ]]; then
                    log_ok "${svc} — running (health: ${HEALTH})"
                elif [[ "$HEALTH" == "starting" ]]; then
                    log_warn "${svc} — running, health: starting (puede estar iniciando)"
                else
                    log_crit "${svc} — running pero health: ${HEALTH}"
                    add_alert "WARN" "Contenedor ${svc} health: ${HEALTH}"
                fi
                ;;
            exited|stopped)
                log_crit "${svc} — DETENIDO (estado: ${STATUS})"
                add_alert "CRIT" "Contenedor ${svc} está detenido en ${HOSTNAME_VAL}"
                ALL_RUNNING=false
                ;;
            missing|"")
                log_crit "${svc} — NO ENCONTRADO (¿stack levantado?)"
                add_alert "CRIT" "Contenedor ${svc} no encontrado en ${HOSTNAME_VAL}"
                ALL_RUNNING=false
                ;;
            *)
                log_warn "${svc} — estado: ${STATUS}"
                add_alert "WARN" "Contenedor ${svc} en estado inesperado: ${STATUS}"
                ALL_RUNNING=false
                ;;
        esac
    done

    $ALL_RUNNING && log_ok "Todos los contenedores del stack están corriendo."

    # Tabla resumen de contenedores
    log_raw ""
    log_info "Resumen de contenedores (podman ps):"
    log_raw "$($CONTAINER_CMD ps -a \
        --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || \
        echo "(no disponible)")"
fi

# =============================================================================
# SECCIÓN 5 — CONECTIVIDAD HTTP A SERVICIOS NGINX
# =============================================================================
log_sect "5. CONECTIVIDAD HTTP (SERVICIOS NGINX)"

if ! command -v curl &>/dev/null; then
    log_warn "curl no disponible — omitiendo verificación HTTP"
else
    for check in "${HTTP_CHECKS[@]}"; do
        NAME=$(echo "$check" | cut -d'|' -f1)
        URL=$(echo "$check" | cut -d'|' -f2)
        EXPECTED=$(echo "$check" | cut -d'|' -f3)

        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            --max-time 5 --connect-timeout 3 "$URL" 2>/dev/null || echo "000")

        if [[ "$HTTP_CODE" == "$EXPECTED" ]]; then
            log_ok "${NAME} — HTTP ${HTTP_CODE} → ${URL}"
        elif [[ "$HTTP_CODE" == "000" ]]; then
            log_crit "${NAME} — SIN RESPUESTA (timeout/conexión rechazada) → ${URL}"
            add_alert "CRIT" "${NAME} no responde en ${URL}"
        else
            log_warn "${NAME} — HTTP ${HTTP_CODE} (esperado ${EXPECTED}) → ${URL}"
            add_alert "WARN" "${NAME} devuelve HTTP ${HTTP_CODE} en ${URL}"
        fi
    done
fi

# =============================================================================
# SECCIÓN 6 — CONECTIVIDAD A POSTGRESQL (pg_isready)
# =============================================================================
log_sect "6. CONECTIVIDAD A POSTGRESQL"

# Cargar variables de entorno desde docker/.env si existe
ENV_FILE="${PROJECT_DIR}/docker/.env"
PG_USER="uv_admin"
PG_DB="uv_sig"
PG_HOST="localhost"
PG_PORT="5432"

if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}" 2>/dev/null || true
    set +a
    PG_USER="${POSTGRES_USER:-uv_admin}"
    PG_DB="${POSTGRES_DB:-uv_sig}"
fi

log_info "Base de datos: ${PG_DB} | Usuario: ${PG_USER} | Puerto: ${PG_PORT}"

# Método 1: pg_isready directo dentro del contenedor
if [[ -n "$CONTAINER_CMD" ]]; then
    PG_STATUS=$($CONTAINER_CMD exec srv-db-01 \
        pg_isready -U "${PG_USER}" -d "${PG_DB}" -h localhost 2>&1 || echo "ERROR")

    if echo "$PG_STATUS" | grep -q "accepting connections"; then
        log_ok "PostgreSQL acepta conexiones — ${PG_STATUS}"
    elif echo "$PG_STATUS" | grep -q "rejecting connections"; then
        log_crit "PostgreSQL RECHAZANDO conexiones — ${PG_STATUS}"
        add_alert "CRIT" "PostgreSQL rechaza conexiones en srv-db-01"
    else
        log_crit "PostgreSQL NO responde — ${PG_STATUS}"
        add_alert "CRIT" "PostgreSQL no responde en srv-db-01"
    fi

    # Verificar número de conexiones activas
    PG_CONNS=$($CONTAINER_CMD exec srv-db-01 \
        psql -U "${PG_USER}" -d "${PG_DB}" -tAc \
        "SELECT count(*) FROM pg_stat_activity WHERE state='active';" \
        2>/dev/null | tr -d '[:space:]' || echo "N/A")
    log_info "Conexiones activas a la BD: ${PG_CONNS}"

    # Verificar integridad básica del esquema sig
    SCHEMA_OK=$($CONTAINER_CMD exec srv-db-01 \
        psql -U "${PG_USER}" -d "${PG_DB}" -tAc \
        "SELECT count(*) FROM information_schema.tables \
         WHERE table_schema='sig';" \
        2>/dev/null | tr -d '[:space:]' || echo "0")
    if [[ "$SCHEMA_OK" -gt 0 ]] 2>/dev/null; then
        log_ok "Esquema uv_sig: ${SCHEMA_OK} tablas accesibles"
    else
        log_warn "No se pudo verificar el esquema uv_sig (${SCHEMA_OK} tablas)"
    fi
else
    # Fallback: pg_isready directo en el host si está instalado
    if command -v pg_isready &>/dev/null; then
        PG_STATUS=$(pg_isready -h "${PG_HOST}" -p "${PG_PORT}" \
            -U "${PG_USER}" -d "${PG_DB}" 2>&1 || echo "ERROR")
        if echo "$PG_STATUS" | grep -q "accepting connections"; then
            log_ok "PostgreSQL: ${PG_STATUS}"
        else
            log_crit "PostgreSQL no accesible: ${PG_STATUS}"
            add_alert "CRIT" "PostgreSQL no accesible desde el host"
        fi
    else
        log_warn "pg_isready no disponible y Podman no encontrado — omitiendo verificación de BD"
    fi
fi

# =============================================================================
# SECCIÓN 7 — CONECTIVIDAD SMTP (srv-smtp-01 / MailHog)
# =============================================================================
log_sect "7. CONECTIVIDAD SMTP (MAILHOG)"

# Verificar puerto SMTP 1025
if timeout 3 bash -c "echo >/dev/tcp/${SMTP_HOST}/${SMTP_PORT}" 2>/dev/null; then
    log_ok "SMTP MailHog puerto ${SMTP_PORT} — accesible"
else
    log_warn "SMTP MailHog puerto ${SMTP_PORT} — NO accesible (¿srv-smtp-01 corriendo?)"
    add_alert "WARN" "SMTP MailHog no accesible en ${SMTP_HOST}:${SMTP_PORT}"
fi

# Verificar API MailHog (para estadísticas de mensajes)
if command -v curl &>/dev/null; then
    MH_MSGS=$(curl -s --max-time 3 "http://localhost:8025/api/v2/messages" 2>/dev/null \
        | grep -o '"count":[0-9]*' | head -1 | cut -d: -f2 || echo "N/A")
    log_info "Mensajes en cola MailHog: ${MH_MSGS:-N/A}"
fi

# =============================================================================
# SECCIÓN 8 — ESTADO RAID 1 Y VOLÚMENES LVM
# =============================================================================
log_sect "8. ESTADO RAID 1 Y VOLÚMENES LVM"

# RAID
if [[ -f /proc/mdstat ]]; then
    MDSTAT=$(cat /proc/mdstat)
    log_info "Estado RAID (/proc/mdstat):"
    log_raw "$MDSTAT"

    # Verificar que el RAID no esté degradado
    if echo "$MDSTAT" | grep -q "\[.*_.*\]"; then
        DEGRADED=$(echo "$MDSTAT" | grep -E "\[.*_.*\]")
        log_crit "RAID DEGRADADO — disco(s) con fallo: ${DEGRADED}"
        add_alert "CRIT" "RAID degradado en ${HOSTNAME_VAL}: ${DEGRADED}"
    elif echo "$MDSTAT" | grep -q "md0"; then
        if echo "$MDSTAT" | grep -q "active"; then
            log_ok "RAID md0 — activo y sincronizado"
        else
            log_warn "RAID md0 — estado no esperado (revisar /proc/mdstat)"
        fi
    else
        log_warn "RAID md0 no encontrado (¿setup_raid.sh ejecutado?)"
    fi

    # Recuperación en progreso
    if echo "$MDSTAT" | grep -q "recovery\|resync"; then
        log_warn "RAID en proceso de recuperación/resync — rendimiento puede verse afectado"
        add_alert "WARN" "RAID en recuperación en ${HOSTNAME_VAL}"
    fi
else
    log_warn "/proc/mdstat no disponible — RAID no configurado o no accesible"
fi

# LVM
log_raw ""
log_info "Volúmenes LVM del SIG:"
for mp in "/mnt/uv_db" "/mnt/uv_files" "/mnt/uv_logs"; do
    if mountpoint -q "$mp" 2>/dev/null; then
        LV_SIZE=$(df -h "$mp" 2>/dev/null | tail -1 | awk '{print $2}')
        LV_USED=$(df -h "$mp" 2>/dev/null | tail -1 | awk '{print $3}')
        LV_FREE=$(df -h "$mp" 2>/dev/null | tail -1 | awk '{print $4}')
        LV_PCT=$(df "$mp" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
        log_ok "${mp} — montado (${LV_USED}/${LV_SIZE} | libre: ${LV_FREE} | ${LV_PCT}%)"
    else
        log_warn "${mp} — NO montado (¿setup_lvm.sh ejecutado?)"
        add_alert "WARN" "Volumen LVM ${mp} no montado en ${HOSTNAME_VAL}"
    fi
done

if command -v lvs &>/dev/null; then
    log_raw ""
    log_info "lvs (Logical Volumes):"
    log_raw "$(lvs 2>/dev/null || echo '  (no disponible)')"
fi

# =============================================================================
# SECCIÓN 9 — RECURSOS DEL HOST
# =============================================================================
log_sect "9. RECURSOS DEL HOST"

# Procesos del sistema
PROC_TOTAL=$(ps aux 2>/dev/null | wc -l || echo "N/A")
log_info "Procesos en ejecución: $((PROC_TOTAL - 1))"

# Conexiones de red activas
if command -v ss &>/dev/null; then
    NET_ESTAB=$(ss -s 2>/dev/null | grep "estab" | grep -oP '\d+ estab' | head -1 || echo "N/A")
    log_info "Conexiones TCP establecidas: ${NET_ESTAB:-N/A}"
elif command -v netstat &>/dev/null; then
    NET_ESTAB=$(netstat -an 2>/dev/null | grep -c "ESTABLISHED" || echo "N/A")
    log_info "Conexiones TCP establecidas: ${NET_ESTAB}"
fi

# Archivos de log recientes con errores
LOG_ERRORS=""
if [[ -f "${LOG_FILE}" ]]; then
    # Contar errores en los últimos 15 minutos del log de monitoreo
    LOG_ERRORS=$(grep "\[CRIT\]\|\[WARN\]" "${LOG_FILE}" 2>/dev/null | tail -10 || echo "")
fi

# =============================================================================
# SECCIÓN 10 — RESUMEN DE ALERTAS Y ENVÍO SMTP
# =============================================================================
log_sect "10. RESUMEN DE ALERTAS"

TOTAL_ALERTS=${#ALERTS[@]}

if [[ $TOTAL_ALERTS -eq 0 ]]; then
    log_ok "Sin alertas — todos los servicios operan dentro de los umbrales"
    log_info "Umbrales: CPU ${CPU_THRESHOLD}% | Memoria ${MEM_THRESHOLD}% | Disco ${DISK_THRESHOLD}%"
else
    log_raw ""
    log_raw "  Alertas detectadas (${TOTAL_ALERTS}):"
    for alert in "${ALERTS[@]}"; do
        log_raw "    → ${alert}"
    done
    log_raw ""
    log_info "Críticas: ${CRIT_COUNT} | Advertencias: ${WARN_COUNT}"
fi

# Guardar copia del reporte en /mnt/uv_logs si está montado
if mountpoint -q /mnt/uv_logs 2>/dev/null; then
    REPORT_DIR="/mnt/uv_logs/monitor"
    mkdir -p "${REPORT_DIR}" 2>/dev/null || true
    REPORT_FILE="${REPORT_DIR}/monitor_$(date +%Y%m%d_%H%M%S).log"
    # Copiar las últimas N líneas del log (las del ciclo actual)
    tail -200 "${LOG_FILE}" > "${REPORT_FILE}" 2>/dev/null || true
    log_info "Reporte guardado en: ${REPORT_FILE}"

    # Limpiar reportes de más de 7 días para no llenar el LV
    find "${REPORT_DIR}" -name "monitor_*.log" -mtime +7 -delete 2>/dev/null || true
fi

# =============================================================================
# ENVÍO DE ALERTA POR SMTP (srv-smtp-01 / MailHog)
# =============================================================================
if [[ $TOTAL_ALERTS -gt 0 ]] && ! $NO_SMTP; then

    ALERT_SUBJECT="[UV-SIG ALERTA] ${CRIT_COUNT} crítica(s) ${WARN_COUNT} advertencia(s) — ${TIMESTAMP}"
    ALERT_BODY="Monitor UV-SIG — ${TIMESTAMP}
Host: ${HOSTNAME_VAL}
Proyecto: ${PROJECT_DIR}

===== ALERTAS DETECTADAS =====
"
    for alert in "${ALERTS[@]}"; do
        ALERT_BODY+="  → ${alert}
"
    done

    ALERT_BODY+="
===== UMBRALES CONFIGURADOS =====
CPU:    ${CPU_THRESHOLD}%
Memoria: ${MEM_THRESHOLD}%
Disco:   ${DISK_THRESHOLD}%

===== LOG RECIENTE =====
$(tail -30 "${LOG_FILE}" 2>/dev/null)

--
Script: scripts/automation/monitor.sh
"

    # Intentar envío con curl al API de MailHog (más confiable que sendmail)
    if command -v curl &>/dev/null; then
        SMTP_PAYLOAD=$(cat <<EOF
{
  "From": {"Email": "monitor@uv.local", "Name": "Monitor UV-SIG"},
  "To": [{"Email": "${ALERT_EMAIL}"}],
  "Subject": "${ALERT_SUBJECT}",
  "TextPart": "$(echo "${ALERT_BODY}" | sed 's/"/\\"/g' | tr '\n' ' ')"
}
EOF
        )

        # MailHog acepta SMTP directo — intentar con curl SMTP
        curl -s --max-time 5 \
            --url "smtp://${SMTP_HOST}:${SMTP_PORT}" \
            --mail-from "monitor@uv.local" \
            --mail-rcpt "${ALERT_EMAIL}" \
            -T <(echo -e "From: Monitor UV-SIG <monitor@uv.local>\nTo: ${ALERT_EMAIL}\nSubject: ${ALERT_SUBJECT}\n\n${ALERT_BODY}") \
            2>/dev/null && log_ok "Alerta enviada por SMTP a ${ALERT_EMAIL}" \
                        || log_warn "No se pudo enviar alerta SMTP (MailHog no accesible)"
    else
        log_warn "curl no disponible — alerta SMTP no enviada"
    fi
fi

# =============================================================================
# PIE DEL REPORTE
# =============================================================================
{
    echo ""
    echo "  Fin del ciclo de monitoreo: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Alertas: ${TOTAL_ALERTS} | Críticas: ${CRIT_COUNT} | Advertencias: ${WARN_COUNT}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
} >> "${LOG_FILE}" 2>/dev/null || true

if ! $QUIET; then
    echo ""
    if [[ $CRIT_COUNT -gt 0 ]]; then
        echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}${BOLD}║  ✗  ${CRIT_COUNT} ALERTA(S) CRÍTICA(S) | ${WARN_COUNT} ADVERTENCIA(S)            ║${NC}"
        echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    elif [[ $WARN_COUNT -gt 0 ]]; then
        echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}${BOLD}║  ⚠  Sin críticas | ${WARN_COUNT} advertencia(s) registrada(s)        ║${NC}"
        echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}${BOLD}║  ✓  Todos los servicios operan correctamente                 ║${NC}"
        echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""
    echo "  Log: ${LOG_FILE}"
    echo ""
fi

# Código de salida: 0 OK | 1 advertencias | 2 críticos
if [[ $CRIT_COUNT -gt 0 ]]; then
    exit 2
elif [[ $WARN_COUNT -gt 0 ]]; then
    exit 1
else
    exit 0
fi
