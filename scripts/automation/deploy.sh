#!/bin/bash
# =============================================================================
# deploy.sh — Despliegue completo de uv-infra-ti
# Unidad para la Atención y Reparación Integral a las Víctimas — SIG
# =============================================================================
#
# DESCRIPCIÓN:
#   Automatiza todo el flujo de despliegue en orden secuencial:
#     1. git pull          — Actualizar código desde el repositorio
#     2. firewall.sh       — Reglas de firewall (UFW/iptables)
#     3. setup_raid.sh     — RAID 1 con discos virtuales (requiere root)
#     4. setup_lvm.sh      — LVM sobre RAID (requiere RAID previo)
#     5. users.sh          — Usuarios, grupos y permisos especiales
#     6. samba-setup.sh    — Preparación del host para Samba
#     7. start.sh          — Levantar el stack de contenedores Podman
#     8. Cron backup       — Programar backup automático diario a las 2:00 AM
#
# USO:
#   bash scripts/automation/deploy.sh                # despliegue completo
#   bash scripts/automation/deploy.sh --skip-pull     # omitir git pull
#   bash scripts/automation/deploy.sh --skip-raid     # omitir RAID+LVM
#   bash scripts/automation/deploy.sh --build          # rebuild de imágenes
#   bash scripts/automation/deploy.sh --only stack     # solo levantar contenedores
#   bash scripts/automation/deploy.sh --skip-cron      # omitir cron de backup
#
# REQUISITOS:
#   - Podman y podman-compose instalados
#   - docker/.env configurado (compartido por WhatsApp)
#   - Ejecutar como root (sudo) para firewall, RAID, LVM, usuarios y Samba
#
# =============================================================================

set -euo pipefail

# ── Colores y funciones de log ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[OK]${NC}    $*"; }
info()    { echo -e "${BLUE}[INFO]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}   $*"; }
section() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }
err()     { echo -e "${RED}[ERR]${NC}    $*" >&2; exit 1; }

# ── Directorios ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
SCRIPTS_DIR="${PROJECT_ROOT}/scripts"
DOCKER_DIR="${PROJECT_ROOT}/docker"

# ── Flags por defecto ──────────────────────────────────────────────────────────
SKIP_PULL=false
SKIP_RAID=false
SKIP_LVM=false
SKIP_FIREWALL=false
SKIP_USERS=false
SKIP_SAMBA=false
SKIP_STACK=false
SKIP_CRON=false
BUILD_FLAG=""

# ── Parsear argumentos ─────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --skip-pull)     SKIP_PULL=true ;;
        --skip-raid)     SKIP_RAID=true ;;
        --skip-lvm)      SKIP_LVM=true ;;
        --skip-firewall) SKIP_FIREWALL=true ;;
        --skip-users)    SKIP_USERS=true ;;
        --skip-samba)    SKIP_SAMBA=true ;;
        --skip-stack)    SKIP_STACK=true ;;
        --skip-cron)     SKIP_CRON=true ;;
        --build)         BUILD_FLAG="--build" ;;
        --only)
            # Si se pasa --only <paso>, solo ejecutar ese paso
            ONLY_STEP="${2:-}"
            ;;
        *) warn "Argumento desconocido: $arg" ;;
    esac
done

# Si se especificó --only, desactivar todo y activar solo ese paso
if [[ -n "${ONLY_STEP:-}" ]]; then
    SKIP_PULL=true
    SKIP_FIREWALL=true
    SKIP_RAID=true
    SKIP_LVM=true
    SKIP_USERS=true
    SKIP_SAMBA=true
    SKIP_STACK=true
    SKIP_CRON=true
    case "$ONLY_STEP" in
        pull)     SKIP_PULL=false ;;
        firewall) SKIP_FIREWALL=false ;;
        raid)     SKIP_RAID=false ;;
        lvm)      SKIP_LVM=false ;;
        users)    SKIP_USERS=false ;;
        samba)    SKIP_SAMBA=false ;;
        stack)    SKIP_STACK=false ;;
        cron)     SKIP_CRON=false ;;
        *) err "Paso desconocido: $ONLY_STEP. Válidos: pull, firewall, raid, lvm, users, samba, stack, cron" ;;
    esac
