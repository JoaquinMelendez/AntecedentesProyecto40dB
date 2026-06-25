-- ============================================================================
-- Catálogo de comunas: completar las 32 comunas de la Provincia de Santiago.
--
-- Motivación: el seed inicial solo cargó 3 (Santiago / Providencia / Las Condes).
-- El front resuelve `comuna_id` para `POST /reportes` matchando el nombre que
-- devuelve Nominatim (reverse-geocode de lat/lng) contra `comuna.nombre`. Si la
-- comuna no está catalogada, el back cae al fallback `usuario.comuna_id`
-- (api.md §4.5.1) y el reporte queda mal-ruteado.
--
-- Idempotente: `ON CONFLICT (codigo) DO NOTHING` evita romper en re-runs.
-- ============================================================================

INSERT INTO comuna (nombre, region, codigo) VALUES
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
  ('Lo Barnechea',        'Metropolitana', '13115'),
  ('Lo Espejo',           'Metropolitana', '13116'),
  ('Lo Prado',            'Metropolitana', '13117'),
  ('Macul',               'Metropolitana', '13118'),
  ('Maipú',               'Metropolitana', '13119'),
  ('Ñuñoa',               'Metropolitana', '13120'),
  ('Pedro Aguirre Cerda', 'Metropolitana', '13121'),
  ('Peñalolén',           'Metropolitana', '13122'),
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
