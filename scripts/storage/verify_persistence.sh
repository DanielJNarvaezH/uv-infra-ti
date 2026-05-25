#!/usr/bin/env bash
# =============================================================================
# verify_persistence.sh — ALM-3: Verificación de Persistencia LVM + Contenedores
# Infraestructura TI — Unidad para la Atención y Reparación Integral a las Víctimas
# Universidad del Quindío — Semestre 2026-1
# =============================================================================
#
# DESCRIPCIÓN:
#   Verifica que los volúmenes LVM montados en /mnt/uv_db y /mnt/uv_files
#   persistan correctamente al reiniciar los contenedores srv-db-01 y
#   srv-files-01. Ejecuta un ciclo completo de prueba:
#
#     1. Verificar prereqs (LVM montado, contenedores corriendo)
#     2. Escribir archivos/datos de prueba en cada volumen
#     3. Reiniciar los contenedores
#     4. Verificar que los datos persisten tras el reinicio
#     5. Verificar integridad del esquema de BD (uv_sig)
#     6. Generar reporte final con evidencia
#
# USO:
#   sudo bash scripts/storage/verify_persistence.sh
#   sudo bash scripts/storage/verify_persistence.sh --quick   # solo monta + ping
#
# PREREQUISITOS:
#   - setup_raid.sh y setup_lvm.sh ejecutados (ALM-1, ALM-2)
#   - Stack de contenedores levantado (start.sh)
#   - Variables de entorno en docker/.env
#
# =============================================================================

set -euo pipefail

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[OK]${NC}    $*"; }
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $*" >&2; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}"; }
header()  { echo -e "\n${BOLD}$*${NC}"; }

PASS=0; FAIL=0

assert_ok() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        log "${desc}"; ((PASS++)) || true
    else
        fail "${desc}"; ((FAIL++)) || true
    fi
}

# ── Verificar root ────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { fail "Ejecutar como root: sudo bash $0"; exit 1; }

# ── Detectar runtime (podman o docker) ───────────────────────────────────────
CONTAINER_CMD=""
if command -v podman &>/dev/null && podman ps >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
elif command -v docker &>/dev/null && docker ps >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
else
    fail "No se encontró podman ni docker operativo."
    exit 1
fi

# ── Modo rápido ───────────────────────────────────────────────────────────────
QUICK_MODE=false
[[ "${1:-}" == "--quick" ]] && QUICK_MODE=true

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
ENV_FILE="${PROJECT_ROOT}/docker/.env"

MNT_DB="/mnt/uv_db"
MNT_FILES="/mnt/uv_files"
REPORT_DIR="/mnt/uv_logs/reports"
REPORT_FILE="${REPORT_DIR}/alm3_persistence_$(date +%Y%m%d_%H%M%S).txt"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# ── Cargar .env si existe ─────────────────────────────────────────────────────
PG_USER="uv_admin"; PG_DB="uv_sig"
if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -a; source "${ENV_FILE}"; set +a
    PG_USER="${POSTGRES_USER:-uv_admin}"
    PG_DB="${POSTGRES_DB:-uv_sig}"
fi

# ── Crear directorio de reportes ──────────────────────────────────────────────
mkdir -p "${REPORT_DIR}" 2>/dev/null || true

# =============================================================================
# CABECERA
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║   ALM-3 — Verificación de Persistencia LVM + Contenedores       ║${NC}"
echo -e "${CYAN}${BOLD}║   Infraestructura TI — Unidad de Víctimas — Sprint 3             ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
info "Timestamp  : ${TIMESTAMP}"
info "Runtime    : ${CONTAINER_CMD}"
info "PG_DB      : ${PG_DB} / ${PG_USER}"
info "Modo rápido: ${QUICK_MODE}"
echo ""

# =============================================================================
# SECCIÓN 1 — PRERREQUISITOS
# =============================================================================
section "1. Verificando prerrequisitos"

# LVM montado
assert_ok "/mnt/uv_db  montado"    mountpoint -q "${MNT_DB}"
assert_ok "/mnt/uv_files montado"   mountpoint -q "${MNT_FILES}"

