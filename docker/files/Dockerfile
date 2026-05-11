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

RUN apt-get update && apt-get install -y --no-install-recommends \
        samba \
        samba-common-bin \
        smbclient \
        tini \
        ca-certificates \
        chrony \
        ntpsec-ntpdate \
    && rm -rf /var/lib/apt/lists/*
    
ARG SAMBA_GID=1050
ARG SAMBA_UID=1050

RUN groupadd -g ${SAMBA_GID} g_files \
    && useradd -M -u ${SAMBA_UID} -g g_files -s /usr/sbin/nologin uv_files_user

COPY smb.conf /etc/samba/smb.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
    && mkdir -p /srv/uv_docs /var/log/samba \
    && chown root:g_files /srv/uv_docs \
    && chmod 2770 /srv/uv_docs

EXPOSE 445

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]