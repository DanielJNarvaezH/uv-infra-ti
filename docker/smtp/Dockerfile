# =============================================================================
# srv-smtp-01 — Servidor de Correo (MailHog)
# Unidad para la Atención y Reparación Integral a las Víctimas
# Sistema Integrado de Gestión (SIG)
# =============================================================================
# Nota: la imagen mailhog/mailhog corre con el usuario "mailhog" (no root)
# internamente — verificado en https://github.com/mailhog/MailHog
# =============================================================================
FROM docker.io/mailhog/mailhog:latest

LABEL maintainer="uv-infra-ti"
LABEL project="uv-sig"
LABEL description="Servidor SMTP de pruebas (MailHog) — SIG"
LABEL version="1.0"

# Variables de entorno documentadas (se pasan desde docker-compose.yml)
# MH_SMTP_BIND_ADDR  : dirección y puerto SMTP  (default: 0.0.0.0:1025)
# MH_API_BIND_ADDR   : dirección y puerto API   (default: 0.0.0.0:8025)
# MH_UI_BIND_ADDR    : dirección y puerto UI    (default: 0.0.0.0:8025)
# MH_STORAGE         : backend de almacenamiento (memory | maildir)

# Puerto SMTP (submission) — scripts internos apuntan aquí
EXPOSE 1025

# Puerto de la interfaz web — restringido a VLAN 20 por regla de firewall
EXPOSE 8025

# Healthcheck: verifica que la API de MailHog responde
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:8025/api/v2/messages > /dev/null || exit 1