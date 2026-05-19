FROM ubuntu/bind9:latest

LABEL maintainer="uv-infra-ti"
LABEL project="uv-sig"
LABEL description="Servidor DNS autoritativo (BIND9) para la zona uv.local y unidadvictimas.co"
LABEL version="1.0"

# Copiar configuración principal
COPY named.conf /etc/bind/named.conf

# Copiar archivos de zona
COPY zones/ /var/cache/bind/

# Ajustar permisos para el usuario bind
RUN chown -R bind:bind /var/cache/bind && chmod 644 /var/cache/bind/*

# Exponer puertos DNS
EXPOSE 53/tcp 53/udp

# Nota: la imagen base ejecuta named como root y luego hace drop a usuario bind
# (no usar USER bind aquí, para que named pueda hacer bind al puerto 53)
