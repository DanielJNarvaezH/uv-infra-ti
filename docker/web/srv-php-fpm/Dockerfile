# Usamos la imagen oficial de PHP-FPM basada en Alpine Linux
FROM php:8.2-fpm-alpine

# Metadatos
LABEL maintainer="uv-infra-ti"
LABEL project="uv-sig"
LABEL description="Contenedor PHP-FPM seguro y optimizado para producción"
LABEL version="1.0"

# Instalar dependencias del sistema y extensiones de PHP necesarias
# libpq-dev: librería de desarrollo de PostgreSQL, requerida para compilar pdo_pgsql
RUN apk add --no-cache \
    tzdata \
    libpq-dev \
    && docker-php-ext-install pdo pdo_pgsql pdo_mysql mysqli opcache \
    && rm -rf /var/cache/apk/*

# Configurar la zona horaria
ENV TZ=America/Bogota
RUN cp /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Copiar configuraciones personalizadas
COPY ./config/php.ini /usr/local/etc/php/conf.d/custom-php.ini
COPY ./config/www.conf /usr/local/etc/php-fpm.d/zz-custom.conf

# Configurar el directorio de trabajo
WORKDIR /var/www/html

# Asegurar permisos correctos (el usuario www-data es estándar en imágenes PHP)
RUN chown -R www-data:www-data /var/www/html

# FPM corre en el puerto 9000 por defecto
EXPOSE 9000

# Healthcheck: verifica que php-fpm arranca y la config es válida
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD php-fpm -t 2>&1 | grep -q "successful" || exit 1

# El comando por defecto ya es "php-fpm" en la imagen base
CMD ["php-fpm"]