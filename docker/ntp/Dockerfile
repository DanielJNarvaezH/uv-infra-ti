FROM ubuntu:22.04

# Metadatos
LABEL maintainer="uv-infra-ti"
LABEL project="uv-sig"
LABEL description="Contenedor NTP para sincronización horaria en la infraestructura de la UV"
LABEL version="1.0"

RUN apt update && apt install -y chrony && apt clean

COPY chrony.conf /etc/chrony/chrony.conf

EXPOSE 123/udp

CMD ["chronyd", "-d", "-x", "-f", "/etc/chrony/chrony.conf"]
