-- ============================================================================
-- 40dB — Capa de agregación OLAP (rollups horarios + matview heatmap)
-- Spec: docs/bbdd.md §13 + docs/backend.md ADR 09 + docs/PLAN.md paso 14
--
-- Objetos creados:
--   * Tabla         lectura_resumen_horaria  (rollup horario por sensor)
--   * Función       refrescar_resumen_horario(p_desde timestamptz)
--   * Vista mat.    mv_heatmap_celda_bucket  (heatmap precomputado 5min/7d)
--   * Cron jobs     refrescar_resumen_horario_hourly   (cada hora minuto 5)
--                   refrescar_mv_heatmap               (cada 15 min)
--
-- Esta migración se aplica DESPUÉS de la inicial (lectura ya existe y, en
-- producción, debe tener al menos algunas horas de datos para que la matview
-- materialice algo útil — ver bbdd.md §13.3).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Extensión pg_cron
-- ----------------------------------------------------------------------------
-- pg_cron vive en la base `postgres` del cluster Supabase y se invoca desde
-- cualquier base con `SELECT cron.schedule(...)`. En el stack local de
-- Supabase la extensión viene preinstalada; en cloud hay que habilitarla
-- desde Dashboard → Database → Extensions una sola vez.

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ----------------------------------------------------------------------------
-- 2. Tabla lectura_resumen_horaria (rollup horario por sensor)
-- ----------------------------------------------------------------------------
-- Una fila por (sensor, hora). Refrescada incrementalmente vía la función de
-- §3 + pg_cron. Volumen: 30 sensores × 24h × 365d ≈ 263k rows/año (~20 MB).

CREATE TABLE lectura_resumen_horaria (
  sensor_id     uuid          NOT NULL REFERENCES sensor(id) ON DELETE CASCADE,
  hora          timestamptz   NOT NULL,
  avg_db        numeric(5, 2) NOT NULL,
  min_db        numeric(5, 2) NOT NULL,
  max_db        numeric(5, 2) NOT NULL,
  p95_db        numeric(5, 2) NOT NULL,
  n_lecturas    integer       NOT NULL CHECK (n_lecturas > 0),
  refrescado_at timestamptz   NOT NULL DEFAULT now(),
  PRIMARY KEY (sensor_id, hora)
);

CREATE INDEX idx_resumen_horaria_hora
  ON lectura_resumen_horaria (hora DESC);
CREATE INDEX idx_resumen_horaria_sensor_hora
  ON lectura_resumen_horaria (sensor_id, hora DESC);

ALTER TABLE lectura_resumen_horaria ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- 3. Función refrescar_resumen_horario (idempotente, upsert)
-- ----------------------------------------------------------------------------
-- Por defecto refresca desde `now() - 2h` truncado a hora — cubre la hora en
-- curso, la anterior y absorbe lecturas QoS 1 atrasadas.
-- Backfill manual:
--   SELECT refrescar_resumen_horario('2026-05-01'::timestamptz);

