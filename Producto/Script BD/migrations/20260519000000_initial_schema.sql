-- ============================================================================
-- 40dB — Migración inicial (canónica)
-- Spec: docs/bbdd.md (esta migración debe reflejar ese doc fielmente)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Extensiones
-- ----------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS postgis;

-- ----------------------------------------------------------------------------
-- 2. Catálogos
-- ----------------------------------------------------------------------------

CREATE TABLE comuna (
  id      int  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre  text NOT NULL UNIQUE,
  region  text,
  codigo  text UNIQUE
);

CREATE TABLE tipo_estado (
  id          int  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre      text NOT NULL UNIQUE,
  descripcion text,
  orden       int  NOT NULL DEFAULT 0
);

-- ----------------------------------------------------------------------------
-- 3. Usuario (perfil extendido sobre auth.users)
-- ----------------------------------------------------------------------------

CREATE TABLE usuario (
  id         uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  nombre     text NOT NULL,
  telefono   text,
  -- D9: tres roles. El admin es cross-comuna; promociones via endpoint
  -- protegido. SQL manual queda solo como bootstrap del primer admin.
  tipo       text NOT NULL DEFAULT 'ciudadano'
             CHECK (tipo IN ('ciudadano', 'municipalidad', 'admin')),
  comuna_id  int  REFERENCES comuna(id),
  activo     boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_usuario_tipo ON usuario(tipo);

-- ----------------------------------------------------------------------------
-- 4. Sensor
-- ----------------------------------------------------------------------------

CREATE TABLE sensor (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  comuna_id  int  NOT NULL REFERENCES comuna(id),
  nombre     text NOT NULL UNIQUE,
  latitud    numeric(10, 8) NOT NULL,
  longitud   numeric(11, 8) NOT NULL,
  ubicacion  geography(Point, 4326)
             GENERATED ALWAYS AS (
               ST_SetSRID(ST_MakePoint(longitud, latitud), 4326)::geography
             ) STORED,
  activo     boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_sensor_comuna    ON sensor(comuna_id);
CREATE INDEX idx_sensor_ubicacion ON sensor USING GIST (ubicacion);

-- ----------------------------------------------------------------------------
-- 5. Lectura (telemetría IoT, particionada — bbdd.md §3.5 / D8)
-- ----------------------------------------------------------------------------
-- PARTITION BY RANGE (timestamp_medicion) para escalar a ~30 sensores @ 5-10s.
-- La PK y la UNIQUE incluyen la partition key porque Postgres lo exige.

CREATE TABLE lectura (
  id                 bigint GENERATED ALWAYS AS IDENTITY,
  sensor_id          uuid NOT NULL REFERENCES sensor(id) ON DELETE CASCADE,
  nivel_db           numeric(5, 2) NOT NULL,
  timestamp_medicion timestamptz NOT NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id, timestamp_medicion),
  -- Idempotencia ante QoS 1 / reintentos del sensor (iot.md §6.3)
  CONSTRAINT uq_lectura_sensor_timestamp UNIQUE (sensor_id, timestamp_medicion)
) PARTITION BY RANGE (timestamp_medicion);

-- Particiones mensuales para 2026-05..2026-12 + DEFAULT como red de seguridad.
-- Roadmap: automatizar con pg_partman (bbdd.md §10.3).
CREATE TABLE lectura_2026_05 PARTITION OF lectura
  FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE lectura_2026_06 PARTITION OF lectura
  FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE lectura_2026_07 PARTITION OF lectura
  FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE lectura_2026_08 PARTITION OF lectura
  FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE lectura_2026_09 PARTITION OF lectura
  FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE lectura_2026_10 PARTITION OF lectura
  FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE lectura_2026_11 PARTITION OF lectura
  FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE lectura_2026_12 PARTITION OF lectura
  FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');
CREATE TABLE lectura_default PARTITION OF lectura DEFAULT;

-- Índices a nivel parent: Postgres los propaga a cada partición.
CREATE INDEX idx_lectura_timestamp        ON lectura(timestamp_medicion);
CREATE INDEX idx_lectura_sensor_timestamp ON lectura(sensor_id, timestamp_medicion);

-- ----------------------------------------------------------------------------
-- 6. Reporte
-- ----------------------------------------------------------------------------

CREATE TABLE reporte (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id                  uuid NOT NULL REFERENCES usuario(id),
  atendido_por_id             uuid REFERENCES usuario(id),
  comuna_id                   int  NOT NULL REFERENCES comuna(id),
  titulo                      text NOT NULL,
  descripcion                 text NOT NULL,
  latitud                     numeric(10, 8) NOT NULL,
  longitud                    numeric(11, 8) NOT NULL,
  ubicacion                   geography(Point, 4326)
                              GENERATED ALWAYS AS (
                                ST_SetSRID(ST_MakePoint(longitud, latitud), 4326)::geography
                              ) STORED,
  -- Evidencia IoT 1:1 (prototipo; N:M queda en roadmap bbdd.md §10.1).
  -- FK compuesta porque lectura es particionada y su PK incluye timestamp_medicion (D8).
  -- chk_evidencia_pair garantiza que ambas columnas vayan juntas.
  lectura_evidencia_id        bigint,
  lectura_evidencia_timestamp timestamptz,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_evidencia_pair CHECK (
    (lectura_evidencia_id IS NULL     AND lectura_evidencia_timestamp IS NULL) OR
    (lectura_evidencia_id IS NOT NULL AND lectura_evidencia_timestamp IS NOT NULL)
  ),
  CONSTRAINT fk_reporte_lectura_evidencia
    FOREIGN KEY (lectura_evidencia_id, lectura_evidencia_timestamp)
    REFERENCES lectura(id, timestamp_medicion)
    ON DELETE SET NULL
);

CREATE INDEX idx_reporte_usuario      ON reporte(usuario_id);
CREATE INDEX idx_reporte_comuna       ON reporte(comuna_id);
CREATE INDEX idx_reporte_atendido_por ON reporte(atendido_por_id)
  WHERE atendido_por_id IS NOT NULL;
CREATE INDEX idx_reporte_ubicacion    ON reporte USING GIST (ubicacion);
-- Acelera el lookup del FK ON DELETE SET NULL.
CREATE INDEX idx_reporte_evidencia    ON reporte(lectura_evidencia_id, lectura_evidencia_timestamp)
  WHERE lectura_evidencia_id IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 7. Historial de estados
-- ----------------------------------------------------------------------------

CREATE TABLE historial_estado (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reporte_id     uuid NOT NULL REFERENCES reporte(id) ON DELETE CASCADE,
  tipo_estado_id int  NOT NULL REFERENCES tipo_estado(id),
  usuario_id     uuid REFERENCES usuario(id),
  comentario     text,
  created_at     timestamptz NOT NULL DEFAULT now()
);

-- Obtener estado actual de un reporte es O(log n) con este índice
CREATE INDEX idx_historial_reporte_created
  ON historial_estado(reporte_id, created_at DESC);

-- ----------------------------------------------------------------------------
-- 8. Triggers
-- ----------------------------------------------------------------------------

-- 8.1 Auto-crear perfil al registrarse (Supabase Auth → public.usuario)
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.usuario (id, nombre, tipo)
  VALUES (
    NEW.id,
    COALESCE(
      NEW.raw_user_meta_data->>'full_name',
      NEW.raw_user_meta_data->>'name',
      split_part(NEW.email, '@', 1)
    ),
    'ciudadano'
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- 8.2 Estado inicial "En espera" al insertar reporte
CREATE OR REPLACE FUNCTION public.set_initial_estado()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_estado_id int;
BEGIN
  SELECT id INTO v_estado_id
  FROM public.tipo_estado
  WHERE nombre = 'En espera'
  LIMIT 1;

  IF v_estado_id IS NULL THEN
    RAISE EXCEPTION 'tipo_estado "En espera" no existe en el catalogo';
  END IF;

  INSERT INTO public.historial_estado (reporte_id, tipo_estado_id, usuario_id)
  VALUES (NEW.id, v_estado_id, NEW.usuario_id);

  RETURN NEW;
END;
$$;

CREATE TRIGGER on_reporte_created
AFTER INSERT ON public.reporte
FOR EACH ROW EXECUTE FUNCTION public.set_initial_estado();

-- 8.3 Mantener updated_at automático
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER usuario_set_updated_at BEFORE UPDATE ON usuario
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER reporte_set_updated_at BEFORE UPDATE ON reporte
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER sensor_set_updated_at  BEFORE UPDATE ON sensor
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 9. RPCs (bbdd.md §5)
-- ----------------------------------------------------------------------------

-- 9.1 Búsqueda single (usada por GET /reportes/buscar-evidencia)
CREATE OR REPLACE FUNCTION public.validar_reporte_ruido(
  p_latitud         double precision,
  p_longitud        double precision,
  p_tiempo_reporte  timestamptz,
  p_radio_metros    int     DEFAULT 100,
  p_umbral_db       numeric DEFAULT 65,
  p_ventana_minutos int     DEFAULT 10
)
RETURNS TABLE (
  lectura_id         bigint,
  sensor_id          uuid,
  nivel_db           numeric,
  timestamp_medicion timestamptz,
  distancia_metros   double precision
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN QUERY
  SELECT
    l.id,
    l.sensor_id,
    l.nivel_db,
    l.timestamp_medicion,
    ST_Distance(
      s.ubicacion,
      ST_SetSRID(ST_MakePoint(p_longitud, p_latitud), 4326)::geography
    ) AS distancia_metros
  FROM lectura l
  JOIN sensor  s ON s.id = l.sensor_id
  WHERE s.activo = true
    AND ST_DWithin(
          s.ubicacion,
          ST_SetSRID(ST_MakePoint(p_longitud, p_latitud), 4326)::geography,
          p_radio_metros
        )
    AND l.timestamp_medicion >= p_tiempo_reporte - make_interval(mins => p_ventana_minutos)
    AND l.timestamp_medicion <= p_tiempo_reporte
    AND l.nivel_db >= p_umbral_db
  ORDER BY l.nivel_db DESC, l.timestamp_medicion DESC
  LIMIT 1;
END;
$$;

-- 9.2 Búsqueda top-N (anti-forgery dentro de crear_reporte_con_validacion)
CREATE OR REPLACE FUNCTION public.validar_reporte_ruido_top_n(
  p_latitud         double precision,
  p_longitud        double precision,
  p_tiempo_reporte  timestamptz,
  p_top_n           int     DEFAULT 5,
  p_radio_metros    int     DEFAULT 100,
  p_umbral_db       numeric DEFAULT 65,
  p_ventana_minutos int     DEFAULT 10
)
RETURNS TABLE (
  lectura_id         bigint,
  sensor_id          uuid,
  nivel_db           numeric,
  timestamp_medicion timestamptz,
  distancia_metros   double precision
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN QUERY
  SELECT
    l.id,
    l.sensor_id,
    l.nivel_db,
    l.timestamp_medicion,
    ST_Distance(
      s.ubicacion,
      ST_SetSRID(ST_MakePoint(p_longitud, p_latitud), 4326)::geography
    )
  FROM lectura l
  JOIN sensor  s ON s.id = l.sensor_id
  WHERE s.activo = true
    AND ST_DWithin(
          s.ubicacion,
          ST_SetSRID(ST_MakePoint(p_longitud, p_latitud), 4326)::geography,
          p_radio_metros
        )
    AND l.timestamp_medicion BETWEEN
          p_tiempo_reporte - make_interval(mins => p_ventana_minutos)
          AND p_tiempo_reporte
    AND l.nivel_db >= p_umbral_db
  ORDER BY l.nivel_db DESC, l.timestamp_medicion DESC
  LIMIT p_top_n;
END;
$$;

-- 9.3 RPC compuesta atómica (usada por POST /reportes)
CREATE OR REPLACE FUNCTION public.crear_reporte_con_validacion(
  p_usuario_id           uuid,
  p_comuna_id            int,
  p_titulo               text,
  p_descripcion          text,
  p_latitud              double precision,
  p_longitud             double precision,
  p_lectura_evidencia_id bigint DEFAULT NULL,
  p_radio_metros         int     DEFAULT 100,
  p_umbral_db            numeric DEFAULT 65,
  p_ventana_minutos      int     DEFAULT 10
)
RETURNS TABLE (
  reporte_id                  uuid,
  lectura_evidencia_id        bigint,
  lectura_evidencia_timestamp timestamptz
)
LANGUAGE plpgsql AS $$
DECLARE
  v_reporte_id   uuid;
  v_evidencia_id bigint;
  v_evidencia_ts timestamptz;
  v_now          timestamptz := now();
BEGIN
  -- 1. Insertar reporte (trigger set_initial_estado agrega "En espera")
  INSERT INTO reporte (usuario_id, comuna_id, titulo, descripcion, latitud, longitud)
  VALUES (p_usuario_id, p_comuna_id, p_titulo, p_descripcion, p_latitud, p_longitud)
  RETURNING id INTO v_reporte_id;

  -- 2. Si el cliente envió un id, verificarlo (anti-forgery + staleness).
  --    Capturamos también timestamp_medicion porque la FK a lectura es compuesta (D8).
  IF p_lectura_evidencia_id IS NOT NULL THEN
    SELECT lectura_id, timestamp_medicion
      INTO v_evidencia_id, v_evidencia_ts
    FROM public.validar_reporte_ruido_top_n(
           p_latitud, p_longitud, v_now,
           5, p_radio_metros, p_umbral_db, p_ventana_minutos
         )
    WHERE lectura_id = p_lectura_evidencia_id
    LIMIT 1;
  END IF;

  -- 3. Fallback: si no se validó el id del cliente, buscar automáticamente.
  IF v_evidencia_id IS NULL THEN
    SELECT lectura_id, timestamp_medicion
      INTO v_evidencia_id, v_evidencia_ts
    FROM public.validar_reporte_ruido(
           p_latitud, p_longitud, v_now,
           p_radio_metros, p_umbral_db, p_ventana_minutos
         )
    LIMIT 1;
  END IF;

  -- 4. Adjuntar evidencia si la hay (par id+timestamp; chk_evidencia_pair).
  IF v_evidencia_id IS NOT NULL THEN
    UPDATE reporte
       SET lectura_evidencia_id        = v_evidencia_id,
           lectura_evidencia_timestamp = v_evidencia_ts
     WHERE id = v_reporte_id;
  END IF;

  RETURN QUERY SELECT v_reporte_id, v_evidencia_id, v_evidencia_ts;
END;
$$;

-- 9.4 Agregación geo-temporal de lecturas (bbdd.md §5.4)
CREATE OR REPLACE FUNCTION public.heatmap_agregado(
  p_min_lng        double precision,
  p_min_lat        double precision,
  p_max_lng        double precision,
  p_max_lat        double precision,
  p_time_start     timestamptz,
  p_time_end       timestamptz,
  p_bucket_minutes int,
  p_grid_size_deg  double precision DEFAULT 0.001
)
RETURNS TABLE (
  lng_cell      double precision,
  lat_cell      double precision,
  bucket_start  timestamptz,
  nivel_db_avg  numeric,
  nivel_db_max  numeric,
  lectura_count bigint
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  -- Las columnas internas del CTE usan prefijo _ para no colisionar con las
  -- columnas del RETURNS TABLE (PL/pgSQL trata éstas como variables y
  -- entraría en ambigüedad en el GROUP BY).
  RETURN QUERY
  WITH celdas AS (
    SELECT
      (round((s.longitud / p_grid_size_deg)::numeric) * p_grid_size_deg)::double precision AS _lng_cell,
      (round((s.latitud  / p_grid_size_deg)::numeric) * p_grid_size_deg)::double precision AS _lat_cell,
      date_bin(
        make_interval(mins => p_bucket_minutes),
        l.timestamp_medicion,
        '2000-01-01'::timestamptz
      ) AS _bucket_start,
      l.nivel_db AS _nivel_db
    FROM lectura l
    JOIN sensor  s ON s.id = l.sensor_id
    WHERE l.timestamp_medicion >= p_time_start
      AND l.timestamp_medicion <  p_time_end
      AND s.longitud BETWEEN p_min_lng AND p_max_lng
      AND s.latitud  BETWEEN p_min_lat AND p_max_lat
  )
  SELECT
    celdas._lng_cell,
    celdas._lat_cell,
    celdas._bucket_start,
    ROUND(AVG(celdas._nivel_db)::numeric, 2),
    MAX(celdas._nivel_db),
    COUNT(*)
  FROM celdas
  GROUP BY celdas._lng_cell, celdas._lat_cell, celdas._bucket_start
  ORDER BY celdas._bucket_start, celdas._lat_cell, celdas._lng_cell;
END;
$$;

-- 9.5 Sensores con estado_salud derivado on-demand (bbdd.md §5.5 / D10)
-- Umbrales: online ≤1min, intermitente ≤5min, offline >5min o !activo,
-- sin_lecturas si MAX(timestamp_medicion) IS NULL.
CREATE OR REPLACE FUNCTION public.sensores_con_salud(
  p_comuna_id int DEFAULT NULL
)
RETURNS TABLE (
  id                uuid,
  nombre            text,
  comuna_id         int,
  latitud           numeric,
  longitud          numeric,
  activo            boolean,
  ultima_lectura_at timestamptz,
  ultima_lectura_db numeric,
  estado_salud      text,
  created_at        timestamptz
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN QUERY
  WITH ultimas AS (
    SELECT DISTINCT ON (l.sensor_id)
      l.sensor_id,
      l.timestamp_medicion AS ts,
      l.nivel_db
    FROM lectura l
    ORDER BY l.sensor_id, l.timestamp_medicion DESC
  )
  SELECT
    s.id,
    s.nombre,
    s.comuna_id,
    s.latitud,
    s.longitud,
    s.activo,
    u.ts,
    u.nivel_db,
    CASE
      WHEN NOT s.activo THEN 'offline'
      WHEN u.ts IS NULL THEN 'sin_lecturas'
      WHEN u.ts >= now() - interval '1 minute'  THEN 'online'
      WHEN u.ts >= now() - interval '5 minutes' THEN 'intermitente'
      ELSE 'offline'
    END::text AS estado_salud,
    s.created_at
  FROM sensor s
  LEFT JOIN ultimas u ON u.sensor_id = s.id
  WHERE (p_comuna_id IS NULL OR s.comuna_id = p_comuna_id)
  ORDER BY s.nombre;
END;
$$;

-- 9.6 KPIs de salud (bbdd.md §5.6)
CREATE OR REPLACE FUNCTION public.resumen_salud_sensores(
  p_comuna_id int DEFAULT NULL
)
RETURNS TABLE (
  total        int,
  online       int,
  intermitente int,
  offline      int,
  sin_lecturas int,
  calculado_at timestamptz
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN QUERY
  SELECT
    COUNT(*)::int                                                AS total,
    COUNT(*) FILTER (WHERE s.estado_salud = 'online')::int       AS online,
    COUNT(*) FILTER (WHERE s.estado_salud = 'intermitente')::int AS intermitente,
    COUNT(*) FILTER (WHERE s.estado_salud = 'offline')::int      AS offline,
    COUNT(*) FILTER (WHERE s.estado_salud = 'sin_lecturas')::int AS sin_lecturas,
    now()                                                        AS calculado_at
  FROM public.sensores_con_salud(p_comuna_id) s;
END;
$$;

-- ----------------------------------------------------------------------------
-- 10. Row Level Security (habilitado sin políticas — ver bbdd.md §6)
-- ----------------------------------------------------------------------------

ALTER TABLE comuna           ENABLE ROW LEVEL SECURITY;
ALTER TABLE tipo_estado      ENABLE ROW LEVEL SECURITY;
ALTER TABLE usuario          ENABLE ROW LEVEL SECURITY;
ALTER TABLE reporte          ENABLE ROW LEVEL SECURITY;
ALTER TABLE historial_estado ENABLE ROW LEVEL SECURITY;
ALTER TABLE sensor            ENABLE ROW LEVEL SECURITY;
ALTER TABLE lectura           ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- 11. Grants para service_role (bypass RLS por diseño — ver bbdd.md §6)
-- ----------------------------------------------------------------------------
-- En Supabase Cloud, los DEFAULT PRIVILEGES sobre el schema public suelen
-- otorgar acceso automáticamente a service_role, pero no siempre — depende
-- del rol que aplique la migración. Lo hacemos explícito para que un
-- `supabase db reset` o un push limpio deje el backend operativo sin pasos
-- manuales.

GRANT USAGE ON SCHEMA public TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO service_role;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT EXECUTE                        ON ALL FUNCTIONS IN SCHEMA public TO service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT                   ON SEQUENCES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE                         ON FUNCTIONS TO service_role;

-- ----------------------------------------------------------------------------
-- 12. Bootstrap del primer admin (manual, auth.md §8.1)
-- ----------------------------------------------------------------------------
-- Problema huevo-y-gallina: PATCH /usuarios/{id}/promover requiere ser admin.
-- El primer admin se promueve via SQL una sola vez, post-signup:
--
--   UPDATE public.usuario
--      SET tipo = 'admin'
--    WHERE id = '<uuid-del-primer-admin>';
--
-- Ese UUID se obtiene tras un signup normal en Supabase Auth. Documentar el
-- UUID resultante en el README del repo para futuros redeploys del entorno.
