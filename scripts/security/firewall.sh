#!/usr/bin/env bash
# =============================================================================
# firewall.sh — SEG-1: Configuración de Firewall
# Infraestructura TI — Unidad para la Atención y Reparación Integral a las Víctimas
# Universidad del Quindío — Semestre 2026-1
# =============================================================================
#
# DESCRIPCIÓN:
#   Aplica reglas de firewall con UFW (con fallback a iptables si UFW no está).
#   Implementa el principio de mínimo privilegio: deniega todo por defecto
#   y abre solo los puertos estrictamente necesarios por segmento de red.
#
# SEGMENTACIÓN DE RED:
#   VLAN 10 — 10.0.10.0/24  Servidores   (BD, NTP, DHCP, Samba, PHP-FPM)
#   VLAN 20 — 10.0.20.0/24  Administración (acceso privilegiado)
#   VLAN 30 — 10.0.30.0/24  Usuarios      (acceso restringido)
#   VLAN 40 — 10.0.40.0/24  DMZ           (Web, DNS, SMTP, Proxy)
#
# USO:
#   sudo bash scripts/security/firewall.sh          # aplica reglas UFW
#   sudo bash scripts/security/firewall.sh --reset  # resetea a estado limpio
#
# VERIFICACIÓN:
#   sudo ufw status verbose
#   sudo iptables -L -n -v
#
# =============================================================================

set -euo pipefail

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[OK]${NC}  $*"; }
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
section() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# ── Verificar root ────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERR]${NC}  Ejecutar como root: sudo bash $0" >&2
    exit 1
fi

# ── Parámetros ────────────────────────────────────────────────────────────────
RESET_MODE=false
[[ "${1:-}" == "--reset" ]] && RESET_MODE=true

# ── Subredes por VLAN ─────────────────────────────────────────────────────────
VLAN10="10.0.10.0/24"   # Servidores
VLAN20="10.0.20.0/24"   # Administración
VLAN30="10.0.30.0/24"   # Usuarios
VLAN40="10.0.40.0/24"   # DMZ

# ── Verificar UFW ─────────────────────────────────────────────────────────────
if ! command -v ufw &>/dev/null; then
    warn "UFW no encontrado — instalando..."
    apt-get install -y --no-install-recommends ufw -q
fi
log "UFW disponible: $(ufw version | head -1)"

# ── Modo reset ────────────────────────────────────────────────────────────────
if $RESET_MODE; then
    warn "Reseteando UFW a estado limpio..."
    ufw --force reset
    log "UFW reseteado. Ejecuta el script sin --reset para aplicar reglas."
    exit 0
fi

# =============================================================================
section "1. Política por defecto — DENY incoming, ALLOW outgoing"
# =============================================================================
# Desactivar UFW temporalmente para aplicar reglas sin interrupciones
ufw --force disable

# Establecer políticas por defecto
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward

log "Política: DENY incoming | ALLOW outgoing | DENY forward"

# =============================================================================
section "2. SSH — Puerto 2222 (no el 22 estándar)"
# =============================================================================
# Acceso SSH solo desde VLAN 20 (Administración) y VLAN 10 (Servidores)
ufw allow from "${VLAN20}" to any port 2222 proto tcp comment "SSH — Admins VLAN20"
ufw allow from "${VLAN10}" to any port 2222 proto tcp comment "SSH — Servidores VLAN10"
log "SSH (2222/tcp): permitido desde VLAN10 y VLAN20"

# =============================================================================
section "3. HTTP/HTTPS — Puertos 80 y 443 (acceso público DMZ)"
# =============================================================================
ufw allow 80/tcp   comment "HTTP  — acceso público"
ufw allow 443/tcp  comment "HTTPS — acceso público"
log "HTTP (80/tcp) y HTTPS (443/tcp): abiertos públicamente"

# Puerto 8080, 8081, 8082, 8083 solo desde VLAN 20 (administración y pruebas)
ufw allow from "${VLAN20}" to any port 8080 proto tcp comment "Proxy admin — VLAN20"
ufw allow from "${VLAN20}" to any port 8081 proto tcp comment "Proxy panel — VLAN20"
ufw allow from "${VLAN20}" to any port 8082 proto tcp comment "Web-01 test — VLAN20"
ufw allow from "${VLAN20}" to any port 8083 proto tcp comment "Web-02 test — VLAN20"
log "Puertos 8080-8083: permitidos solo desde VLAN20 (administración)"

