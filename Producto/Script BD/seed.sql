-- ============================================================================
-- 40dB — Seed de desarrollo
-- Ejecutado por: supabase db reset
-- ============================================================================

-- Catálogo de estados (obligatorio para el trigger set_initial_estado)
INSERT INTO tipo_estado (nombre, descripcion, orden) VALUES
  ('En espera',   'Reporte creado, sin asignar',     1),
  ('En atencion', 'Funcionario asignado trabajando', 2),
  ('Atendido',    'Reporte resuelto',                3),
  ('Descartado',  'Reporte invalido o duplicado',    4);

-- Catálogo de comunas: las 32 comunas de la Provincia de Santiago (Gran Santiago).
-- Códigos INE oficiales. El front matchea contra `nombre` (case-insensitive y
-- sin tildes vía Nominatim reverse-geocode, ver api.md §4.5.1).
INSERT INTO comuna (nombre, region, codigo) VALUES
  ('Santiago',            'Metropolitana', '13101'),
  ('Cerrillos',           'Metropolitana', '13102'),
  ('Cerro Navia',         'Metropolitana', '13103'),
  ('Conchalí',            'Metropolitana', '13104'),
  ('El Bosque',           'Metropolitana', '13105'),
  ('Estación Central',    'Metropolitana', '13106'),
  ('Huechuraba',          'Metropolitana', '13107'),
  ('Independencia',       'Metropolitana', '13108'),
  ('La Cisterna',         'Metropolitana', '13109'),
  ('La Florida',          'Metropolitana', '13110'),
  ('La Granja',           'Metropolitana', '13111'),
  ('La Pintana',          'Metropolitana', '13112'),
  ('La Reina',            'Metropolitana', '13113'),
  ('Las Condes',          'Metropolitana', '13114'),
  ('Lo Barnechea',        'Metropolitana', '13115'),
  ('Lo Espejo',           'Metropolitana', '13116'),
  ('Lo Prado',            'Metropolitana', '13117'),
  ('Macul',               'Metropolitana', '13118'),
  ('Maipú',               'Metropolitana', '13119'),
  ('Ñuñoa',               'Metropolitana', '13120'),
  ('Pedro Aguirre Cerda', 'Metropolitana', '13121'),
  ('Peñalolén',           'Metropolitana', '13122'),
  ('Providencia',         'Metropolitana', '13123'),
  ('Pudahuel',            'Metropolitana', '13124'),
  ('Quilicura',           'Metropolitana', '13125'),
  ('Quinta Normal',       'Metropolitana', '13126'),
  ('Recoleta',            'Metropolitana', '13127'),
  ('Renca',               'Metropolitana', '13128'),
  ('San Joaquín',         'Metropolitana', '13129'),
  ('San Miguel',          'Metropolitana', '13130'),
  ('San Ramón',           'Metropolitana', '13131'),
  ('Vitacura',            'Metropolitana', '13132')
ON CONFLICT (codigo) DO NOTHING;

-- Sensores mock (ubición referencial en el centro de cada comuna)
-- Nota: la columna `ubicacion` geography se genera automáticamente desde lat/lng
INSERT INTO sensor (comuna_id, nombre, latitud, longitud) VALUES
  ((SELECT id FROM comuna WHERE codigo = '13101'), 'Plaza de Armas - Centro',  -33.43800, -70.65010),
  ((SELECT id FROM comuna WHERE codigo = '13123'), 'Plaza Italia - Norte',      -33.43720, -70.64830),
  ((SELECT id FROM comuna WHERE codigo = '13114'), 'Apoquindo - Las Condes',    -33.41450, -70.59780);

-- Lecturas mock variadas (algunas sobre umbral 65 dB, otras debajo)
-- Se insertan con timestamps recientes para que el matching IoT funcione en tests
INSERT INTO lectura (sensor_id, nivel_db, timestamp_medicion) VALUES
  ((SELECT id FROM sensor WHERE nombre = 'Plaza de Armas - Centro'),  72.5,  now() - interval '2 minutes'),
  ((SELECT id FROM sensor WHERE nombre = 'Plaza de Armas - Centro'),  58.3,  now() - interval '5 minutes'),
  ((SELECT id FROM sensor WHERE nombre = 'Plaza Italia - Norte'),      78.1,  now() - interval '1 minute'),
  ((SELECT id FROM sensor WHERE nombre = 'Plaza Italia - Norte'),      63.0,  now() - interval '8 minutes'),
  ((SELECT id FROM sensor WHERE nombre = 'Apoquindo - Las Condes'),    55.2,  now() - interval '3 minutes');

-- Nota: usuarios y reportes mock requieren filas en auth.users primero.
-- Se crean manualmente via Supabase Auth en el entorno local o se agregan
-- con supabase-specific helpers. No se incluyen aquí para evitar dependencias
-- de auth en el seed básico.
