# =============================================================================
# srv-files-01 — Servidor de Archivos Samba
# Sistema Integrado de Gestión (SIG)
# =============================================================================
FROM debian:bookworm-slim

LABEL maintainer="uv-infra-ti"
LABEL project="uv-sig"
LABEL description="Servidor de archivos Samba — SIG"
LABEL version="1.0"

ENV DEBIAN_FRONTEND=noninteractive

# Build args
ARG SSH_PUBLIC_KEY=""

RUN apt-get update && apt-get install -y --no-install-recommends \
        samba \
        samba-common-bin \
        smbclient \
        tini \
        ca-certificates \
        chrony \
        ntpsec-ntpdate \
        openssh-server \
        sudo \
        procps \
        htop \
    && rm -rf /var/lib/apt/lists/*

# Copiar política sudo desde config/
COPY config/uv_policies.sudoers /etc/sudoers.d/uv_policies
RUN chmod 0440 /etc/sudoers.d/uv_policies && visudo -cf /etc/sudoers.d/uv_policies

# Copiar script de política de contraseñas y ejecutarlo
COPY ./scripts/security/apply_password_policy.sh /usr/local/bin/apply_password_policy.sh
RUN chmod +x /usr/local/bin/apply_password_policy.sh && /usr/local/bin/apply_password_policy.sh

# Llave pública SSH — se pasa en tiempo de build, nunca se hardcodea
# Uso: podman build --build-arg SSH_PUBLIC_KEY="$(cat ~/.ssh/id_rsa.pub)" ...
ARG SAMBA_UID=1050
ARG SAMBA_GID=1050

RUN groupadd -g ${SAMBA_GID} g_files \
    && useradd -M -u ${SAMBA_UID} -g g_files -s /usr/sbin/nologin uv_files_user

# -----------------------------------------------------------------------------
# Configuración SSH segura
# - Puerto 2222
# - Sin login root
# - Solo autenticación por llave pública
# -----------------------------------------------------------------------------
RUN mkdir -p /var/run/sshd \
    && sed -i 's/^#\?Port .*/Port 2222/'               /etc/ssh/sshd_config \
    && sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config \
    && echo "AllowUsers uv_admin uv_webmaster" >> /etc/ssh/sshd_config

# Usuario dedicado para acceso SSH al servidor de archivos
RUN useradd -m -s /bin/bash uv_admin \
    && mkdir -p /home/uv_admin/.ssh \
    && chmod 700 /home/uv_admin/.ssh

# Instalar llave pública si se pasó como build arg
RUN if [ -n "${SSH_PUBLIC_KEY}" ]; then \
        echo "${SSH_PUBLIC_KEY}" > /home/uv_admin/.ssh/authorized_keys \
        && chmod 600 /home/uv_admin/.ssh/authorized_keys \
        && chown -R uv_admin:uv_admin /home/uv_admin/.ssh; \
    fi

RUN useradd -m -s /bin/bash uv_webmaster \
    && mkdir -p /home/uv_webmaster/.ssh \
    && chmod 700 /home/uv_webmaster/.ssh

RUN if [ -n "${SSH_PUBLIC_KEY}" ]; then \
        echo "${SSH_PUBLIC_KEY}" > /home/uv_webmaster/.ssh/authorized_keys \
        && chmod 600 /home/uv_webmaster/.ssh/authorized_keys \
        && chown -R uv_webmaster:uv_webmaster /home/uv_webmaster/.ssh; \
    fi
    
COPY ./docker/files/smb.conf /etc/samba/smb.conf
COPY ./docker/files/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
    && mkdir -p /srv/uv_docs /var/log/samba \
    && chown root:g_files /srv/uv_docs \
    && chmod 2770 /srv/uv_docs

EXPOSE 445
EXPOSE 2222

# Healthcheck: verifica que smbd está corriendo y la config es válida
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD testparm -s /etc/samba/smb.conf >/dev/null 2>&1 && pgrep smbd >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]