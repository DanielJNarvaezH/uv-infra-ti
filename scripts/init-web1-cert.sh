#!/bin/bash

# ==========================================
# VARIABLES DE CONFIGURACIÓN
# ==========================================
DOMAINS=("unidadvictimas.gov.co" "www.unidadvictimas.gov.co")
EMAIL="admin@unidadvictimas.gov.co"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DATA_PATH="${PROJECT_ROOT}/docker/web/certbot/conf"
WEBROOT_PATH="${PROJECT_ROOT}/docker/web/certbot/www"
RSA_KEY_SIZE=4096
STAGING=1 # Cambia a 1 si estás haciendo pruebas para no bloquearte en Let's Encrypt

# ==========================================

if [ -d "$DATA_PATH/live/${DOMAINS[0]}" ]; then
  echo "Los certificados ya existen para ${DOMAINS[0]}. Saliendo."
  exit 0
fi

echo "### Creando directorios..."
mkdir -p "$DATA_PATH/live/${DOMAINS[0]}"
mkdir -p "$WEBROOT_PATH"

echo "### Creando certificado falso (dummy) temporal de OpenSSL..."
path="/etc/letsencrypt/live/${DOMAINS[0]}"
docker-compose run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:$RSA_KEY_SIZE -days 1\
    -keyout '$path/privkey.pem' \
    -out '$path/fullchain.pem' \
    -subj '/CN=localhost'" certbot
echo

echo "### Iniciando Nginx..."
docker-compose up --force-recreate -d srv-web-01
echo

echo "### Borrando certificado temporal..."
docker-compose run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/${DOMAINS[0]} && \
  rm -Rf /etc/letsencrypt/archive/${DOMAINS[0]} && \
  rm -Rf /etc/letsencrypt/renewal/${DOMAINS[0]}.conf" certbot
echo

echo "### Solicitando certificado real de Let's Encrypt..."
# Unir dominios con -d
domain_args=""
for domain in "${DOMAINS[@]}"; do
  domain_args="$domain_args -d $domain"
done

# Activar modo staging si es necesario
if [ $STAGING != "0" ]; then staging_arg="--staging"; else staging_arg=""; fi

docker-compose run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $domain_args \
    --email $EMAIL \
    --rsa-key-size $RSA_KEY_SIZE \
    --agree-tos \
    --force-renewal \
    --non-interactive" certbot
echo

echo "### Recargando Nginx para aplicar los nuevos certificados..."
docker-compose exec srv-web-01 nginx -s reload
echo "### ¡Proceso completado con éxito!"