# =============================================================================
section "4. PostgreSQL — Puerto 5432 (solo VLAN10 → VLAN20)"
# =============================================================================
# La BD solo acepta conexiones desde servidores de la VLAN10 y admins de VLAN20
ufw allow from "${VLAN10}" to any port 5432 proto tcp comment "PostgreSQL — VLAN10 servidores"
ufw allow from "${VLAN20}" to any port 5432 proto tcp comment "PostgreSQL — VLAN20 admins"
log "PostgreSQL (5432/tcp): permitido desde VLAN10 y VLAN20 únicamente"

# =============================================================================
section "5. Samba — Puerto 445 (solo LAN, bloqueado desde DMZ)"
# =============================================================================
ufw allow from "${VLAN10}" to any port 445 proto tcp comment "Samba — VLAN10"
ufw allow from "${VLAN20}" to any port 445 proto tcp comment "Samba — VLAN20"
ufw allow from "${VLAN30}" to any port 445 proto tcp comment "Samba — VLAN30 usuarios"
# DMZ (VLAN40) explícitamente bloqueada
ufw deny  from "${VLAN40}" to any port 445 proto tcp comment "Samba — BLOQUEAR DMZ"
log "Samba (445/tcp): permitido desde VLAN10/20/30, bloqueado desde VLAN40 (DMZ)"

# =============================================================================
section "6. DHCP — Puertos 67/68 UDP"
# =============================================================================
ufw allow 67/udp comment "DHCP server"
ufw allow 68/udp comment "DHCP client"
log "DHCP (67-68/udp): abiertos"

# =============================================================================
section "7. DNS — Puerto 53 TCP/UDP"
# =============================================================================
ufw allow 53/tcp comment "DNS TCP"
ufw allow 53/udp comment "DNS UDP"
log "DNS (53/tcp+udp): abiertos"

# =============================================================================
section "8. SMTP — Puertos 25 y 587 (solo VLAN20 Administración)"
# =============================================================================
ufw allow from "${VLAN20}" to any port 25  proto tcp comment "SMTP    — solo VLAN20"
ufw allow from "${VLAN20}" to any port 587 proto tcp comment "SMTP/TLS — solo VLAN20"
# Puerto 1025 de MailHog (submission interno) solo desde VLAN10 y VLAN20
ufw allow from "${VLAN10}" to any port 1025 proto tcp comment "MailHog SMTP interno — VLAN10"
ufw allow from "${VLAN20}" to any port 1025 proto tcp comment "MailHog SMTP interno — VLAN20"
log "SMTP (25/587/tcp): solo VLAN20 | MailHog (1025): VLAN10 y VLAN20"

# =============================================================================
section "9. MailHog UI — Puerto 8025 (solo VLAN20 Administración)"
# =============================================================================
ufw allow from "${VLAN20}" to any port 8025 proto tcp comment "MailHog UI — solo VLAN20"
log "MailHog UI (8025/tcp): solo VLAN20"

# =============================================================================
section "10. NTP — Puerto 123 UDP"
# =============================================================================
ufw allow from "${VLAN10}" to any port 123 proto udp comment "NTP — VLAN10"
ufw allow from "${VLAN20}" to any port 123 proto udp comment "NTP — VLAN20"
ufw allow from "${VLAN30}" to any port 123 proto udp comment "NTP — VLAN30"
ufw allow from "${VLAN40}" to any port 123 proto udp comment "NTP — VLAN40"
log "NTP (123/udp): permitido desde todas las VLANs"

# =============================================================================
section "11. Activar UFW"
# =============================================================================
# Habilitar logging para auditoría
ufw logging on

# Activar UFW
echo "y" | ufw enable

# =============================================================================
section "12. Verificación final"
# =============================================================================
echo ""
ufw status verbose
echo ""

# Resumen de reglas aplicadas
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              Firewall configurado correctamente              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Política:    DENY incoming | ALLOW outgoing"
echo "  SSH:         2222/tcp      → VLAN10, VLAN20"
echo "  HTTP/HTTPS:  80,443/tcp    → público"
echo "  PostgreSQL:  5432/tcp      → VLAN10, VLAN20"
echo "  Samba:       445/tcp       → VLAN10/20/30 (bloqueado DMZ)"
echo "  DHCP:        67-68/udp     → abierto"
echo "  DNS:         53/tcp+udp    → abierto"
echo "  SMTP:        25,587/tcp    → VLAN20"
echo "  MailHog UI:  8025/tcp      → VLAN20"
echo "  NTP:         123/udp       → todas las VLANs"
echo ""
echo -e "${YELLOW}  Para verificar:${NC}"
echo "    sudo ufw status verbose"
echo "    sudo iptables -L -n -v"
echo ""
echo -e "${YELLOW}  Para resetear:${NC}"
echo "    sudo bash $0 --reset"
