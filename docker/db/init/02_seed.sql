-- =============================================================================
-- 02_seed.sql
-- Datos de prueba representativos del SIG — NO usar en producción
-- Unidad para la Atención y Reparación Integral a las Víctimas
-- =============================================================================

\echo '>>> [uv_sig] Cargando datos de prueba (seed)...'

-- -----------------------------------------------------------------------------
-- Funcionarios de la Unidad
-- -----------------------------------------------------------------------------
INSERT INTO sig.funcionarios (id, nombre, apellido, cargo, email) VALUES
    ('a1000000-0000-0000-0000-000000000001',
     'María Fernanda', 'Ríos Castillo',
     'Profesional de Atención a Víctimas',
      'mfrios@unidadvictimas.co'),
    ('a1000000-0000-0000-0000-000000000002',
     'Carlos Andrés', 'Muñoz Herrera',
     'Coordinador de Registro y Valoración',
     'camuñoz@unidadvictimas.co'),
    ('a1000000-0000-0000-0000-000000000003',
     'Luz Marina', 'Torres Quintero',
     'Psicóloga — Área de Atención Psicosocial',
     'lmtorres@unidadvictimas.co');

-- -----------------------------------------------------------------------------
-- Víctimas (datos ficticios — solo representativos del sistema)
-- -----------------------------------------------------------------------------
INSERT INTO sig.victimas (
    id, tipo_documento_id, numero_documento,
    nombre, apellido, fecha_nacimiento,
    genero_id, etnia_id,
    municipio_residencia, departamento_residencia,
    municipio_hecho, departamento_hecho,
    fecha_declaracion, fecha_valoracion, estado_registro_id
) VALUES
    -- Víctima 1: Incluida, desplazamiento forzado
    ('b2000000-0000-0000-0000-000000000001',
     1, '1098765432',
     'Rosa Elena', 'Suárez Palomino',
     '1985-03-12', 1, 1,
     'Armenia', 'Quindío',
     'El Castillo', 'Meta',
     '2020-06-15', '2020-09-01',
     (SELECT id FROM sig.estado_registro WHERE codigo = 'INCLUIDO')),
    -- Víctima 2: En valoración, homicidio de familiar
    ('b2000000-0000-0000-0000-000000000002',
     1, '43210987',
     'Juan Pablo', 'Giraldo Mesa',
     '1972-11-28', 1, 1,
     'Calarcá', 'Quindío',
     'Puerto Rico', 'Caquetá',
     '2024-01-10', NULL,
     (SELECT id FROM sig.estado_registro WHERE codigo = 'EN_VALORACION')),
    -- Víctima 3: Incluida, comunidad indígena, desplazamiento
    ('b2000000-0000-0000-0000-000000000003',
     5, 'PA-2031455',
     'Carmenza', 'Yagarí Domicó',
     '1990-07-04', 2, 2,
     'Quibdó', 'Chocó',
     'Bagadó', 'Chocó',
     '2019-03-22', '2019-07-15',
     (SELECT id FROM sig.estado_registro WHERE codigo = 'INCLUIDO'));

-- Hechos victimizantes asociados
INSERT INTO sig.victima_hechos (victima_id, hecho_id, fecha_hecho, municipio_hecho) VALUES
    ('b2000000-0000-0000-0000-000000000001',
     (SELECT id FROM sig.hecho_victimizante WHERE codigo = 'DESPLAZAMIENTO'),
     '2020-05-30', 'El Castillo'),
    ('b2000000-0000-0000-0000-000000000002',
     (SELECT id FROM sig.hecho_victimizante WHERE codigo = 'HOMICIDIO'),
     '2023-12-15', 'Puerto Rico'),
    ('b2000000-0000-0000-0000-000000000003',
     (SELECT id FROM sig.hecho_victimizante WHERE codigo = 'DESPLAZAMIENTO'),
     '2019-03-10', 'Bagadó'),
    ('b2000000-0000-0000-0000-000000000003',
     (SELECT id FROM sig.hecho_victimizante WHERE codigo = 'VIOLENCIA_SEXUAL'),
     '2019-03-10', 'Bagadó');

