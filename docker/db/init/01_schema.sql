-- =============================================================================
-- 01_schema.sql
-- Esquema inicial de la base de datos uv_sig
-- Unidad para la Atención y Reparación Integral a las Víctimas
-- Sistema Integrado de Gestión (SIG)
-- =============================================================================
-- Procesos misionales representados:
--   1. Registro y Valoración
--   2. Atención
--   3. Reparación Integral
--   4. Participación
-- =============================================================================
-- Ejecutado automáticamente por postgres:16 al inicializar el volumen vacío.
-- =============================================================================

\echo '>>> [uv_sig] Iniciando creación del esquema...'

-- -----------------------------------------------------------------------------
-- Extensiones
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";   -- UUIDs como PK (trazabilidad)
CREATE EXTENSION IF NOT EXISTS "unaccent";    -- búsquedas sin distinción de tildes

-- -----------------------------------------------------------------------------
-- Esquema dedicado (separa el SIG del esquema public)
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS sig;

-- Asegurar que uv_admin trabaje en el esquema sig por defecto
ALTER USER uv_admin SET search_path TO sig, public;
GRANT ALL PRIVILEGES ON SCHEMA sig TO uv_admin;


-- =============================================================================
-- PROCESO 1: REGISTRO Y VALORACIÓN
-- Gestión del registro de víctimas y la valoración de su declaración.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Catálogos de referencia (lookup tables)
-- -----------------------------------------------------------------------------

CREATE TABLE sig.tipo_documento (
    id          SMALLSERIAL PRIMARY KEY,
    codigo      VARCHAR(10)  NOT NULL UNIQUE,
    descripcion VARCHAR(60)  NOT NULL
);
COMMENT ON TABLE sig.tipo_documento IS 'Catálogo de tipos de documento de identidad';

INSERT INTO sig.tipo_documento (codigo, descripcion) VALUES
    ('CC',  'Cédula de Ciudadanía'),
    ('TI',  'Tarjeta de Identidad'),
    ('RC',  'Registro Civil'),
    ('CE',  'Cédula de Extranjería'),
    ('PA',  'Pasaporte'),
    ('NUIP','Número Único de Identificación Personal');


CREATE TABLE sig.genero (
    id          SMALLSERIAL PRIMARY KEY,
    codigo      VARCHAR(10)  NOT NULL UNIQUE,
    descripcion VARCHAR(40)  NOT NULL
);
COMMENT ON TABLE sig.genero IS 'Catálogo de géneros (enfoque diferencial SIG)';

INSERT INTO sig.genero (codigo, descripcion) VALUES
    ('M',   'Masculino'),
    ('F',   'Femenino'),
    ('NB',  'No Binario'),
    ('ND',  'No Declara');


CREATE TABLE sig.etnia (
    id          SMALLSERIAL PRIMARY KEY,
    codigo      VARCHAR(20)  NOT NULL UNIQUE,
    descripcion VARCHAR(80)  NOT NULL
);
COMMENT ON TABLE sig.etnia IS 'Catálogo de grupos étnicos (enfoque diferencial)';

INSERT INTO sig.etnia (codigo, descripcion) VALUES
    ('NINGUNA',        'Sin pertenencia étnica'),
    ('INDIGENA',       'Indígena'),
    ('AFROCOLOMBIANO', 'Afrocolombiano / Afrodescendiente'),
    ('RAIZAL',         'Raizal del Archipiélago'),
    ('PALENQUERO',     'Palenquero'),
    ('ROM',            'Rom / Gitano');


CREATE TABLE sig.hecho_victimizante (
    id          SMALLSERIAL PRIMARY KEY,
    codigo      VARCHAR(30)  NOT NULL UNIQUE,
    descripcion VARCHAR(120) NOT NULL,
    activo      BOOLEAN      NOT NULL DEFAULT TRUE
);
COMMENT ON TABLE sig.hecho_victimizante IS
    'Catálogo de hechos victimizantes reconocidos por la Ley 1448 de 2011';

INSERT INTO sig.hecho_victimizante (codigo, descripcion) VALUES
    ('DESPLAZAMIENTO',         'Desplazamiento forzado'),
    ('HOMICIDIO',              'Homicidio de familiar'),
    ('DESAPARICION_FORZADA',   'Desaparición forzada'),
    ('SECUESTRO',              'Secuestro'),
    ('MINAS',                  'Víctima de minas antipersonal / MAP / MUSE'),
    ('RECLUTAMIENTO',          'Reclutamiento ilícito'),
    ('VIOLENCIA_SEXUAL',       'Delitos contra la libertad e integridad sexual'),
    ('TORTURA',                'Tortura'),
    ('DESPOJO_TIERRAS',        'Despojo o abandono forzado de tierras'),
    ('ATAQUE_POBLACION',       'Actos terroristas / Ataques a población civil'),
    ('PERDIDA_BIENES',         'Pérdida de bienes muebles o inmuebles'),
    ('LESIONES_PERSONALES',    'Lesiones personales físicas o psicológicas');


