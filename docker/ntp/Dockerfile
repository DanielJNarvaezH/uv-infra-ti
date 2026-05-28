# =============================================================================
# srv-ntp-01 — Servidor NTP (chrony)
# Unidad para la Atención y Reparación Integral a las Víctimas
# Sistema Integrado de Gestión (SIG)
# =============================================================================
FROM ubuntu:22.04

LABEL maintainer="uv-infra-ti"
LABEL project="uv-sig"
LABEL description="Contenedor NTP para sincronización horaria en la infraestructura de la UV"
LABEL version="1.0"

# Variables de entorno documentadas
ENV DEBIAN_FRONTEND=noninteractive
# TZ: zona horaria del servidor (heredada del host o definida en compose)
ENV TZ=America/Bogota

RUN apt-get update && apt-get install -y --no-install-recommends \
        chrony \
        procps \
        htop \
    && rm -rf /var/lib/apt/lists/*

COPY chrony.conf /etc/chrony/chrony.conf

EXPOSE 123/udp

# Healthcheck: verifica que chrony esté sincronizado con una fuente de tiempo
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD chronyc tracking | grep -i "reference id" || exit 1

CMD ["chronyd", "-d", "-x", "-f", "/etc/chrony/chrony.conf"]