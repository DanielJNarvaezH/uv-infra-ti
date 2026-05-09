# Usamos la imagen oficial de PHP-FPM basada en Alpine Linux
FROM php:8.2-fpm-alpine

# Metadatos
LABEL maintainer="Juan-Devgo"
LABEL description="Contenedor PHP-FPM seguro y optimizado para producción"

# Instalar dependencias del sistema y extensiones de PHP necesarias
RUN apk add --no-cache \
    tzdata \
    && docker-php-ext-install pdo pdo_mysql mysqli opcache \
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

# El comando por defecto ya es "php-fpm" en la imagen base
CMD ["php-fpm"]