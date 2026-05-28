# =============================================================================
# srv-dhcp-01 — Servidor DHCP
# Unidad para la Atención y Reparación Integral a las Víctimas
# Sistema Integrado de Gestión (SIG)
# =============================================================================
FROM ubuntu:22.04

LABEL maintainer="uv-infra-ti"
LABEL project="uv-sig"
LABEL description="Servidor DHCP — asignación dinámica de IPs a VLAN 20 y VLAN 30"
LABEL version="1.0"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        isc-dhcp-server \
        iproute2 \
        iputils-ping \
        procps \
        htop \
    && rm -rf /var/lib/apt/lists/*

# Copiar configuración
COPY dhcpd.conf /etc/dhcp/dhcpd.conf

# isc-dhcp-server necesita este archivo para el leasedb
RUN touch /var/lib/dhcp/dhcpd.leases

# Usuario no-root dedicado para dhcpd
RUN groupadd -r dhcpuser && useradd -r -g dhcpuser -s /usr/sbin/nologin dhcpuser \
    && chown dhcpuser:dhcpuser /var/lib/dhcp \
    && chown dhcpuser:dhcpuser /var/lib/dhcp/dhcpd.leases

# Copiar entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 67/udp
EXPOSE 68/udp

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD pgrep dhcpd || exit 1

ENTRYPOINT ["/entrypoint.sh"]