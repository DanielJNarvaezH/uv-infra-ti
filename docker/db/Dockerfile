# =============================================================================
# srv-db-01 — Servidor de Base de Datos
# Unidad para la Atención y Reparación Integral a las Víctimas
# Sistema Integrado de Gestión (SIG)
# =============================================================================
# Imagen base oficial — versión fijada para reproducibilidad
FROM postgres:16

# Metadatos del contenedor
LABEL maintainer="uv-infra-ti"
LABEL project="uv-sig"
LABEL description="Base de datos principal del SIG — Unidad de Víctimas"
LABEL version="1.0"

RUN apt-get update && apt-get install -y \
        chrony \
        ntpsec-ntpdate  \
    && rm -rf /var/lib/apt/lists/*


# El directorio oficial de inicialización de postgres:16.
# Todo archivo .sql o .sh colocado aquí se ejecuta en orden alfanumérico
# la primera vez que el contenedor arranca con un volumen vacío.
COPY init/ /docker-entrypoint-initdb.d/

# El puerto estándar de PostgreSQL (documentación; el binding real va en compose)
EXPOSE 5432

# Healthcheck: verifica que la BD responde antes de que otros contenedores dependan de ella
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB} || exit 1
