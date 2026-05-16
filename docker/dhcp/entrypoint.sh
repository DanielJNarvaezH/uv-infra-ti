#!/bin/bash
# =============================================================================
# entrypoint.sh — srv-dhcp-01
# Configura interfaces y arranca dhcpd
# =============================================================================

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [srv-dhcp-01] $*"; }

log "Iniciando servidor DHCP..."

# Esperar hasta 30 segundos a que aparezcan las interfaces de vlan20 y vlan30
# (se conectan después del arranque via podman network connect)
log "Esperando interfaces de red (vlan20 y vlan30)..."
for i in $(seq 1 30); do
    IFACE_COUNT=$(ip link show | grep -c "^[0-9].*eth" || true)
    if [ "${IFACE_COUNT}" -ge 3 ]; then
        log "3 interfaces detectadas después de ${i}s."
        break
    fi
    sleep 1
done

# Detectar todas las interfaces (excluir loopback)
INTERFACES=$(ip link show | awk -F'[@:]' '/^[0-9]+:/ && !/lo/ {gsub(/ /,"",$2); if($2!="") print $2}' | tr '\n' ' ')
log "Interfaces detectadas: ${INTERFACES}"

# Configurar el archivo de interfaces para isc-dhcp-server
echo "INTERFACESv4=\"${INTERFACES}\"" > /etc/default/isc-dhcp-server

log "Validando dhcpd.conf..."
dhcpd -t -cf /etc/dhcp/dhcpd.conf && log "Configuración válida." || {
    log "ERROR: dhcpd.conf inválido"
    exit 1
}

log "Arrancando dhcpd en interfaces: ${INTERFACES}"
exec /usr/sbin/dhcpd -f -cf /etc/dhcp/dhcpd.conf -lf /var/lib/dhcp/dhcpd.leases