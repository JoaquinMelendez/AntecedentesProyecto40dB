-- ============================================================================
-- 40dB — Archivos generados desde el panel admin (PDF / CSV / imagen)
-- Cubre: docs/integracion-backend §8 (vista /admin-dashboard/reportes).
--
-- Decisiones:
--   * Bucket privado. El backend (service_role) es el único cliente —
--     mismo invariante que el resto de tablas (CLAUDE.md §invariantes).
--   * Sin policies sobre storage.objects: el frontend no instancia el
--     cliente JS de Supabase contra Storage. Todo pasa por la API.
--   * Tabla 1:1 con cada objeto en el bucket. El object_path es la única
--     fuente de verdad para reconstruir el download desde el backend.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Bucket privado en Supabase Storage
-- ----------------------------------------------------------------------------

INSERT INTO storage.buckets (id, name, public)
VALUES ('reportes-admin', 'reportes-admin', false)
ON CONFLICT (id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 2. Tabla de metadatos
-- ----------------------------------------------------------------------------

CREATE TABLE reporte_archivo_admin (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  generado_por_id  uuid NOT NULL REFERENCES usuario(id),
  nombre           text NOT NULL,                  -- nombre legible para el usuario
  tipo             text NOT NULL                   -- discriminator de presentación
                   CHECK (tipo IN ('pdf', 'csv', 'imagen')),
  mime_type        text NOT NULL,                  -- 'application/pdf', 'text/csv', 'image/png', ...
  tamano_bytes     bigint NOT NULL CHECK (tamano_bytes >= 0),
  object_path      text NOT NULL UNIQUE,           -- key dentro del bucket 'reportes-admin'
  rango_desde      timestamptz,                    -- opcional: período cubierto por el reporte
  rango_hasta      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_rango_orden CHECK (
    rango_desde IS NULL OR rango_hasta IS NULL OR rango_desde <= rango_hasta
  )
);

CREATE INDEX idx_reporte_archivo_admin_created
  ON reporte_archivo_admin(created_at DESC, id DESC);
CREATE INDEX idx_reporte_archivo_admin_generado_por
  ON reporte_archivo_admin(generado_por_id);
CREATE INDEX idx_reporte_archivo_admin_tipo
  ON reporte_archivo_admin(tipo);

-- ----------------------------------------------------------------------------
-- 3. RLS habilitado sin policies (mismo patrón que el resto del esquema)
-- ----------------------------------------------------------------------------

ALTER TABLE reporte_archivo_admin ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- 4. Grants explícitos para service_role
-- ----------------------------------------------------------------------------
-- Cubierto por los grants globales del initial schema (§11), pero los
-- repetimos por simetría con el bucket.

GRANT SELECT, INSERT, UPDATE, DELETE ON reporte_archivo_admin TO service_role;