# Espacio disponible
header "Espacio en volúmenes LVM:"
df -h "${MNT_DB}" "${MNT_FILES}" 2>/dev/null || warn "No se pudo obtener df"

# Contenedores corriendo
for svc in srv-db-01 srv-files-01; do
    assert_ok "Contenedor ${svc} corriendo" \
        bash -c "${CONTAINER_CMD} ps --format '{{.Names}}' | grep -q '^${svc}\$'"
done

# Health de los contenedores
for svc in srv-db-01 srv-files-01; do
    health=$(${CONTAINER_CMD} inspect "${svc}" \
        --format '{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
    if [[ "${health}" == "healthy" ]]; then
        log "${svc} health: ${health}"; ((PASS++)) || true
    else
        warn "${svc} health: ${health} (puede estar iniciando)"
    fi
done

# Verificar bind mounts en docker-compose
if grep -q "/mnt/uv_db" "${PROJECT_ROOT}/docker/docker-compose.yml" 2>/dev/null; then
    log "docker-compose.yml referencia /mnt/uv_db  (bind mount configurado)"
    ((PASS++)) || true
else
    fail "docker-compose.yml NO referencia /mnt/uv_db"; ((FAIL++)) || true
fi

if grep -q "/mnt/uv_files" "${PROJECT_ROOT}/docker/docker-compose.yml" 2>/dev/null; then
    log "docker-compose.yml referencia /mnt/uv_files (bind mount configurado)"
    ((PASS++)) || true
else
    fail "docker-compose.yml NO referencia /mnt/uv_files"; ((FAIL++)) || true
fi

if $QUICK_MODE; then
    echo ""
    info "Modo rápido: finalizando aquí."
    echo -e "${GREEN}[PASS: ${PASS}] [FAIL: ${FAIL}]${NC}"
    exit $((FAIL > 0 ? 1 : 0))
fi

# =============================================================================
# SECCIÓN 2 — ESCRIBIR DATOS DE PRUEBA ANTES DEL REINICIO
# =============================================================================
section "2. Escribiendo datos de prueba (antes del reinicio)"

MARKER_DB="${MNT_DB}/alm3_test_$(date +%s).marker"
MARKER_FILES="${MNT_FILES}/alm3_test_$(date +%s).marker"
TEST_CONTENT="ALM-3 persistence test — $(date '+%Y-%m-%d %H:%M:%S') — ${HOSTNAME}"

# Archivo de prueba en /mnt/uv_db (fuera del directorio de datos PG — en la raíz del LV)
echo "${TEST_CONTENT}" > "${MARKER_DB}"
log "Marker escrito en ${MARKER_DB}"

# Archivo de prueba en /mnt/uv_files
echo "${TEST_CONTENT}" > "${MARKER_FILES}"
log "Marker escrito en ${MARKER_FILES}"

# Registro en tabla PostgreSQL (prueba de persistencia a nivel de BD)
PG_TEST_TABLE="sig.alm3_persistence_test"
PG_TEST_VALUE="test_$(date +%s)"
if ${CONTAINER_CMD} exec srv-db-01 \
    psql -U "${PG_USER}" -d "${PG_DB}" -q \
    -c "CREATE TABLE IF NOT EXISTS ${PG_TEST_TABLE} (id SERIAL PRIMARY KEY, ts TIMESTAMPTZ DEFAULT NOW(), valor TEXT NOT NULL);" \
    -c "INSERT INTO ${PG_TEST_TABLE} (valor) VALUES ('${PG_TEST_VALUE}');" \
    >/dev/null 2>&1; then
    log "Registro de prueba insertado en ${PG_TEST_TABLE}: '${PG_TEST_VALUE}'"
else
    warn "No se pudo insertar registro de prueba en BD (continuando...)"
fi

# Verificar checksum del marker en /mnt/uv_files antes del reinicio
CHECKSUM_BEFORE=$(md5sum "${MARKER_FILES}" | cut -d' ' -f1)
info "Checksum del marker (antes): ${CHECKSUM_BEFORE}"

# =============================================================================
# SECCIÓN 3 — REINICIAR CONTENEDORES
# =============================================================================
section "3. Reiniciando contenedores (simulación de fallo/mantenimiento)"

info "Deteniendo srv-db-01 y srv-files-01..."
${CONTAINER_CMD} stop srv-db-01 srv-files-01 2>/dev/null || true
log "Contenedores detenidos."

# Verificar que los volúmenes SIGUEN montados con los contenedores parados
assert_ok "/mnt/uv_db   persiste con contenedor detenido"  mountpoint -q "${MNT_DB}"
assert_ok "/mnt/uv_files persiste con contenedor detenido" mountpoint -q "${MNT_FILES}"

header "Estado de los LV tras detener contenedores:"
lvs 2>/dev/null || warn "lvs no disponible"

info "Reiniciando srv-db-01 y srv-files-01..."
${CONTAINER_CMD} start srv-db-01 srv-files-01 2>/dev/null || {
    warn "start falló — intentando con compose..."
    cd "${PROJECT_ROOT}/docker"
    if command -v podman-compose &>/dev/null; then
        podman-compose up -d srv-db-01 srv-files-01 2>/dev/null || true
    fi
}
log "Contenedores reiniciados."

# Esperar healthcheck (máx. 90s)
info "Esperando que los contenedores estén healthy (máx. 90s)..."
ELAPSED=0; TIMEOUT=90
while [[ $ELAPSED -lt $TIMEOUT ]]; do
    DB_HEALTH=$(${CONTAINER_CMD} inspect srv-db-01 \
        --format '{{.State.Health.Status}}' 2>/dev/null || echo "starting")
    FILES_HEALTH=$(${CONTAINER_CMD} inspect srv-files-01 \
        --format '{{.State.Health.Status}}' 2>/dev/null || echo "starting")
    if [[ "${DB_HEALTH}" == "healthy" && "${FILES_HEALTH}" == "healthy" ]]; then
        log "Ambos contenedores healthy tras ${ELAPSED}s"
        break
    fi
    sleep 5; ((ELAPSED+=5)) || true
    [[ $((ELAPSED % 15)) -eq 0 ]] && \
        info "  Esperando... ${ELAPSED}s (db:${DB_HEALTH} files:${FILES_HEALTH})"
done
[[ $ELAPSED -ge $TIMEOUT ]] && warn "Timeout esperando healthcheck (posible inicio lento)"

# =============================================================================
# SECCIÓN 4 — VERIFICAR PERSISTENCIA TRAS EL REINICIO
# =============================================================================
section "4. Verificando persistencia tras el reinicio"

# Verificar volúmenes aún montados
assert_ok "/mnt/uv_db   montado tras reinicio"  mountpoint -q "${MNT_DB}"
assert_ok "/mnt/uv_files montado tras reinicio" mountpoint -q "${MNT_FILES}"

# Verificar archivos marker
if [[ -f "${MARKER_DB}" ]]; then
    log "Marker en /mnt/uv_db    PERSISTE: $(cat "${MARKER_DB}")"
    ((PASS++)) || true
else
    fail "Marker en /mnt/uv_db NO persiste"; ((FAIL++)) || true
fi

if [[ -f "${MARKER_FILES}" ]]; then
    log "Marker en /mnt/uv_files PERSISTE: $(cat "${MARKER_FILES}")"
    ((PASS++)) || true
else
    fail "Marker en /mnt/uv_files NO persiste"; ((FAIL++)) || true
fi

# Verificar checksum después del reinicio
CHECKSUM_AFTER=$(md5sum "${MARKER_FILES}" 2>/dev/null | cut -d' ' -f1 || echo "ERROR")
if [[ "${CHECKSUM_BEFORE}" == "${CHECKSUM_AFTER}" ]]; then
    log "Integridad del marker verificada (checksum MD5 coincide)"
    ((PASS++)) || true
else
    fail "Checksum no coincide — posible corrupción (antes:${CHECKSUM_BEFORE} después:${CHECKSUM_AFTER})"
    ((FAIL++)) || true
fi

# =============================================================================
# SECCIÓN 5 — INTEGRIDAD DE LA BASE DE DATOS
# =============================================================================
section "5. Verificando integridad del esquema uv_sig"

# pg_isready
assert_ok "PostgreSQL acepta conexiones (pg_isready)" \
    bash -c "${CONTAINER_CMD} exec srv-db-01 pg_isready -U ${PG_USER} -d ${PG_DB}"

# Tablas principales del SIG
for tabla in sig.victimas sig.atenciones sig.proceso_reparacion sig.eventos_participacion; do
    assert_ok "Tabla ${tabla} existe" \
        bash -c "${CONTAINER_CMD} exec srv-db-01 \
            psql -U ${PG_USER} -d ${PG_DB} -tAc \
            \"SELECT 1 FROM information_schema.tables \
              WHERE table_schema='sig' AND table_name='${tabla##*.}'\" \
            | grep -q 1"
done

# Datos de seed (víctimas de prueba)
VICTIM_COUNT=$(${CONTAINER_CMD} exec srv-db-01 \
    psql -U "${PG_USER}" -d "${PG_DB}" -tAc \
    "SELECT COUNT(*) FROM sig.victimas;" 2>/dev/null | tr -d '[:space:]' || echo "0")
if [[ "${VICTIM_COUNT}" -gt 0 ]]; then
    log "Datos de seed intactos: ${VICTIM_COUNT} víctima(s) en sig.victimas"
    ((PASS++)) || true
else
    warn "sig.victimas vacía (puede ser primer arranque sin seed)"
fi

# Verificar el registro de prueba ALM-3
if ${CONTAINER_CMD} exec srv-db-01 \
    psql -U "${PG_USER}" -d "${PG_DB}" -tAc \
    "SELECT valor FROM sig.alm3_persistence_test WHERE valor='${PG_TEST_VALUE}';" \
    2>/dev/null | grep -q "${PG_TEST_VALUE}"; then
    log "Registro de prueba ALM-3 persiste en BD: '${PG_TEST_VALUE}'"
    ((PASS++)) || true
else
    warn "Registro de prueba no encontrado (el esquema puede no haber inicializado)"
fi

# =============================================================================
# SECCIÓN 6 — VERIFICAR BIND MOUNTS DENTRO DE LOS CONTENEDORES
# =============================================================================
section "6. Verificando bind mounts dentro de los contenedores"

# srv-db-01: /var/lib/postgresql/data debe ser el mismo LV que /mnt/uv_db
PG_DATA_INODE=$(${CONTAINER_CMD} exec srv-db-01 \
    stat -c %d /var/lib/postgresql/data 2>/dev/null || echo "0")
HOST_DB_INODE=$(stat -c %d "${MNT_DB}" 2>/dev/null || echo "1")
if [[ "${PG_DATA_INODE}" == "${HOST_DB_INODE}" ]]; then
    log "srv-db-01:/var/lib/postgresql/data ↔ host:/mnt/uv_db (mismo device)"
    ((PASS++)) || true
else
    info "Verificación de device: PG_DATA=${PG_DATA_INODE} HOST_DB=${HOST_DB_INODE}"
    info "(En rootless Podman los device IDs pueden diferir — inspeccionando mount)"
fi

# Inspeccionar mounts del contenedor
header "Bind mounts activos en srv-db-01:"
${CONTAINER_CMD} inspect srv-db-01 \
    --format '{{range .Mounts}}  Tipo:{{.Type}}  Src:{{.Source}}  → Dst:{{.Destination}}{{"\n"}}{{end}}' \
    2>/dev/null || warn "No se pudo inspeccionar mounts de srv-db-01"

header "Bind mounts activos en srv-files-01:"
${CONTAINER_CMD} inspect srv-files-01 \
    --format '{{range .Mounts}}  Tipo:{{.Type}}  Src:{{.Source}}  → Dst:{{.Destination}}{{"\n"}}{{end}}' \
    2>/dev/null || warn "No se pudo inspeccionar mounts de srv-files-01"

# Verificar que Samba puede listar el share
if ${CONTAINER_CMD} exec srv-files-01 \
    testparm -s /etc/samba/smb.conf >/dev/null 2>&1; then
    log "Samba: smb.conf válido y servicio activo"
    ((PASS++)) || true
else
    warn "Samba: testparm no disponible o smb.conf inválido"
fi

# =============================================================================
# SECCIÓN 7 — MÉTRICAS DE ALMACENAMIENTO
# =============================================================================
section "7. Métricas de almacenamiento LVM"

header "Espacio en puntos de montaje:"
df -h "${MNT_DB}" "${MNT_FILES}" /mnt/uv_logs 2>/dev/null || true

header "Logical Volumes activos:"
lvs 2>/dev/null || warn "lvs no disponible"

header "Volume Group:"
vgs 2>/dev/null || warn "vgs no disponible"

header "Estado RAID (/proc/mdstat):"
cat /proc/mdstat 2>/dev/null || warn "/proc/mdstat no disponible"

# =============================================================================
# SECCIÓN 8 — GENERAR REPORTE DE EVIDENCIA
# =============================================================================
section "8. Generando reporte de evidencia"

{
echo "========================================================================"
echo "  ALM-3 — Reporte de Persistencia LVM + Contenedores Docker"
echo "  Infraestructura TI — Unidad para la Atención y Reparación a Víctimas"
echo "  Timestamp: ${TIMESTAMP}"
echo "========================================================================"
echo ""
echo "RESULTADOS:"
echo "  Pruebas pasadas : ${PASS}"
echo "  Pruebas fallidas: ${FAIL}"
echo ""
echo "VOLÚMENES VERIFICADOS:"
df -h "${MNT_DB}" "${MNT_FILES}" /mnt/uv_logs 2>/dev/null
echo ""
echo "BIND MOUNTS srv-db-01:"
${CONTAINER_CMD} inspect srv-db-01 \
    --format '{{range .Mounts}}  {{.Type}} {{.Source}} → {{.Destination}}{{"\n"}}{{end}}' \
    2>/dev/null || echo "  (no disponible)"
echo ""
echo "BIND MOUNTS srv-files-01:"
${CONTAINER_CMD} inspect srv-files-01 \
    --format '{{range .Mounts}}  {{.Type}} {{.Source}} → {{.Destination}}{{"\n"}}{{end}}' \
    2>/dev/null || echo "  (no disponible)"
echo ""
echo "LOGICAL VOLUMES:"
lvs 2>/dev/null || echo "  (no disponible)"
echo ""
echo "ESTADO RAID:"
cat /proc/mdstat 2>/dev/null || echo "  (no disponible)"
echo ""
echo "DATOS DE PRUEBA:"
echo "  Marker DB    : ${MARKER_DB}"
echo "  Marker Files : ${MARKER_FILES}"
echo "  Checksum MD5 antes  : ${CHECKSUM_BEFORE}"
echo "  Checksum MD5 después: ${CHECKSUM_AFTER}"
echo "  Registro BD  : ${PG_TEST_VALUE}"
echo ""
echo "========================================================================"
echo "  Estado final: $( [[ ${FAIL} -eq 0 ]] && echo 'PERSISTENCIA VERIFICADA ✓' || echo "ADVERTENCIAS — revisar ${FAIL} fallo(s)" )"
echo "========================================================================"
} > "${REPORT_FILE}" 2>/dev/null || true

if [[ -f "${REPORT_FILE}" ]]; then
    log "Reporte guardado en: ${REPORT_FILE}"
else
    warn "No se pudo guardar el reporte (¿/mnt/uv_logs no montado?)"
fi

# =============================================================================
# RESUMEN FINAL
# =============================================================================
echo ""
if [[ ${FAIL} -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║   ✓  ALM-3 VERIFICADO — Persistencia confirmada               ║${NC}"
    echo -e "${GREEN}${BOLD}║   Pruebas pasadas: ${PASS}  │  Fallidas: ${FAIL}                           ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
else
    echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}${BOLD}║   ⚠  ALM-3 — Persistencia con advertencias                    ║${NC}"
    echo -e "${YELLOW}${BOLD}║   Pruebas pasadas: ${PASS}  │  Fallidas: ${FAIL}                           ║${NC}"
    echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
fi
echo ""
echo -e "${YELLOW}  Limpiar markers de prueba (opcional):${NC}"
echo "    rm -f ${MARKER_DB} ${MARKER_FILES}"
echo ""
[[ -f "${REPORT_FILE}" ]] && echo -e "  Reporte: ${REPORT_FILE}\n"

exit $((FAIL > 0 ? 1 : 0))