-- -----------------------------------------------------------------------------
-- Atenciones prestadas
-- -----------------------------------------------------------------------------
INSERT INTO sig.atenciones (
    victima_id, tipo_atencion_id, funcionario_id,
    fecha_atencion, canal, sede, descripcion, resultado
) VALUES
    ('b2000000-0000-0000-0000-000000000001',
     (SELECT id FROM sig.tipo_atencion WHERE codigo = 'ORIENTACION'),
     'a1000000-0000-0000-0000-000000000001',
     '2020-09-10 09:00:00-05', 'PRESENCIAL', 'PCEV Armenia',
     'Orientación sobre oferta institucional y medidas de reparación.',
     'Víctima informada. Se agenda seguimiento.'),
    ('b2000000-0000-0000-0000-000000000001',
     (SELECT id FROM sig.tipo_atencion WHERE codigo = 'PSICOSOCIAL'),
     'a1000000-0000-0000-0000-000000000003',
     '2020-10-05 10:30:00-05', 'PRESENCIAL', 'PCEV Armenia',
     'Primera sesión de atención psicosocial individual.',
     'Se identifican afectaciones emocionales por el desplazamiento. Plan de trabajo acordado.'),
    ('b2000000-0000-0000-0000-000000000003',
     (SELECT id FROM sig.tipo_atencion WHERE codigo = 'JURIDICA'),
     'a1000000-0000-0000-0000-000000000001',
     '2024-03-18 14:00:00-05', 'VIRTUAL', 'Centro Regional Chocó',
     'Consulta sobre proceso de restitución de tierras y enfoque diferencial étnico.',
     'Se remite a la Unidad de Restitución de Tierras y se agenda consulta previa.');

-- -----------------------------------------------------------------------------
-- Procesos de reparación
-- -----------------------------------------------------------------------------
INSERT INTO sig.proceso_reparacion (
    victima_id, tipo_reparacion_id, estado_id,
    funcionario_id, fecha_solicitud, monto_cop, numero_resolucion, observaciones
) VALUES
    ('b2000000-0000-0000-0000-000000000001',
     (SELECT id FROM sig.tipo_reparacion WHERE codigo = 'INDEMNIZACION'),
     (SELECT id FROM sig.estado_reparacion WHERE codigo = 'COMPLETADA'),
     'a1000000-0000-0000-0000-000000000002',
     '2021-01-20', 17956008.00, 'RES-2021-00342',
     'Indemnización administrativa por desplazamiento forzado. Pago efectuado.'),
    ('b2000000-0000-0000-0000-000000000003',
     (SELECT id FROM sig.tipo_reparacion WHERE codigo = 'RESTITUCION_TIERRAS'),
     (SELECT id FROM sig.estado_reparacion WHERE codigo = 'EN_PROCESO'),
     'a1000000-0000-0000-0000-000000000002',
     '2024-04-02', NULL, NULL,
     'Proceso de restitución con enfoque étnico. Pendiente consulta previa con comunidad Emberá.');

-- -----------------------------------------------------------------------------
-- Eventos de participación
-- -----------------------------------------------------------------------------
INSERT INTO sig.eventos_participacion (
    id, tipo_participacion_id, nombre,
    fecha_evento, municipio, departamento, descripcion, funcionario_id
) VALUES
    ('c3000000-0000-0000-0000-000000000001',
     (SELECT id FROM sig.tipo_participacion WHERE codigo = 'MESA_DEPARTAMENTAL'),
     'Mesa Departamental de Participación de Víctimas — Quindío 2024-I',
     '2024-04-25', 'Armenia', 'Quindío',
     'Espacio de participación efectiva para el seguimiento a la política pública de víctimas.',
     'a1000000-0000-0000-0000-000000000001');

INSERT INTO sig.participacion_victimas (evento_id, victima_id, rol) VALUES
    ('c3000000-0000-0000-0000-000000000001',
     'b2000000-0000-0000-0000-000000000001',
     'DELEGADO');

\echo '>>> [uv_sig] Datos de prueba cargados correctamente.'