fi

# ── Verificar root para pasos que lo requieren ─────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "Este script requiere root. Ejecuta con: sudo bash $0 $*"
fi

# ── Verificaciones previas ─────────────────────────────────────────────────────
if ! $SKIP_STACK; then
    command -v podman         >/dev/null 2>&1 || err "podman no está instalado."
    command -v podman-compose >/dev/null 2>&1 || err "podman-compose no está instalado."
    [ -f "${DOCKER_DIR}/.env" ]             || err "Falta docker/.env — pídelo al equipo por WhatsApp."
    [ -f "${DOCKER_DIR}/docker-compose.yml" ] || err "No se encontró docker/docker-compose.yml"
fi

# =============================================================================
# PASO 1 — Git Pull
# =============================================================================
if ! $SKIP_PULL; then
    section "Paso 1/8 — Actualizando repositorio (git pull)"
    cd "${PROJECT_ROOT}"
    info "Directorio: ${PROJECT_ROOT}"
    if git pull; then
        log "Repositorio actualizado correctamente."
    else
        warn "git pull falló. Continuando con código local..."
    fi
else
    info "Omitiendo: git pull (--skip-pull)"
fi

# =============================================================================
# PASO 2 — Firewall
# =============================================================================
if ! $SKIP_FIREWALL; then
    section "Paso 2/8 — Configurando firewall"
    FIREWALL_SCRIPT="${SCRIPTS_DIR}/security/firewall.sh"
    if [ -f "${FIREWALL_SCRIPT}" ]; then
        info "Ejecutando ${FIREWALL_SCRIPT}..."
        bash "${FIREWALL_SCRIPT}"
        log "Firewall configurado."
    else
        err "No se encontró ${FIREWALL_SCRIPT}"
    fi
else
    info "Omitiendo: firewall (--skip-firewall)"
fi

# =============================================================================
# PASO 3 — RAID 1
# =============================================================================
if ! $SKIP_RAID; then
    section "Paso 3/8 — Configurando RAID 1"
    RAID_SCRIPT="${SCRIPTS_DIR}/storage/setup_raid.sh"
    if [ -f "${RAID_SCRIPT}" ]; then
        info "Ejecutando ${RAID_SCRIPT}..."
        bash "${RAID_SCRIPT}" 500
        log "RAID 1 configurado."
    else
        err "No se encontró ${RAID_SCRIPT}"
    fi
else
    info "Omitiendo: RAID (--skip-raid)"
fi

# =============================================================================
# PASO 4 — LVM sobre RAID
# =============================================================================
if ! $SKIP_LVM; then
    section "Paso 4/8 — Configurando LVM sobre RAID"
    LVM_SCRIPT="${SCRIPTS_DIR}/storage/setup_lvm.sh"
    if [ -f "${LVM_SCRIPT}" ]; then
        info "Ejecutando ${LVM_SCRIPT}..."
        bash "${LVM_SCRIPT}"
        log "LVM configurado."
    else
        err "No se encontró ${LVM_SCRIPT}"
    fi
else
    info "Omitiendo: LVM (--skip-lvm)"
fi

# =============================================================================
# PASO 5 — Usuarios y grupos
# =============================================================================
if ! $SKIP_USERS; then
    section "Paso 5/8 — Creando usuarios y grupos"
    USERS_SCRIPT="${SCRIPTS_DIR}/users.sh"
    if [ -f "${USERS_SCRIPT}" ]; then
        info "Ejecutando ${USERS_SCRIPT}..."
        bash "${USERS_SCRIPT}"
        log "Usuarios y grupos configurados."
    else
        err "No se encontró ${USERS_SCRIPT}"
    fi

    # Instalar políticas sudoers en el host
    POLICY_SCRIPT="${SCRIPTS_DIR}/security/install_uv_policies.sh"
    PASS_SCRIPT="${SCRIPTS_DIR}/security/apply_password_policy.sh"

    if [ -f "${POLICY_SCRIPT}" ]; then
        info "Instalando políticas sudoers en host..."
        bash "${POLICY_SCRIPT}"
        log "Sudoers instaladas en host."
    else
        warn "No se encontró ${POLICY_SCRIPT} — omitiendo instalación de sudoers en host."
    fi

    if [ -f "${PASS_SCRIPT}" ]; then
        info "Aplicando política de contraseñas en host..."
        bash "${PASS_SCRIPT}"
        log "Política de contraseñas aplicada en host."
    else
        warn "No se encontró ${PASS_SCRIPT} — omitiendo política de contraseñas en host."
    fi
