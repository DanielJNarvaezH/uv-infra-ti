#!/bin/bash
# =============================================================================
# entrypoint-ssh.sh — Arranca SSH + PostgreSQL en srv-db-01
# =============================================================================

# Regenerar host keys si no existen
ssh-keygen -A 2>/dev/null || true

# Crear directorio runtime que necesita sshd en Debian trixie
mkdir -p /run/sshd

# Arrancar sshd en background — sin set -e para que un fallo no mate todo
/usr/sbin/sshd -D &

echo "[srv-db-01] sshd arrancado en puerto 2222"

# Pasar el control al entrypoint original de postgres:16
exec /usr/local/bin/docker-entrypoint.sh postgres