CREATE TABLE sig.estado_registro (
    id          SMALLSERIAL PRIMARY KEY,
    codigo      VARCHAR(20)  NOT NULL UNIQUE,
    descripcion VARCHAR(80)  NOT NULL
);
COMMENT ON TABLE sig.estado_registro IS
    'Estados del proceso de Registro y Valoración (Ley 1448 de 2011)';

INSERT INTO sig.estado_registro (codigo, descripcion) VALUES
    ('INCLUIDO',          'Incluido en el Registro Único de Víctimas (RUV)'),
    ('NO_INCLUIDO',       'No incluido — declaración no supera valoración'),
    ('EN_VALORACION',     'En proceso de valoración por la Unidad'),
    ('PENDIENTE_INFO',    'Pendiente de información adicional del declarante'),
    ('CESACION',          'Cesación de la condición de víctima'),
    ('FALLECIDO',         'Víctima fallecida — registro actualizado');


-- -----------------------------------------------------------------------------
-- Tabla principal: víctimas
-- -----------------------------------------------------------------------------

CREATE TABLE sig.victimas (
    id                  UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    -- Identificación
    tipo_documento_id   SMALLINT     NOT NULL REFERENCES sig.tipo_documento(id),
    numero_documento    VARCHAR(20)  NOT NULL,
    nombre              VARCHAR(80)  NOT NULL,
    apellido            VARCHAR(80)  NOT NULL,
    -- Datos personales (enfoque diferencial)
    fecha_nacimiento    DATE,
    genero_id           SMALLINT     REFERENCES sig.genero(id),
    etnia_id            SMALLINT     REFERENCES sig.etnia(id),
    discapacidad        BOOLEAN      NOT NULL DEFAULT FALSE,
    -- Ubicación
    municipio_residencia VARCHAR(80),
    departamento_residencia VARCHAR(60),
    municipio_hecho     VARCHAR(80),
    departamento_hecho  VARCHAR(60),
    -- Proceso de registro
    fecha_declaracion   DATE,
    fecha_valoracion    DATE,
    estado_registro_id  SMALLINT     NOT NULL REFERENCES sig.estado_registro(id),
    observaciones_valoracion TEXT,
    -- Auditoría
    creado_en           TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    actualizado_en      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    -- Restricción: documento único por tipo
    CONSTRAINT uq_victima_documento UNIQUE (tipo_documento_id, numero_documento)
);

COMMENT ON TABLE sig.victimas IS
    'Registro principal de víctimas del conflicto armado (Ley 1448 de 2011)';
COMMENT ON COLUMN sig.victimas.discapacidad IS
    'Bandera de enfoque diferencial — víctimas con discapacidad';

-- Relación m:n víctimas ↔ hechos victimizantes
CREATE TABLE sig.victima_hechos (
    victima_id      UUID        NOT NULL REFERENCES sig.victimas(id) ON DELETE CASCADE,
    hecho_id        SMALLINT    NOT NULL REFERENCES sig.hecho_victimizante(id),
    fecha_hecho     DATE,
    municipio_hecho VARCHAR(80),
    PRIMARY KEY (victima_id, hecho_id)
);
COMMENT ON TABLE sig.victima_hechos IS
    'Asociación entre víctima y los hechos victimizantes declarados';


-- =============================================================================
-- PROCESO 2: ATENCIÓN
-- Registro de las atenciones (orientación, psicosocial, jurídica, etc.)
-- prestadas a las víctimas por los funcionarios de la Unidad.
-- =============================================================================

CREATE TABLE sig.tipo_atencion (
    id          SMALLSERIAL PRIMARY KEY,
    codigo      VARCHAR(30)  NOT NULL UNIQUE,
    descripcion VARCHAR(100) NOT NULL,
    activo      BOOLEAN      NOT NULL DEFAULT TRUE
);
COMMENT ON TABLE sig.tipo_atencion IS
    'Catálogo de tipos de atención ofrecidos por la Unidad';

INSERT INTO sig.tipo_atencion (codigo, descripcion) VALUES
    ('ORIENTACION',         'Orientación e información sobre derechos y oferta institucional'),
    ('PSICOSOCIAL',         'Atención psicosocial individual'),
    ('PSICOSOCIAL_GRUPAL',  'Atención psicosocial grupal / colectiva'),
    ('JURIDICA',            'Asesoría jurídica'),
    ('REMISION',            'Remisión a otra entidad del SNARIV'),
    ('AYUDA_HUMANITARIA',   'Entrega de ayuda humanitaria de emergencia'),
    ('INDEMNIZACION_INFO',  'Información sobre indemnización administrativa'),
    ('REPARACION_INFO',     'Información sobre medidas de reparación integral');


