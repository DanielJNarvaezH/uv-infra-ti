# =============================================================================
# srv-db-01 — Servidor de Base de Datos
# Unidad para la Atención y Reparación Integral a las Víctimas
# Sistema Integrado de Gestión (SIG)
# =============================================================================
# Imagen base oficial — versión fijada para reproducibilidad
FROM docker.io/library/postgres:16

# Metadatos del contenedor
LABEL maintainer="uv-infra-ti"
LABEL project="uv-sig"
LABEL description="Base de datos principal del SIG — Unidad de Víctimas"
LABEL version="1.0"

# Build args
ARG SSH_PUBLIC_KEY=""

# Variables de entorno documentadas (se inyectan desde .env via docker-compose)
# POSTGRES_DB       : nombre de la base de datos (usado en HEALTHCHECK)
# POSTGRES_USER     : usuario administrador de PostgreSQL
# POSTGRES_PASSWORD : contraseña del usuario administrador
# TZ / PGTZ         : zona horaria del servidor y de PostgreSQL

RUN apt-get update && apt-get install -y \
        chrony \
        ntpsec-ntpdate \
        openssh-server \
        sudo \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Configuración SSH segura
# - Puerto 2222 (no el 22 estándar)
# - Sin login root
# - Solo autenticación por llave pública
# - Sin contraseñas
# -----------------------------------------------------------------------------
RUN mkdir -p /var/run/sshd \
    && sed -i 's/^#\?Port .*/Port 2222/'               /etc/ssh/sshd_config \
    && sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config \
    && echo "AllowUsers uv_dbadmin" >> /etc/ssh/sshd_config

# Usuario dedicado para acceso SSH a la BD (no root, no postgres)
RUN useradd -m -s /bin/bash uv_dbadmin \
    && mkdir -p /home/uv_dbadmin/.ssh \
    && chmod 700 /home/uv_dbadmin/.ssh

# Instalar llave pública si se pasó como build arg
RUN if [ -n "${SSH_PUBLIC_KEY}" ]; then \
        echo "${SSH_PUBLIC_KEY}" > /home/uv_dbadmin/.ssh/authorized_keys \
        && chmod 600 /home/uv_dbadmin/.ssh/authorized_keys \
        && chown -R uv_dbadmin:uv_dbadmin /home/uv_dbadmin/.ssh; \
    fi

# El directorio oficial de inicialización de postgres:16.
# Todo archivo .sql o .sh colocado aquí se ejecuta en orden alfanumérico
# la primera vez que el contenedor arranca con un volumen vacío.
COPY ./docker/db/init/ /docker-entrypoint-initdb.d/

# Copiar entrypoint personalizado que arranca SSH + PostgreSQL
COPY ./docker/db/entrypoint-ssh.sh /entrypoint-ssh.sh
RUN chmod +x /entrypoint-ssh.sh

EXPOSE 5432
EXPOSE 2222

# Healthcheck: verifica que la BD responde antes de que otros contenedores dependan de ella
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB} || exit 1

ENTRYPOINT ["/entrypoint-ssh.sh"]