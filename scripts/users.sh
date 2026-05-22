#!/usr/bin/env bash
# =============================================================================
# users.sh — Creación de usuarios, grupos y permisos especiales
# Unidad para la Atención y Reparación Integral a las Víctimas — SIG
# =============================================================================
# Este script configura:
#   1. Grupos del sistema: g_admins, g_web, g_db, g_files
#   2. Usuarios del sistema: uv_admin, uv_webmaster, uv_dbadmin, uv_files_user
#   3. Asignación de usuarios a grupos
#   4. Permisos especiales: SETUID, SETGID, sticky bit
# =============================================================================
# Uso:
#   Ejecutar dentro del contenedor correspondiente:
#     podman exec -it srv-db-01    bash /opt/uv-infra-ti/users.sh
#     podman exec -it srv-files-01 bash /opt/uv-infra-ti/users.sh
#     podman exec -it srv-php-fpm  bash /opt/uv-infra-ti/users.sh
#
#   O ejecutar todo desde el host (aplica cada sección en su contenedor):
#     bash scripts/users.sh
# =============================================================================

set -euo pipefail

log()  { echo -e "\e[32m[$(date '+%H:%M:%S')][INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[$(date '+%H:%M:%S')][WARN]\e[0m $*"; }

# =============================================================================
# 1. GRUPOS DEL SISTEMA
# =============================================================================
# g_admins (GID 2000) — Administradores generales
# g_web    (GID 2010) — Administradores web
# g_db     (GID 2020) — Administradores de base de datos
# g_files  (GID 1050) — Usuarios del servidor de archivos (ya existe en srv-files-01)
# =============================================================================

crear_grupos() {
    log "Creando grupos del sistema..."

    groupadd -f -g 2000 g_admins 2>/dev/null && log "  ✓ g_admins (GID 2000) creado" \
        || warn "  ⚠ g_admins ya existe, omitiendo"

    groupadd -f -g 2010 g_web 2>/dev/null && log "  ✓ g_web (GID 2010) creado" \
        || warn "  ⚠ g_web ya existe, omitiendo"

    groupadd -f -g 2020 g_db 2>/dev/null && log "  ✓ g_db (GID 2020) creado" \
        || warn "  ⚠ g_db ya existe, omitiendo"

    groupadd -f -g 1050 g_files 2>/dev/null && log "  ✓ g_files (GID 1050) creado" \
        || warn "  ⚠ g_files ya existe, omitiendo"
}

# =============================================================================
# 2. USUARIOS DEL SISTEMA
# =============================================================================
# uv_admin      — Administrador general (srv-files-01)
# uv_webmaster  — Administrador web (srv-php-fpm)
# uv_dbadmin    — Administrador de base de datos (srv-db-01)
# uv_files_user — Usuario Samba para recursos compartidos (srv-files-01)
# =============================================================================

crear_usuarios() {
    log "Creando usuarios del sistema..."

    # uv_admin — administrador general con shell de login
    if ! id uv_admin >/dev/null 2>&1; then
        useradd -m -u 2001 -g g_admins -s /bin/bash uv_admin
        log "  ✓ uv_admin (UID 2001) creado — grupo principal: g_admins"
    else
        warn "  ⚠ uv_admin ya existe, omitiendo creación"
    fi

    # uv_webmaster — administrador web con shell de login
    if ! id uv_webmaster >/dev/null 2>&1; then
        useradd -m -u 2002 -g g_web -s /bin/bash uv_webmaster
        log "  ✓ uv_webmaster (UID 2002) creado — grupo principal: g_web"
    else
        warn "  ⚠ uv_webmaster ya existe, omitiendo creación"
    fi

    # uv_dbadmin — administrador de base de datos con shell de login
    if ! id uv_dbadmin >/dev/null 2>&1; then
        useradd -m -u 2003 -g g_db -s /bin/bash uv_dbadmin
        log "  ✓ uv_dbadmin (UID 2003) creado — grupo principal: g_db"
    else
        warn "  ⚠ uv_dbadmin ya existe, omitiendo creación"
    fi

    # uv_files_user — usuario de servicio Samba (sin shell de login)
    if ! id uv_files_user >/dev/null 2>&1; then
        useradd -M -u 2004 -g g_files -s /usr/sbin/nologin uv_files_user
        log "  ✓ uv_files_user (UID 2004) creado — grupo principal: g_files"
    else
        warn "  ⚠ uv_files_user ya existe, omitiendo creación"
    fi
}

