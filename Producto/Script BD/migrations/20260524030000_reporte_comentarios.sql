-- ============================================================================
-- 40dB — Comentarios sobre reporte (internos para funcionarios, externos para
--         el vecino autor).
-- Spec: docs/bbdd.md §3.8 + docs/api.md §4.10/§4.11
--
-- Decisiones:
--   * Tabla NUEVA `reporte_comentario` (no se mezcla con `historial_estado`):
--     historial_estado modela transiciones de estado (tipo_estado_id NOT NULL)
--     y el trigger set_initial_estado garantiza "todo reporte tiene al menos
--     un estado". Mezclar comentarios obligaría a relajar esa invariante.
--   * `visibilidad` discrimina interno (solo funcionarios) vs externo
--     (visible para el ciudadano dueño del reporte).
--   * Delegación se modela como columnas dedicadas (delegado_a_id +
--     delegado_at), no como jsonb, para conservar FK sobre el funcionario.
--     El CHECK garantiza coherencia: si hay delegación, visibilidad debe ser
--     'interno' y ambas columnas vienen juntas.
--   * RLS habilitado sin policies (mismo invariante que el resto: el backend
--     con service_role es el único cliente — CLAUDE.md §invariantes).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Tabla
-- ----------------------------------------------------------------------------

CREATE TABLE reporte_comentario (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reporte_id     uuid    NOT NULL REFERENCES reporte(id) ON DELETE CASCADE,
  autor_id       uuid    NOT NULL REFERENCES usuario(id),
  visibilidad    text    NOT NULL
                 CHECK (visibilidad IN ('interno', 'externo')),
  cuerpo         text    NOT NULL CHECK (length(btrim(cuerpo)) > 0),
  -- Delegación estructurada (solo comentarios internos pueden delegar).
  delegado_a_id  uuid    REFERENCES usuario(id),
  delegado_at    timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_delegacion_pair CHECK (
    (delegado_a_id IS NULL AND delegado_at IS NULL)
    OR (
      visibilidad = 'interno'
      AND delegado_a_id IS NOT NULL
      AND delegado_at IS NOT NULL
    )
  )
);

-- ----------------------------------------------------------------------------
-- 2. Índices
-- ----------------------------------------------------------------------------

-- Timeline de un reporte: GET /reportes/{id}/comentarios ordena por created_at.
CREATE INDEX idx_reporte_comentario_reporte_created
  ON reporte_comentario(reporte_id, created_at DESC);

-- "Reportes delegados a mí" (futuro). Parcial — solo filas con delegación.
CREATE INDEX idx_reporte_comentario_delegado
  ON reporte_comentario(delegado_a_id, delegado_at DESC)
  WHERE delegado_a_id IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 3. RLS (sin policies — mismo patrón que el resto del esquema)
-- ----------------------------------------------------------------------------

ALTER TABLE reporte_comentario ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- 4. Grants
-- ----------------------------------------------------------------------------
-- Cubierto por los grants globales del initial schema (§11) y ALTER DEFAULT
-- PRIVILEGES, pero se repiten por simetría con migraciones siguientes.

GRANT SELECT, INSERT, UPDATE, DELETE ON reporte_comentario TO service_role;