CREATE TABLE sig.funcionarios (
    id          UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    nombre      VARCHAR(80)  NOT NULL,
    apellido    VARCHAR(80)  NOT NULL,
    cargo       VARCHAR(100),
    email       VARCHAR(120) UNIQUE,
    activo      BOOLEAN      NOT NULL DEFAULT TRUE,
    creado_en   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE sig.funcionarios IS
    'Funcionarios de la Unidad que registran atenciones y gestionan casos';


CREATE TABLE sig.atenciones (
    id              UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    victima_id      UUID         NOT NULL REFERENCES sig.victimas(id),
    tipo_atencion_id SMALLINT    NOT NULL REFERENCES sig.tipo_atencion(id),
    funcionario_id  UUID         REFERENCES sig.funcionarios(id),
    -- Detalle de la atención
    fecha_atencion  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    canal           VARCHAR(30)  NOT NULL DEFAULT 'PRESENCIAL'
                        CHECK (canal IN ('PRESENCIAL','TELEFONICA','VIRTUAL','CORREO')),
    sede            VARCHAR(80),
    descripcion     TEXT,
    resultado       TEXT,
    -- Auditoría
    creado_en       TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE sig.atenciones IS
    'Registro histórico de atenciones prestadas a cada víctima';
COMMENT ON COLUMN sig.atenciones.canal IS
    'Canal por el que se prestó la atención';


-- =============================================================================
-- PROCESO 3: REPARACIÓN INTEGRAL
-- Seguimiento a las medidas de reparación establecidas por la Ley 1448:
-- indemnización, restitución, rehabilitación, satisfacción y garantías de NR.
-- =============================================================================

CREATE TABLE sig.tipo_reparacion (
    id          SMALLSERIAL PRIMARY KEY,
    codigo      VARCHAR(30)  NOT NULL UNIQUE,
    descripcion VARCHAR(100) NOT NULL
);
COMMENT ON TABLE sig.tipo_reparacion IS
    'Catálogo de medidas de reparación integral (Ley 1448 de 2011, Art. 25)';

INSERT INTO sig.tipo_reparacion (codigo, descripcion) VALUES
    ('INDEMNIZACION',       'Indemnización administrativa por vía administrativa'),
    ('RESTITUCION_TIERRAS', 'Restitución de tierras y territorios'),
    ('REHABILITACION',      'Rehabilitación física, mental y psicosocial'),
    ('SATISFACCION',        'Medidas de satisfacción (actos de reconocimiento, memoria)'),
    ('GARANTIA_NO_REP',     'Garantías de no repetición');


CREATE TABLE sig.estado_reparacion (
    id          SMALLSERIAL PRIMARY KEY,
    codigo      VARCHAR(20)  NOT NULL UNIQUE,
    descripcion VARCHAR(80)  NOT NULL
);

INSERT INTO sig.estado_reparacion (codigo, descripcion) VALUES
    ('PENDIENTE',    'Pendiente de iniciar'),
    ('EN_PROCESO',   'En proceso de gestión'),
    ('COMPLETADA',   'Medida ejecutada / entregada'),
    ('RECHAZADA',    'No procede — ver observaciones'),
    ('SUSPENDIDA',   'Suspendida temporalmente');


CREATE TABLE sig.proceso_reparacion (
    id                  UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    victima_id          UUID         NOT NULL REFERENCES sig.victimas(id),
    tipo_reparacion_id  SMALLINT     NOT NULL REFERENCES sig.tipo_reparacion(id),
    estado_id           SMALLINT     NOT NULL REFERENCES sig.estado_reparacion(id),
    funcionario_id      UUID         REFERENCES sig.funcionarios(id),
    -- Datos de la medida
    fecha_solicitud     DATE         NOT NULL DEFAULT CURRENT_DATE,
    fecha_resolucion    DATE,
    monto_cop           NUMERIC(18,2),   -- aplica solo para indemnización
    numero_resolucion   VARCHAR(40),     -- referencia del acto administrativo
    observaciones       TEXT,
    -- Auditoría
    creado_en           TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    actualizado_en      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE sig.proceso_reparacion IS
    'Seguimiento a medidas de reparación integral por víctima';
COMMENT ON COLUMN sig.proceso_reparacion.monto_cop IS
    'Valor en pesos colombianos de la indemnización (NULL para medidas no monetarias)';


-- =============================================================================
-- PROCESO 4: PARTICIPACIÓN
-- Registro de espacios y actividades de participación efectiva de las víctimas.
-- =============================================================================

CREATE TABLE sig.tipo_participacion (
    id          SMALLSERIAL PRIMARY KEY,
    codigo      VARCHAR(30)  NOT NULL UNIQUE,
    descripcion VARCHAR(100) NOT NULL
);
COMMENT ON TABLE sig.tipo_participacion IS
    'Catálogo de tipos de espacio de participación de víctimas';

INSERT INTO sig.tipo_participacion (codigo, descripcion) VALUES
    ('MESA_MUNICIPAL',      'Mesa Municipal de Participación de Víctimas'),
    ('MESA_DEPARTAMENTAL',  'Mesa Departamental de Participación de Víctimas'),
    ('MESA_NACIONAL',       'Mesa Nacional de Participación de Víctimas'),
    ('TALLER',              'Taller de formación / capacitación'),
    ('AUDIENCIA_PUBLICA',   'Audiencia pública'),
    ('CONSULTA_PREVIA',     'Consulta previa con comunidades étnicas'),
    ('ENCUENTRO_REGIONAL',  'Encuentro regional de víctimas');


CREATE TABLE sig.eventos_participacion (
    id                   UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    tipo_participacion_id SMALLINT    NOT NULL REFERENCES sig.tipo_participacion(id),
    nombre               VARCHAR(160) NOT NULL,
    fecha_evento         DATE         NOT NULL,
    municipio            VARCHAR(80),
    departamento         VARCHAR(60),
    descripcion          TEXT,
    funcionario_id       UUID         REFERENCES sig.funcionarios(id),
    creado_en            TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE sig.eventos_participacion IS
    'Registro de espacios y eventos de participación de víctimas';


-- Asistencia de víctimas a eventos de participación
CREATE TABLE sig.participacion_victimas (
    evento_id   UUID     NOT NULL REFERENCES sig.eventos_participacion(id) ON DELETE CASCADE,
    victima_id  UUID     NOT NULL REFERENCES sig.victimas(id),
    rol         VARCHAR(40) DEFAULT 'ASISTENTE'
                    CHECK (rol IN ('ASISTENTE','DELEGADO','PONENTE','MODERADOR')),
    PRIMARY KEY (evento_id, victima_id)
);
COMMENT ON TABLE sig.participacion_victimas IS
    'Asistencia y rol de las víctimas en cada evento de participación';


-- =============================================================================
-- ÍNDICES — Optimización de consultas frecuentes
-- =============================================================================

-- Búsqueda de víctimas por documento (query más común en ventanilla)
CREATE INDEX idx_victimas_documento
    ON sig.victimas (tipo_documento_id, numero_documento);

-- Búsqueda de víctimas por nombre/apellido (búsqueda parcial)
CREATE INDEX idx_victimas_nombre
    ON sig.victimas USING gin (to_tsvector('spanish', nombre || ' ' || apellido));

-- Atenciones por víctima y fecha (historial de atenciones)
CREATE INDEX idx_atenciones_victima_fecha
    ON sig.atenciones (victima_id, fecha_atencion DESC);

-- Reparaciones por víctima y estado (seguimiento de casos)
CREATE INDEX idx_reparacion_victima_estado
    ON sig.proceso_reparacion (victima_id, estado_id);

-- Eventos de participación por fecha
CREATE INDEX idx_eventos_fecha
    ON sig.eventos_participacion (fecha_evento DESC);


-- =============================================================================
-- FUNCIÓN DE AUDITORÍA — Actualiza updated_at automáticamente
-- =============================================================================

CREATE OR REPLACE FUNCTION sig.fn_set_actualizado_en()
RETURNS TRIGGER AS $$
BEGIN
    NEW.actualizado_en = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_victimas_actualizado_en
    BEFORE UPDATE ON sig.victimas
    FOR EACH ROW EXECUTE FUNCTION sig.fn_set_actualizado_en();

CREATE TRIGGER trg_reparacion_actualizado_en
    BEFORE UPDATE ON sig.proceso_reparacion
    FOR EACH ROW EXECUTE FUNCTION sig.fn_set_actualizado_en();


-- =============================================================================
-- PERMISOS — uv_admin tiene control total sobre el esquema sig
-- =============================================================================

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA sig TO uv_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA sig TO uv_admin;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA sig TO uv_admin;

-- Permisos por defecto para objetos futuros
ALTER DEFAULT PRIVILEGES IN SCHEMA sig
    GRANT ALL PRIVILEGES ON TABLES TO uv_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA sig
    GRANT ALL PRIVILEGES ON SEQUENCES TO uv_admin;


\echo '>>> [uv_sig] Esquema creado correctamente.'
\echo '>>> Tablas: victimas, atenciones, proceso_reparacion, eventos_participacion'
\echo '>>> Catálogos: tipo_documento, genero, etnia, hecho_victimizante,'
\echo '>>>            tipo_atencion, tipo_reparacion, tipo_participacion'