CREATE OR REPLACE FUNCTION public.refrescar_resumen_horario(
  p_desde timestamptz DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_desde timestamptz := COALESCE(
    p_desde,
    date_trunc('hour', now()) - interval '2 hours'
  );
  v_filas integer;
BEGIN
  INSERT INTO lectura_resumen_horaria
    (sensor_id, hora, avg_db, min_db, max_db, p95_db, n_lecturas, refrescado_at)
  SELECT
    l.sensor_id,
    date_bin(interval '1 hour', l.timestamp_medicion, '2000-01-01'::timestamptz) AS hora,
    ROUND(AVG(l.nivel_db)::numeric, 2),
    MIN(l.nivel_db),
    MAX(l.nivel_db),
    ROUND(percentile_cont(0.95) WITHIN GROUP (ORDER BY l.nivel_db)::numeric, 2),
    COUNT(*),
    now()
  FROM lectura l
  WHERE l.timestamp_medicion >= v_desde
  GROUP BY l.sensor_id,
           date_bin(interval '1 hour', l.timestamp_medicion, '2000-01-01'::timestamptz)
  ON CONFLICT (sensor_id, hora) DO UPDATE SET
    avg_db        = EXCLUDED.avg_db,
    min_db        = EXCLUDED.min_db,
    max_db        = EXCLUDED.max_db,
    p95_db        = EXCLUDED.p95_db,
    n_lecturas    = EXCLUDED.n_lecturas,
    refrescado_at = EXCLUDED.refrescado_at;

  GET DIAGNOSTICS v_filas = ROW_COUNT;
  RETURN v_filas;
END;
$$;

-- ----------------------------------------------------------------------------
-- 4. Vista materializada mv_heatmap_celda_bucket
-- ----------------------------------------------------------------------------
-- Precomputa el heatmap para la combinación más común que pedirá el frontend:
-- bucket_minutes=5 sobre los últimos 7 días. Para ventanas o buckets distintos
-- el endpoint /heatmaps sigue cayendo al RPC heatmap_agregado() existente.
--
-- Limitación honesta: la cláusula WHERE timestamp_medicion >= now() - 7d se
-- congela al CREATE — Postgres no re-evalúa now() en cada REFRESH. Mantenemos
-- la matview "corriéndose hacia adelante": acumula rows viejos pero no pierde
-- ninguno reciente. Si la huella crece molesto (volumen MVP no lo justifica),
-- DROP + CREATE periódico (cada N días) en mantenimiento.

CREATE MATERIALIZED VIEW mv_heatmap_celda_bucket AS
SELECT
  (round((s.longitud / 0.001)::numeric) * 0.001)::double precision AS lng_cell,
  (round((s.latitud  / 0.001)::numeric) * 0.001)::double precision AS lat_cell,
  date_bin(interval '5 minutes', l.timestamp_medicion, '2000-01-01'::timestamptz) AS bucket_start,
  ROUND(AVG(l.nivel_db)::numeric, 2) AS nivel_db_avg,
  MAX(l.nivel_db)                    AS nivel_db_max,
  COUNT(*)                           AS lectura_count
FROM lectura l
JOIN sensor  s ON s.id = l.sensor_id
WHERE l.timestamp_medicion >= now() - interval '7 days'
GROUP BY 1, 2, 3;

-- UNIQUE obligatorio para REFRESH MATERIALIZED VIEW CONCURRENTLY
CREATE UNIQUE INDEX idx_mv_heatmap_unique
  ON mv_heatmap_celda_bucket (lng_cell, lat_cell, bucket_start);

-- Filtro temporal del endpoint (siempre acota bucket_start)
CREATE INDEX idx_mv_heatmap_bucket
  ON mv_heatmap_celda_bucket (bucket_start DESC);

-- ----------------------------------------------------------------------------
-- 5. Schedule con pg_cron
-- ----------------------------------------------------------------------------
-- Los jobs se identifican por nombre. Para que `supabase db reset` sea
-- idempotente, desprogramamos primero si ya existen.

DO $$
DECLARE
  v_job_id bigint;
BEGIN
  -- Rollup horario: minuto 5 de cada hora (margen para lecturas tardías)
  FOR v_job_id IN
    SELECT jobid FROM cron.job WHERE jobname = 'refrescar_resumen_horario_hourly'
  LOOP
    PERFORM cron.unschedule(v_job_id);
  END LOOP;

  PERFORM cron.schedule(
    'refrescar_resumen_horario_hourly',
    '5 * * * *',
    $cron$SELECT public.refrescar_resumen_horario();$cron$
  );

  -- Matview heatmap: cada 15 minutos
  FOR v_job_id IN
    SELECT jobid FROM cron.job WHERE jobname = 'refrescar_mv_heatmap'
  LOOP
    PERFORM cron.unschedule(v_job_id);
  END LOOP;

  PERFORM cron.schedule(
    'refrescar_mv_heatmap',
    '*/15 * * * *',
    $cron$REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_heatmap_celda_bucket;$cron$
  );
END;
$$;

-- ----------------------------------------------------------------------------
-- 6. Grants para service_role (el backend lee desde acá)
-- ----------------------------------------------------------------------------
-- Las ALTER DEFAULT PRIVILEGES de la migración inicial cubren tablas creadas
-- después, pero las matviews y funciones merecen un grant explícito para
-- evitar sorpresas si los defaults se desconfiguran.

GRANT SELECT ON lectura_resumen_horaria   TO service_role;
GRANT SELECT ON mv_heatmap_celda_bucket   TO service_role;
GRANT EXECUTE ON FUNCTION public.refrescar_resumen_horario(timestamptz) TO service_role;