# =============================================================================
# 3. ASIGNACIÓN DE USUARIOS A GRUPOS SECUNDARIIOS
# =============================================================================
# uv_admin      → g_admins, g_files
# uv_webmaster  → g_admins, g_web
# uv_dbadmin    → g_admins, g_db
# uv_files_user → g_files
# =============================================================================

asignar_grupos() {
    log "Asignando usuarios a grupos secundarios..."

    usermod -aG g_admins,g_files uv_admin 2>/dev/null \
        && log "  ✓ uv_admin → g_admins, g_files"

    usermod -aG g_admins,g_web uv_webmaster 2>/dev/null \
        && log "  ✓ uv_webmaster → g_admins, g_web"

    usermod -aG g_admins,g_db uv_dbadmin 2>/dev/null \
        && log "  ✓ uv_dbadmin → g_admins, g_db"

    usermod -aG g_files uv_files_user 2>/dev/null \
        && log "  ✓ uv_files_user → g_files"
}

# =============================================================================
# 4. PERMISOS ESPECIALES
# =============================================================================
# SETUID    (chmod u+s) en /usr/local/bin/uv-backup.sh
# SETGID    (chmod g+s) en /srv/uv_docs
# Sticky bit (chmod +t) en /tmp y /srv/uv_docs
# =============================================================================

configurar_permisos_especiales() {
    log "Configurando permisos especiales..."

    # --- SETUID en script de backup ---
    if [ -f /usr/local/bin/uv-backup.sh ]; then
        chmod u+s /usr/local/bin/uv-backup.sh
        log "  ✓ SETUID aplicado a /usr/local/bin/uv-backup.sh"
    else
        warn "  ⚠ /usr/local/bin/uv-backup.sh no encontrado — omitiendo SETUID"
    fi

    # --- SETGID en /srv/uv_docs ---
    if [ -d /srv/uv_docs ]; then
        chmod g+s /srv/uv_docs
        log "  ✓ SETGID aplicado a /srv/uv_docs"
    else
        warn "  ⚠ /srv/uv_docs no existe — omitiendo SETGID"
    fi

    # --- Sticky bit en /tmp ---
    chmod +t /tmp
    log "  ✓ Sticky bit aplicado a /tmp"

    # --- Sticky bit en /srv/uv_docs ---
    if [ -d /srv/uv_docs ]; then
        chmod +t /srv/uv_docs
        log "  ✓ Sticky bit aplicado a /srv/uv_docs"
    else
        warn "  ⚠ /srv/uv_docs no existe — omitiendo sticky bit"
    fi
}

# =============================================================================
# RESUMEN
# =============================================================================
resumen() {
    echo ""
    echo "============================================="
    echo "  RESUMEN — Usuarios y Grupos del Sistema"
    echo "============================================="
    echo ""
    echo "Grupos creados:"
    echo "  g_admins  GID 2000  — Administradores generales"
    echo "  g_web     GID 2010  — Administradores web"
    echo "  g_db      GID 2020  — Administradores BD"
    echo "  g_files   GID 1050  — Usuarios de archivos"
    echo ""
    echo "Usuarios creados:"
    echo "  uv_admin      UID 2001  Grupos: g_admins, g_files"
    echo "  uv_webmaster  UID 2002  Grupos: g_admins, g_web"
    echo "  uv_dbadmin    UID 2003  Grupos: g_admins, g_db"
    echo "  uv_files_user UID 2004  Grupos: g_files"
    echo ""
    echo "Permisos especiales:"
    echo "  SETUID     /usr/local/bin/uv-backup.sh  (ejecuta como propietario)"
    echo "  SETGID     /srv/uv_docs                (herencia de grupo)"
    echo "  Sticky bit /tmp                         (solo propietario borra)"
    echo "  Sticky bit /srv/uv_docs                (solo propietario borra)"
    echo "============================================="
}

# =============================================================================
# EJECUCIÓN
# =============================================================================
crear_grupos
crear_usuarios
asignar_grupos
configurar_permisos_especiales
resumen