# =============================================================================
# srv-smtp-01 — Servidor de Correo (MailHog)
# Unidad para la Atención y Reparación Integral a las Víctimas
# Sistema Integrado de Gestión (SIG)
# =============================================================================

FROM mailhog/mailhog:latest

LABEL maintainer="uv-infra-ti"
LABEL project="uv-sig"
LABEL description="Servidor SMTP de pruebas (MailHog) — SIG"
LABEL version="1.0"

# Puerto SMTP (submission) — scripts internos apuntan aquí
EXPOSE 1025

# Puerto de la interfaz web — restringido a VLAN 20 por regla de firewall
EXPOSE 8025