else
    info "Omitiendo: usuarios (--skip-users)"
fi

# =============================================================================
# PASO 6 — Samba
# =============================================================================
if ! $SKIP_SAMBA; then
    section "Paso 6/8 — Preparando host para Samba"
    SAMBA_SCRIPT="${SCRIPTS_DIR}/samba-setup.sh"
    if [ -f "${SAMBA_SCRIPT}" ]; then
        info "Ejecutando ${SAMBA_SCRIPT}..."
        bash "${SAMBA_SCRIPT}"
        log "Samba configurado."
    else
        err "No se encontró ${SAMBA_SCRIPT}"
    fi
else
    info "Omitiendo: Samba (--skip-samba)"
fi

# =============================================================================
# PASO 7 — Levantar stack de contenedores
# =============================================================================
if ! $SKIP_STACK; then
    section "Paso 7/8 — Levantando stack de contenedores"
    START_SCRIPT="${SCRIPTS_DIR}/start.sh"
    if [ -f "${START_SCRIPT}" ]; then
        info "Ejecutando ${START_SCRIPT} ${BUILD_FLAG}..."
        bash "${START_SCRIPT}" ${BUILD_FLAG}
        log "Stack levantado."
    else
        err "No se encontró ${START_SCRIPT}"
    fi
else
    info "Omitiendo: stack (--skip-stack)"
fi

# =============================================================================
# PASO 8 — Cron job de backup automático
# =============================================================================
if ! $SKIP_CRON; then
    section "Paso 8/8 — Configurando cron job de backup"
    BACKUP_SCRIPT="${SCRIPTS_DIR}/automation/backup.sh"
    if [ -f "${BACKUP_SCRIPT}" ]; then
        if ! crontab -l 2>/dev/null | grep -q "backup.sh"; then
            (crontab -l 2>/dev/null; echo "0 2 * * * ${BACKUP_SCRIPT} >> /var/log/uv_backup.log 2>&1") | crontab -
            log "Cron job de backup configurado — diario a las 02:00."
        else
            warn "Cron job de backup ya existe — omitiendo."
        fi
    else
        warn "No se encontró ${BACKUP_SCRIPT} — omitiendo cron de backup."
    fi
else
    info "Omitiendo: cron backup (--skip-cron)"
fi

# =============================================================================
# RESUMEN FINAL
# =============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           Despliegue completado exitosamente                ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Pasos ejecutados:"
! $SKIP_PULL     && echo "    ✓ git pull"           || echo "    ✗ git pull (omitido)"
! $SKIP_FIREWALL && echo "    ✓ firewall"           || echo "    ✗ firewall (omitido)"
! $SKIP_RAID     && echo "    ✓ RAID 1"             || echo "    ✗ RAID 1 (omitido)"
! $SKIP_LVM      && echo "    ✓ LVM"                || echo "    ✗ LVM (omitido)"
! $SKIP_USERS    && echo "    ✓ usuarios/grupos"    || echo "    ✗ usuarios/grupos (omitido)"
! $SKIP_SAMBA    && echo "    ✓ Samba"              || echo "    ✗ Samba (omitido)"
! $SKIP_STACK    && echo "    ✓ stack Podman"        || echo "    ✗ stack Podman (omitido)"
! $SKIP_CRON     && echo "    ✓ cron backup"           || echo "    ✗ cron backup (omitido)"
echo ""
echo -e "${YELLOW}  Verificar estado:${NC}"
echo "    podman ps -a"
echo "    sudo ufw status verbose"
echo "    cat /proc/mdstat"
echo "    sudo pvdisplay && sudo vgdisplay && sudo lvdisplay"
echo ""