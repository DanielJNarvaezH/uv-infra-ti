FROM docker.io/ubuntu/bind9:latest

LABEL maintainer="uv-infra-ti"
LABEL project="uv-sig"
LABEL description="Servidor DNS autoritativo (BIND9) para la zona uv.interno y unidadvictimas.corp"
LABEL version="1.0"

# Variables de entorno documentadas
# TZ: zona horaria del servidor
ENV TZ=America/Bogota

# Copiar configuración principal
COPY named.conf /etc/bind/named.conf

# Copiar archivos de zona
COPY zones/ /etc/bind/zones/

# Ajustar permisos para el usuario bind
RUN mkdir -p /var/cache/bind && chown -R bind:bind /var/cache/bind /etc/bind/zones && chmod 644 /etc/bind/zones/*

# Exponer puertos DNS
EXPOSE 53/tcp 53/udp

# Nota: la imagen base ejecuta named como root y luego hace drop a usuario bind
# (no usar USER bind aquí, para que named pueda hacer bind al puerto 53)

# Healthcheck: verifica que named esté corriendo y la configuración sea válida
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD named-checkconf && pgrep named > /dev/null || exit 1
