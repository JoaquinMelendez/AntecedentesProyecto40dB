# Base de Datos — 40dB

Este documento define el **modelo de datos canónico** del backend 40dB: DDL, índices, triggers, función de validación (RPC), estrategia de RLS y máquina de estados del reporte. Es la referencia que `supabase/migrations/*` debe reflejar.

> **Nota:** este doc reemplaza cualquier suposición previa de modelo de datos en `backend.md`. Si difieren, manda este.

---

## 1. Decisiones de diseño

| # | Decisión | Justificación |
|---|---|---|
| D1 | **PostGIS habilitado** con columna `ubicacion geography(Point, 4326)` generada desde `latitud`/`longitud` | Query crítico (validación geo-temporal) usa `ST_DWithin` con índice GIST — orden de magnitud más rápido que haversine en SQL y estándar en Supabase. |
| D2 | **Validación IoT 1:1** para prototipo: `reporte.lectura_evidencia_id` apunta a una `lectura` única | El prototipo tendrá un solo micrófono. N:M con `score` queda como **roadmap** (sección 10) cuando se sumen sensores y validaciones manuales. |
| D3 | **Estado del reporte como historial append-only** (`historial_estado`) | Auditoría completa: quién cambió a qué, cuándo y por qué. Estado actual = último row por `reporte_id` (índice compuesto lo hace barato). |
| D4 | **RLS habilitada sin políticas** | Todo el tráfico pasa por FastAPI con `service_role_key`. El frontend **nunca** habla con Supabase directo. Bypass por diseño, no por descuido. |
| D5 | **lat/lng numéricos se mantienen** como columnas fuente; `ubicacion` es `GENERATED STORED` | Source of truth humano-legible. La columna PostGIS se deriva, no se duplica manualmente. |
| D6 | **FK compuesta a `lectura` (no a `sensor`) para evidencia** | `reporte` referencia `(lectura_evidencia_id, lectura_evidencia_timestamp)` contra `(lectura.id, lectura.timestamp_medicion)`. La denormalización del timestamp es **obligatoria** porque `lectura` es particionada (D8) — Postgres exige que toda UNIQUE/PK incluya la partition key, y una FK solo puede apuntar a esa UNIQUE/PK. Navegamos sensor + dB por JOIN sin desnormalizar más. |
| D7 | **Catálogos pequeños como tablas, no enums** | `comuna`, `tipo_estado`. Permite agregar valores sin migración y referenciarlos por FK. |
| D8 | **`lectura` particionada por mes desde el inicio (`PARTITION BY RANGE (timestamp_medicion)`)** | Diseñada para escalar a ~30 sensores publicando cada 5–10s. Supabase **no soporta TimescaleDB**, así que se usa partición nativa de Postgres. Particionar desde el día 1 evita una migración dolorosa después (cambiar a partitioned table requiere recrear toda la tabla y FKs). La cadencia mensual cubre ~8–16M rows/partición con el volumen objetivo, manejable por btree/GIST sin presión. |
| D9 | **Tres roles en `usuario.tipo`: `ciudadano`, `municipalidad`, `admin`** | El admin es cross-comuna y opera CRUD de sensores + gestiona usuarios (promociones, activación). Mantenerlo dentro de `usuario.tipo` como tercer valor del CHECK evita una tabla `rol` separada (overkill para 3 valores discretos sin metadata extra). La promoción a `municipalidad` o `admin` ahora es vía endpoint (`PATCH /usuarios/{id}/promover`) protegido por rol admin — la SQL manual queda solo como bootstrap del primer admin. Ver `auth.md` §8 actualizada. |
| D10 | **`sensor.estado_salud` se computa on-demand**, no se persiste | Vista de salud (`online` / `intermitente` / `offline`) se deriva en cada `GET /sensores` desde `MAX(timestamp_medicion)` por sensor. El índice `idx_lectura_sensor_timestamp` ya existe → query <5ms con volumen MVP. Cero estado mutable, sin worker, sin drift. Umbrales en §5.5 (`estado_salud_sensor`). Si crece a >100 sensores y se vuelve hotspot, evaluar vista materializada (no en MVP). |

---

## 2. Diagrama lógico (ERD textual)

```
auth.users (Supabase)
   ▲ 1:1
   │
usuario ─── pertenece a ──▶ comuna
   │                          ▲
   │ 1:N                      │ 1:N
   ▼                          │
reporte ─── ubicado en ───────┘
   │  ▲ (atendido_por_id, opcional)
   │  └─── usuario (tipo='municipalidad')
   │
   │ 1:N                              evidencia (1:1)
   ▼                                       │
historial_estado ──▶ tipo_estado           ▼
   ▲                                    lectura ──▶ sensor ──▶ comuna
   │ FK usuario_id (quién hizo el cambio)
```

**Cardinalidades clave:**
- `usuario` 1—N `reporte` (autor) y opcional 1—N `reporte` (atendido_por).
- `reporte` 1—N `historial_estado`; estado actual = `MAX(created_at)`.
- `sensor` 1—N `lectura`.
- `reporte` 0..1—1 `lectura` vía `lectura_evidencia_id` (validación 1:1 del prototipo).

---

## 3. DDL canónico

> El SQL real vive en `supabase/migrations/*`. Esta sección documenta el **estado objetivo**. Cuando se ratifique este doc, se actualizará la migración o se creará una nueva.

### 3.1 Extensiones

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
-- pgcrypto es parte de Supabase por default (provee gen_random_uuid)
```

### 3.2 Catálogos

```sql
CREATE TABLE comuna (
  id      int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre  text NOT NULL UNIQUE,
  region  text,
  codigo  text UNIQUE
);

CREATE TABLE tipo_estado (
  id          int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre      text NOT NULL UNIQUE,
  descripcion text,
  orden       int NOT NULL DEFAULT 0
);
```

### 3.3 Usuario (perfil sobre `auth.users`)

```sql
CREATE TABLE usuario (
  id          uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  nombre      text NOT NULL,
  telefono    text,
  tipo        text NOT NULL DEFAULT 'ciudadano'
              CHECK (tipo IN ('ciudadano', 'municipalidad', 'admin')),
  comuna_id   int REFERENCES comuna(id),
  activo      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_usuario_tipo ON usuario(tipo);
```

El detalle de auth (trigger `handle_new_user`, OAuth, JWT) está en `auth.md`.

### 3.4 Sensor

```sql
CREATE TABLE sensor (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  comuna_id   int NOT NULL REFERENCES comuna(id),
  nombre      text NOT NULL UNIQUE,
  latitud     numeric(10, 8) NOT NULL,
  longitud    numeric(11, 8) NOT NULL,
  ubicacion   geography(Point, 4326)
              GENERATED ALWAYS AS (
                ST_SetSRID(ST_MakePoint(longitud, latitud), 4326)::geography
              ) STORED,
  activo      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_sensor_comuna    ON sensor(comuna_id);
CREATE INDEX idx_sensor_ubicacion ON sensor USING GIST (ubicacion);
```

### 3.5 Lectura (telemetría IoT, particionada)

Tabla diseñada para alto volumen (ver D8). `PARTITION BY RANGE (timestamp_medicion)` con particiones mensuales. La PK y la UNIQUE incluyen `timestamp_medicion` porque Postgres exige que toda constraint de unicidad contenga la partition key.

```sql
CREATE TABLE lectura (
  id                  bigint GENERATED ALWAYS AS IDENTITY,
  sensor_id           uuid NOT NULL REFERENCES sensor(id) ON DELETE CASCADE,
  nivel_db            numeric(5, 2) NOT NULL,
  timestamp_medicion  timestamptz NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  -- PK compuesta: la partition key (timestamp_medicion) debe estar incluida
  PRIMARY KEY (id, timestamp_medicion),
  -- Idempotencia ante QoS 1 / reintentos del sensor (ver iot.md §6.3).
  -- Ya incluye la partition key, así que es válida globalmente.
  CONSTRAINT uq_lectura_sensor_timestamp UNIQUE (sensor_id, timestamp_medicion)
) PARTITION BY RANGE (timestamp_medicion);

-- Índices declarados a nivel parent: Postgres los propaga a cada partición.
CREATE INDEX idx_lectura_timestamp        ON lectura(timestamp_medicion);
CREATE INDEX idx_lectura_sensor_timestamp ON lectura(sensor_id, timestamp_medicion);
```

#### 3.5.1 Particiones iniciales

La migración crea **8 particiones mensuales** (mayo–diciembre 2026) más una **partición default** como red de seguridad para timestamps fuera de rango. Esto cubre el horizonte del MVP sin necesitar automatización aún.

```sql
CREATE TABLE lectura_2026_05 PARTITION OF lectura
  FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE lectura_2026_06 PARTITION OF lectura
  FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
-- … (07, 08, 09, 10, 11, 12)
CREATE TABLE lectura_2026_12 PARTITION OF lectura
  FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');
CREATE TABLE lectura_default PARTITION OF lectura DEFAULT;
```

**Sobre la partición `DEFAULT`.** Atrapa cualquier `INSERT` con timestamp fuera de los rangos declarados (ej. skew de reloj severo, lecturas antiguas reenviadas, o un mes sin crear). Es una **red de seguridad explícita**, no un mecanismo de producción: cuando se acerca el fin del año, hay que crear las particiones del año siguiente **antes** de que la default empiece a recibir tráfico, porque el planner penaliza con DEFAULT pobladas (no puede prunear).

#### 3.5.2 Mantenimiento de particiones

**MVP (manual + cron simple):**
- Pre-crear 3 meses de futuro al inicio.
- Una tarea trimestral (revisión humana, o `pg_cron` con script SQL) crea las siguientes 3 particiones.
- Drop manual de particiones antiguas si se decide retención (no antes de tener política de retención definida — por ahora retenemos todo).

**Roadmap:** `pg_partman` para automatizar creación + drop con política declarativa. Supabase soporta `pg_partman` desde plan Pro. Ver §10.3 para detalle del trigger de migración.

### 3.6 Reporte

```sql
CREATE TABLE reporte (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id            uuid NOT NULL REFERENCES usuario(id),
  atendido_por_id       uuid REFERENCES usuario(id),
  comuna_id             int  NOT NULL REFERENCES comuna(id),
  titulo                text NOT NULL,
  descripcion           text NOT NULL,
  latitud               numeric(10, 8) NOT NULL,
  longitud              numeric(11, 8) NOT NULL,
  ubicacion             geography(Point, 4326)
                        GENERATED ALWAYS AS (
                          ST_SetSRID(ST_MakePoint(longitud, latitud), 4326)::geography
                        ) STORED,
  -- Evidencia IoT (prototipo 1:1, ver roadmap para N:M).
  -- FK compuesta porque `lectura` es particionada: la PK incluye timestamp_medicion (D8).
  -- Ambas columnas se setean juntas o ambas son NULL (chk_evidencia_pair).
  lectura_evidencia_id          bigint,
  lectura_evidencia_timestamp   timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
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
-- Para acelerar el lookup de FK (ON DELETE SET NULL escanea esta combinación)
CREATE INDEX idx_reporte_evidencia    ON reporte(lectura_evidencia_id, lectura_evidencia_timestamp)
  WHERE lectura_evidencia_id IS NOT NULL;
```

### 3.7 Historial de estados

```sql
CREATE TABLE historial_estado (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reporte_id      uuid NOT NULL REFERENCES reporte(id) ON DELETE CASCADE,
  tipo_estado_id  int  NOT NULL REFERENCES tipo_estado(id),
  usuario_id      uuid REFERENCES usuario(id),     -- quién hizo el cambio
  comentario      text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- CRÍTICO: obtener "último estado por reporte" es O(log n) con este índice
CREATE INDEX idx_historial_reporte_created
  ON historial_estado(reporte_id, created_at DESC);
```

### 3.8 Comentarios del reporte

Mensajes adjuntos al reporte, separados del historial de estados. Sirven para dos audiencias distintas:

- **Internos** (`visibilidad = 'interno'`): solo funcionarios `municipalidad` (de la comuna del reporte) y `admin` los ven. Pueden incluir una **delegación estructurada** (campos `delegado_a_id` + `delegado_at`) — el frontend renderiza "Delegado a: X a las HH:MM" sin parsear texto libre.
- **Externos** (`visibilidad = 'externo'`): el vecino dueño del reporte los ve también. Texto libre tipo "Esto fue derivado a una patrulla municipal, ya van en camino."

Por qué tabla nueva en vez de extender `historial_estado`:

- `historial_estado.tipo_estado_id` es `NOT NULL` y el trigger `set_initial_estado` garantiza que **todo reporte tiene al menos un estado**. Permitir comentarios sin transición de estado requeriría relajar ambos.
- Semánticamente son cosas distintas: `historial_estado` es "quién cambió a qué estado y cuándo", `reporte_comentario` es "quién dejó un mensaje, para quién". El timeline combinado (si el frontend lo quiere) se obtiene con `UNION` en lectura.

```sql
CREATE TABLE reporte_comentario (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reporte_id     uuid    NOT NULL REFERENCES reporte(id) ON DELETE CASCADE,
  autor_id       uuid    NOT NULL REFERENCES usuario(id),
  visibilidad    text    NOT NULL
                 CHECK (visibilidad IN ('interno', 'externo')),
  cuerpo         text    NOT NULL CHECK (length(btrim(cuerpo)) > 0),
  -- Delegación estructurada. Solo aplica a internos.
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

CREATE INDEX idx_reporte_comentario_reporte_created
  ON reporte_comentario(reporte_id, created_at DESC);
-- "Reportes delegados a mí" (futuro). Parcial: solo filas con delegación.
CREATE INDEX idx_reporte_comentario_delegado
  ON reporte_comentario(delegado_a_id, delegado_at DESC)
  WHERE delegado_a_id IS NOT NULL;
```

**Autorización (resumida — el contrato vive en `api.md` §4.28/§4.29):**

| Rol | Escribir interno | Escribir externo | Leer interno | Leer externo |
|---|---|---|---|---|
| ciudadano (dueño del reporte) | ❌ | ❌ | ❌ | ✅ |
| municipalidad (de la comuna) | ✅ | ✅ | ✅ | ✅ |
| admin | ✅ | ✅ | ✅ | ✅ |
| cualquier otro | ❌ | ❌ | ❌ | ❌ |

`delegado_a_id` referencia `usuario(id)` sin filtro de `tipo` a nivel DB; el use case valida que sea un usuario con `tipo='municipalidad'` antes de insertar.

---

## 4. Triggers

### 4.1 `handle_new_user` — auto-provisioning de perfil
Cuando llega un `INSERT` a `auth.users` (login Google/email), crea automáticamente el row en `usuario`. Detalle completo en `auth.md`.

### 4.2 `set_initial_estado` — estado inicial automático
Cuando se inserta un `reporte`, mete "En espera" en `historial_estado` sin que el código Python tenga que recordarlo. Garantiza invariante: **todo reporte tiene al menos un estado**.

```sql
CREATE OR REPLACE FUNCTION public.set_initial_estado()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_estado_id int;
BEGIN
  SELECT id INTO v_estado_id FROM public.tipo_estado WHERE nombre = 'En espera' LIMIT 1;
  IF v_estado_id IS NULL THEN
    RAISE EXCEPTION 'tipo_estado "En espera" no existe en el catalogo';
  END IF;
  INSERT INTO public.historial_estado (reporte_id, tipo_estado_id, usuario_id)
  VALUES (NEW.id, v_estado_id, NEW.usuario_id);
  RETURN NEW;
END; $$;

CREATE TRIGGER on_reporte_created
AFTER INSERT ON public.reporte
FOR EACH ROW EXECUTE FUNCTION public.set_initial_estado();
```

### 4.3 `set_updated_at` — mantenimiento de `updated_at`
Aplicado a `usuario`, `reporte`, `sensor`. Evita olvidos en UPDATEs manuales.

---

## 5. RPCs (funciones Postgres)

Seis funciones PL/pgSQL viven en la DB. Todas se invocan desde Python con `supabase_client.rpc(<nombre>, params)`:

| Función | Para qué | Llamada desde |
|---|---|---|
| `validar_reporte_ruido` | Single-match para preview | `GET /reportes/buscar-evidencia` |
| `validar_reporte_ruido_top_n` | Top-N para anti-forgery | (interno, dentro de §5.3) |
| `crear_reporte_con_validacion` | Insert + validación atómica | `POST /reportes` |
| `heatmap_agregado` | Agregación por celda + bucket | `GET /heatmaps` |
| `sensores_con_salud` | Lista sensores con `estado_salud` derivado on-demand | `GET /sensores`, `GET /sensores/{id}` |
| `resumen_salud_sensores` | KPIs agregados (online/intermitente/offline/sin_lecturas) | `GET /sensores/resumen` |

Las tres primeras encapsulan **reglas de negocio** (criterios geo-temporales, transiciones del modelo, atomicidad). La cuarta es **agregación pura** sobre `lectura`, vive como función Postgres porque `supabase-py` no expone SQL raw parametrizado. Las dos últimas (D10) computan el estado de salud del sensor on-demand desde `MAX(timestamp_medicion)` por sensor — no encapsulan reglas, solo aprovechan el índice `idx_lectura_sensor_timestamp` para responder rápido sin estado persistido.

### 5.1 `validar_reporte_ruido` (single, para preview)

**Parámetros de diseño** (configurables vía signature):
- Radio: 100 m (default)
- Ventana retrospectiva: 10 minutos
- Umbral mínimo: 65 dB

```sql
CREATE OR REPLACE FUNCTION public.validar_reporte_ruido(
  p_latitud         double precision,
  p_longitud        double precision,
  p_tiempo_reporte  timestamptz,
  p_radio_metros    int     DEFAULT 100,
  p_umbral_db       numeric DEFAULT 65,
  p_ventana_minutos int     DEFAULT 10
)
RETURNS TABLE (
  lectura_id          bigint,
  sensor_id           uuid,
  nivel_db            numeric,
  timestamp_medicion  timestamptz,
  distancia_metros    double precision
)
LANGUAGE plpgsql
STABLE
AS $$
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
  JOIN sensor s ON s.id = l.sensor_id
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
END; $$;
```

**Uso:** la invoca `GET /reportes/buscar-evidencia` (preview iniciado por el usuario). No escribe nada. Para el insert se usa la compuesta (§5.3).

### 5.2 `validar_reporte_ruido_top_n` (top-N, para anti-forgery)

Variante que retorna las top-N lecturas que cumplen los criterios (no solo la mejor). Se usa dentro de `crear_reporte_con_validacion` para confirmar que el `lectura_evidencia_id` enviado por el cliente pertenece al set legítimo de candidatos.

```sql
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
  lectura_id          bigint,
  sensor_id           uuid,
  nivel_db            numeric,
  timestamp_medicion  timestamptz,
  distancia_metros    double precision
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN QUERY
  SELECT l.id, l.sensor_id, l.nivel_db, l.timestamp_medicion,
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
          p_radio_metros)
    AND l.timestamp_medicion BETWEEN p_tiempo_reporte - make_interval(mins => p_ventana_minutos)
                                 AND p_tiempo_reporte
    AND l.nivel_db >= p_umbral_db
  ORDER BY l.nivel_db DESC, l.timestamp_medicion DESC
  LIMIT p_top_n;
END; $$;
```

### 5.3 `crear_reporte_con_validacion` (compuesta, atómica — usada por POST)

Envuelve insert + validación + fallback en una sola transacción. Lo invoca el backend en `POST /reportes`. Si algo falla, la transacción se revierte completa (incluyendo el `historial_estado` que insertó el trigger).

```sql
CREATE OR REPLACE FUNCTION public.crear_reporte_con_validacion(
  p_usuario_id            uuid,
  p_comuna_id             int,
  p_titulo                text,
  p_descripcion           text,
  p_latitud               double precision,
  p_longitud              double precision,
  p_lectura_evidencia_id  bigint DEFAULT NULL
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
  -- 1. Insertar el reporte (trigger set_initial_estado agrega "En espera")
  INSERT INTO reporte (usuario_id, comuna_id, titulo, descripcion, latitud, longitud)
  VALUES (p_usuario_id, p_comuna_id, p_titulo, p_descripcion, p_latitud, p_longitud)
  RETURNING id INTO v_reporte_id;

  -- 2. Si el cliente envió un id, verificarlo (anti-forgery + staleness).
  --    Capturamos también el timestamp_medicion porque la FK a lectura es compuesta (D8).
  IF p_lectura_evidencia_id IS NOT NULL THEN
    SELECT lectura_id, timestamp_medicion
      INTO v_evidencia_id, v_evidencia_ts
    FROM validar_reporte_ruido_top_n(p_latitud, p_longitud, v_now, 5)
    WHERE lectura_id = p_lectura_evidencia_id
    LIMIT 1;
  END IF;

  -- 3. Si no se adjuntó nada en el paso 2, intentar fallback automático.
  IF v_evidencia_id IS NULL THEN
    SELECT lectura_id, timestamp_medicion
      INTO v_evidencia_id, v_evidencia_ts
    FROM validar_reporte_ruido(p_latitud, p_longitud, v_now)
    LIMIT 1;
  END IF;

  -- 4. Adjuntar la evidencia (si la hay). Las dos columnas van juntas (chk_evidencia_pair).
  IF v_evidencia_id IS NOT NULL THEN
    UPDATE reporte
       SET lectura_evidencia_id        = v_evidencia_id,
           lectura_evidencia_timestamp = v_evidencia_ts
     WHERE id = v_reporte_id;
  END IF;

  RETURN QUERY SELECT v_reporte_id, v_evidencia_id, v_evidencia_ts;
END; $$;
```

**Por qué RPC compuesta y no transacción desde Python.** Un solo roundtrip a Postgres, atomicidad implícita garantizada por la DB, lógica de fallback testeable como unidad en SQL (con `pgTAP` o tests de integración), y el backend Python queda como orquestador delgado que solo mapea el resultado. Decisión cerrada (antes era "pendiente de discusión").

### 5.4 `heatmap_agregado` (agregación geo-temporal)

Función Postgres que agrega `lectura` por celda + bucket temporal. La invoca `LecturaRepository.heatmap(...)` via `rpc()`. A diferencia de §5.1–§5.3, **no encapsula reglas de negocio** — es agregación pura. Vive como función Postgres porque `supabase-py` no expone SQL raw parametrizado.

```sql
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
```

**Notas:**
- Usa `date_bin` (Postgres 14+) para alinear buckets a un origen fijo (`2000-01-01`), garantizando que dos requests con misma ventana produzcan los mismos buckets.
- El filtro por bbox usa `sensor.latitud/longitud` numéricos, no PostGIS — más simple y barato para un bounding box rectangular. PostGIS se usa solo en §5.1–§5.2 (radio geodésico).
- El `0.001°` (~100 m al ecuador, menos a latitudes altas) viene de `settings.HEATMAP_GRID_SIZE_DEG`.
- La validación de límites (`bucket_minutes ∈ {1,5,15,60}`, ventana ≤ 7 días, bbox válido) vive en el use case Python (`app/application/obtener_heatmap.py`), no en SQL — son reglas de **dominio del endpoint**, no de la agregación.

### 5.5 `estado_salud_sensor` (cálculo on-demand por sensor)

Función Postgres que computa el estado de salud de cada sensor en base a la última lectura recibida (D10). La invoca `SensorRepository.listar(...)` con o sin filtro de comuna; también es la base de `resumen_salud_sensores` (§5.6).

**Umbrales** (fijos en el RPC; si en el futuro se quieren configurables, mover a parámetros):

| Estado | Definición |
|---|---|
| `online` | última lectura ≤ 1 min |
| `intermitente` | 1 min < última lectura ≤ 5 min |
| `offline` | > 5 min sin lectura, **o** `sensor.activo = false` |
| `sin_lecturas` | sensor sin ninguna lectura en `lectura` (recién provisionado) |

```sql
CREATE OR REPLACE FUNCTION public.sensores_con_salud(
  p_comuna_id int DEFAULT NULL
)
RETURNS TABLE (
  id                 uuid,
  nombre             text,
  comuna_id          int,
  latitud            numeric,
  longitud           numeric,
  activo             boolean,
  ultima_lectura_at  timestamptz,
  ultima_lectura_db  numeric,
  estado_salud       text
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
    END AS estado_salud
  FROM sensor s
  LEFT JOIN ultimas u ON u.sensor_id = s.id
  WHERE (p_comuna_id IS NULL OR s.comuna_id = p_comuna_id)
  ORDER BY s.nombre;
END;
$$;
```

**Performance.** El `DISTINCT ON (sensor_id)` con `ORDER BY sensor_id, timestamp_medicion DESC` usa el índice `idx_lectura_sensor_timestamp` directo (lookup → leaf más reciente), evitando un scan de partición. Costo: O(N sensores × log lecturas). Con 1-30 sensores: <5ms.

### 5.6 `resumen_salud_sensores` (KPIs admin)

Agregación del resultado de §5.5. La invoca `GET /api/v1/sensores/resumen` (`api.md` §4.16).

```sql
CREATE OR REPLACE FUNCTION public.resumen_salud_sensores(
  p_comuna_id int DEFAULT NULL
)
RETURNS TABLE (
  total          int,
  online         int,
  intermitente   int,
  offline        int,
  sin_lecturas   int,
  calculado_at   timestamptz
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN QUERY
  SELECT
    COUNT(*)::int                                                    AS total,
    COUNT(*) FILTER (WHERE s.estado_salud = 'online')::int           AS online,
    COUNT(*) FILTER (WHERE s.estado_salud = 'intermitente')::int     AS intermitente,
    COUNT(*) FILTER (WHERE s.estado_salud = 'offline')::int          AS offline,
    COUNT(*) FILTER (WHERE s.estado_salud = 'sin_lecturas')::int     AS sin_lecturas,
    now()                                                            AS calculado_at
  FROM public.sensores_con_salud(p_comuna_id) s;
END;
$$;
```

---

## 6. Row Level Security (RLS)

### Estrategia: enabled, sin políticas
Todas las tablas tienen RLS activado **sin políticas**, lo que significa que ningún rol cliente (`anon`, `authenticated`) puede leer ni escribir directamente. **El backend usa `service_role_key`** que bypasa RLS por diseño.

```sql
ALTER TABLE comuna           ENABLE ROW LEVEL SECURITY;
ALTER TABLE tipo_estado      ENABLE ROW LEVEL SECURITY;
ALTER TABLE usuario          ENABLE ROW LEVEL SECURITY;
ALTER TABLE reporte          ENABLE ROW LEVEL SECURITY;
ALTER TABLE historial_estado ENABLE ROW LEVEL SECURITY;
ALTER TABLE sensor           ENABLE ROW LEVEL SECURITY;
ALTER TABLE lectura          ENABLE ROW LEVEL SECURITY;
```

**Implicaciones:**
- El frontend Vue 3 **nunca** debe usar el cliente JS de Supabase directo — todo HTTP pasa por FastAPI.
- La `service_role_key` **nunca** se expone al cliente. Vive solo en backend (env var).
- Si en el futuro se decide exponer Supabase al frontend (ej. para auth con SDK), se diseñarán políticas explícitas. Detalle en `auth.md`.

---

## 7. Máquina de estados del reporte

Estados (orden lógico, no jerárquico):

```
       ┌─────────────┐
       │  En espera  │  ◀── creado por usuario
       └──────┬──────┘
              │  (funcionario asigna)
              ▼
       ┌─────────────┐
       │ En atencion │
       └──────┬──────┘
              │
        ┌─────┴─────┐
        ▼           ▼
   ┌─────────┐ ┌────────────┐
   │ Atendido │ │ Descartado │
   └─────────┘ └────────────┘
```

| Estado | Quién lo asigna | Cuándo |
|---|---|---|
| `En espera` | Trigger automático | Al crear el reporte |
| `En atencion` | Usuario `municipalidad` | Cuando toma el caso (`atendido_por_id` se setea) |
| `Atendido` | Usuario `municipalidad` | Cuando resuelve |
| `Descartado` | Usuario `municipalidad` | Si es inválido/duplicado |

**Reglas (a aplicar en capa de aplicación, no en DB):**
- Solo usuarios `tipo='municipalidad'` pueden insertar transiciones distintas a "En espera".
- No se puede saltar de "En espera" → "Atendido" sin pasar por "En atencion" (validación en use case, no en SQL).
- El comentario es obligatorio en transiciones a `Descartado`.

---

## 8. Seed de desarrollo

Vive en `supabase/seed.sql` y se ejecuta con `supabase db reset`. Contiene:
- 3 comunas (Santiago, Providencia, Las Condes).
- 3 usuarios mock (2 ciudadanos + 1 funcionario municipal).
- 3 sensores en distintas comunas.
- Lecturas variadas (algunas sobre el umbral, otras debajo) para probar matching IoT.
- 3 reportes en distintos estados.
- ⚠️ El seed actual aún referencia `validacion_iot` (modelo N:M descartado). **Hay que actualizarlo** cuando se aplique el cambio al modelo 1:1.

---

## 9. Índices: justificación una a una

| Índice | Para qué query |
|---|---|
| `idx_usuario_tipo` | Filtrar funcionarios municipales (panel admin). |
| `idx_sensor_comuna` | Listar sensores por comuna (mantenimiento, dashboards). |
| `idx_sensor_ubicacion` (GIST) | `ST_DWithin` en RPC de validación. **Crítico**. |
| `idx_lectura_timestamp` | Heatmap por ventana temporal sin filtro de sensor. |
| `idx_lectura_sensor_timestamp` | Matching IoT (sensor + ventana). **Crítico para RPC**. |
| `idx_reporte_usuario` | "Mis reportes" del ciudadano. |
| `idx_reporte_comuna` | Lista de reportes por comuna (panel funcionario). |
| `idx_reporte_atendido_por` (parcial) | "Casos asignados a mí" del funcionario. |
| `idx_reporte_ubicacion` (GIST) | Heatmap geoespacial agrupado. |
| `idx_historial_reporte_created` | Obtener estado actual de un reporte (`ORDER BY created_at DESC LIMIT 1`). **Crítico**. |

---

## 10. Roadmap del modelo

Cambios postergados pero documentados para no perderlos:

### 10.1 Validación IoT N:M (cuando crezcan los sensores)

Reintroducir tabla asociativa:

```sql
CREATE TABLE validacion_iot (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reporte_id  uuid    NOT NULL REFERENCES reporte(id) ON DELETE CASCADE,
  lectura_id  bigint  NOT NULL REFERENCES lectura(id) ON DELETE CASCADE,
  score       numeric(3, 2) NOT NULL CHECK (score BETWEEN 0 AND 1),
  metodo      text NOT NULL DEFAULT 'automatico'
              CHECK (metodo IN ('automatico', 'manual')),
  usuario_id  uuid REFERENCES usuario(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (reporte_id, lectura_id)
);
```

Migración: `reporte.lectura_evidencia_id` se preserva (denota validación principal) o se descarta migrando los rows existentes a la tabla nueva.

### 10.2 Políticas RLS para acceso desde cliente
Si en algún momento el frontend lee Supabase directo (ej. real-time subscriptions para heatmap), diseñar políticas:
- `comuna`, `tipo_estado` → SELECT público (catálogos).
- `reporte` → SELECT propio (`auth.uid() = usuario_id`) o municipal de la misma comuna.
- `lectura` → SELECT público (data acústica anónima, agregada).

### 10.3 Automatización de creación/drop de particiones

El particionamiento de `lectura` **ya no es roadmap** — está incorporado al MVP (D8, §3.5). Lo que queda como evolución es **automatizar la creación** de particiones futuras y **definir política de retención**:

- **Trigger de adopción de `pg_partman`:** cuando el equipo decida automatizar (típicamente al notar que pre-crear manualmente cada trimestre se vuelve tedioso, o al acercarse a una partición default poblada). Supabase soporta `pg_partman` desde plan Pro. Una vez habilitado, se registra `lectura` como tabla gestionada con cadencia mensual y un buffer de N meses futuros.
- **Política de retención:** por ahora **retenemos todo** (utilidad histórica para heatmap y posibles re-validaciones). Si el volumen lo exige, definir corte (ej. "drop > 24 meses") y configurarlo en `pg_partman` o como cron manual.
- **Compresión:** Postgres nativo no comprime particiones (a diferencia de TimescaleDB). Si la huella en disco se vuelve un problema, evaluar `pg_squeeze` o migrar al stack alternativo descrito en `backend.md` §9.

### 10.4 Vista materializada para heatmap
**Promovida del roadmap al MVP.** Ver §13 para la spec canónica (DDL, refresh, integración con `heatmap_agregado`). Esta entrada se conserva solo como pointer histórico.

---

## 11. Trazabilidad doc ↔ migración

| Sección de este doc | Archivo SQL |
|---|---|
| 3. DDL canónico (extensiones, catálogos, tablas, índices) | `supabase/migrations/<nueva>_initial_schema.sql` |
| 4. Triggers (`handle_new_user`, `set_initial_estado`, `set_updated_at`) | misma migración |
| 5.1–5.4 RPCs (`validar_reporte_ruido`, `*_top_n`, `crear_reporte_con_validacion`, `heatmap_agregado`) | misma migración |
| 6. RLS (enable sin políticas) | misma migración |
| 8. Seed (catálogo `tipo_estado` + datos de dev) | `supabase/seed.sql` |

---

## 12. Plan de regeneración de migración

**Estado actual:** la migración committed (`20260519000000_initial_schema.sql`, anteriormente `20260502225141_…`) refleja una versión previa del modelo y está desalineada con este doc en varios puntos:

| Desalineación | Esta sección |
|---|---|
| Falta `CREATE EXTENSION postgis` | §3.1 |
| `sensor`/`reporte` sin columna `ubicacion geography` generada ni índice GIST | §3.4 / §3.6 |
| Tiene `validacion_iot` (N:M descartada), falta `reporte.lectura_evidencia_id` + `…_timestamp` | §3.6, §10.1 |
| `lectura` no es particionada por rango sobre `timestamp_medicion` | §3.5 (D8) |
| Falta `UNIQUE (sensor_id, timestamp_medicion)` en `lectura` | §3.5 |
| Falta PK compuesta `(id, timestamp_medicion)` en `lectura` (exigida por la partición) | §3.5 |
| `reporte` no tiene FK compuesta a `(lectura.id, lectura.timestamp_medicion)` | §3.6, D6 |
| No incluye ninguna de las 4 RPCs | §5 |

**Decisión:** regenerar como migración limpia (squash). Nada está en producción.

### 12.1 Pasos

1. **Eliminar** `supabase/migrations/20260502225141_initial_schema.sql` y `supabase/seed.sql` (los reemplazamos por nuevos).
2. **Generar** una migración nueva con timestamp actual:
   ```bash
   supabase migration new initial_schema
   ```
3. **Poblar** el nuevo archivo SQL con, en este orden:
   - §3.1 Extensiones (`postgis`).
   - §3.2 Catálogos (`comuna`, `tipo_estado`).
   - §3.3 `usuario` (con CHECK extendido a 3 roles: `ciudadano`, `municipalidad`, `admin` — D9).
   - §3.4 `sensor` (con `ubicacion` generada + GIST).
   - §3.5 `lectura` **particionada** (`PARTITION BY RANGE (timestamp_medicion)`) + PK compuesta + UNIQUE `(sensor_id, timestamp_medicion)`.
   - §3.5.1 Crear particiones mensuales para 2026-05 … 2026-12 + `lectura_default`.
   - §3.6 `reporte` (con `ubicacion` generada + `lectura_evidencia_id` + `lectura_evidencia_timestamp` + FK compuesta + `chk_evidencia_pair` + GIST).
   - §3.7 `historial_estado`.
   - §4 Triggers (`handle_new_user`, `set_initial_estado`, `set_updated_at`).
   - §5.1–5.6 RPCs (incluye `heatmap_agregado`, `sensores_con_salud`, `resumen_salud_sensores`; `crear_reporte_con_validacion` devuelve el par id+timestamp).
   - §6 RLS enable.
4. **Reescribir** `supabase/seed.sql` con: catálogo `tipo_estado`, 3 comunas, 3 sensores con `latitud/longitud` válidos (la columna `ubicacion` se genera automáticamente), unas lecturas mock, sin `validacion_iot`.
5. **Aplicar local:**
   ```bash
   supabase db reset           # drop + recreate + apply migration + seed
   ```
6. **Verificar:**
   - `\dx` muestra `postgis`.
   - `\d+ lectura` muestra `Partition key: RANGE (timestamp_medicion)` y lista las particiones mensuales + `lectura_default`.
   - `SELECT * FROM validar_reporte_ruido(-33.4372, -70.6483, now());` retorna o vacío o un row, sin error.
   - `INSERT` duplicado en `lectura` con mismo `(sensor_id, timestamp_medicion)` falla con UNIQUE violation.
   - Un `INSERT INTO lectura` con `timestamp_medicion` dentro de mayo 2026 cae en `lectura_2026_05` (`SELECT tableoid::regclass, * FROM lectura LIMIT 1;` confirma).
   - `INSERT INTO reporte (..., lectura_evidencia_id, lectura_evidencia_timestamp)` con par válido funciona; con par solo-id-o-solo-timestamp falla por `chk_evidencia_pair`; con id+timestamp inexistentes falla por la FK compuesta.
   - `INSERT INTO usuario (..., tipo) VALUES (..., 'admin')` funciona (CHECK extendido a 3 roles); `tipo='superadmin'` falla.
   - `SELECT * FROM sensores_con_salud();` retorna cada sensor con `estado_salud` calculado (sensor del seed sin lecturas frescas debería aparecer como `sin_lecturas` o `offline` según haya o no rows en `lectura`).
   - `SELECT * FROM resumen_salud_sensores();` retorna 1 row con `total`, `online`, `intermitente`, `offline`, `sin_lecturas`, `calculado_at`.
7. **Aplicar remoto** (cuando esté linkeado el proyecto):
   ```bash
   supabase db push
   ```

### 12.2 Roadmap explícitamente excluido del MVP

- `validacion_iot` (N:M) — §10.1.
- **Automatización** con `pg_partman` y política de retención — §10.3 (las particiones iniciales sí están en el MVP, ver §3.5.1).
- Políticas RLS para acceso cliente — §10.2.

No agregar nada de eso en la migración inicial.

> **Nota.** La vista materializada de heatmap y la tabla `lectura_resumen_horaria` **no están** en la migración inicial. Viven en una migración separada (§13), aplicada después de que el flujo IoT esté funcionando — así la primera migración no se contamina con objetos que dependen de tener `lectura` cargada con datos representativos.

---

## 13. Capa de agregación: rollups horarios + matview de heatmap (OLAP intra-Postgres)

Esta sección define la **capa analítica** del proyecto: agregaciones precomputadas sobre `lectura` (la tabla OLTP, particionada, ~100M rows/año proyectados — `iot.md` §4) que sirven a dashboards históricos y al endpoint `/heatmaps` sin escanear datos crudos en cada request.

**Posición arquitectónica.** Es la respuesta al volumen de time-series **sin agregar infra fuera de Postgres** (no Spark, no DuckDB externo, no Kafka). Implementa el patrón clásico de **rollup batch** (downsample horario por sensor) + **matview con refresh periódico** (heatmap de los últimos 7 días). Ver decisión arquitectónica completa en [`backend.md`](./backend.md) ADR 09.

### 13.1 Tabla `lectura_resumen_horaria` (rollup horario por sensor)

Una row por `(sensor, hora)`. Sirve a series temporales (gráficos del panel municipal, históricos de un sensor, KPIs por hora del día). Refresh idempotente vía función SQL + `pg_cron`.

```sql
CREATE TABLE lectura_resumen_horaria (
  sensor_id     uuid          NOT NULL REFERENCES sensor(id) ON DELETE CASCADE,
  hora          timestamptz   NOT NULL,           -- inicio de la hora (date_bin)
  avg_db        numeric(5, 2) NOT NULL,
  min_db        numeric(5, 2) NOT NULL,
  max_db        numeric(5, 2) NOT NULL,
  p95_db        numeric(5, 2) NOT NULL,           -- percentile_cont(0.95)
  n_lecturas    integer       NOT NULL CHECK (n_lecturas > 0),
  refrescado_at timestamptz   NOT NULL DEFAULT now(),
  PRIMARY KEY (sensor_id, hora)
);

CREATE INDEX idx_resumen_horaria_hora        ON lectura_resumen_horaria (hora DESC);
CREATE INDEX idx_resumen_horaria_sensor_hora ON lectura_resumen_horaria (sensor_id, hora DESC);
```

**Volumen.** 30 sensores × 24 h × 365 días ≈ **263k rows/año** ≈ ~20 MB. Cabe holgado en Supabase free (límite 500 MB).

**Por qué tabla y no matview.** Necesitamos:
- Refresh **incremental** (solo la última hora + ventana de gracia para QoS 1 retrasado), no `REFRESH MATERIALIZED VIEW` completo.
- Permitir **backfill manual** por rango (`refrescar_resumen_horario('2026-05-01')`).
- `UPSERT` controlado vía `ON CONFLICT`, no recomputar 8M rows cada hora.

### 13.2 Función `refrescar_resumen_horario` (idempotente)

```sql
CREATE OR REPLACE FUNCTION public.refrescar_resumen_horario(
  p_desde timestamptz DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_desde timestamptz := COALESCE(
    p_desde,
    date_trunc('hour', now()) - interval '2 hours'  -- gracia QoS 1
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
```

**Notas:**
- Origen `2000-01-01` en `date_bin` garantiza buckets alineados entre invocaciones (mismo criterio que `heatmap_agregado` §5.4).
- La ventana de gracia de 2 h absorbe lecturas QoS 1 retrasadas (HiveMQ → backend → Postgres puede demorar segundos a minutos en escenarios degradados).
- Backfill: `SELECT refrescar_resumen_horario('2026-05-01'::timestamptz);` recomputa desde esa fecha.
- Es `SECURITY INVOKER` (default). Si Supabase `pg_cron` corre como `postgres`, accede sin problema. Si se ejecuta desde el backend, el `service_role` la puede llamar también.

### 13.3 Vista materializada `mv_heatmap_celda_bucket`

Precomputa el heatmap de **buckets de 5 minutos en los últimos 7 días** — la combinación de parámetros que el frontend pedirá el ~90% del tiempo. Para ventanas custom o bucket distinto, el endpoint `/heatmaps` cae al RPC `heatmap_agregado` (§5.4) que escanea `lectura` directo.

```sql
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

-- UNIQUE obligatorio para REFRESH ... CONCURRENTLY
CREATE UNIQUE INDEX idx_mv_heatmap_unique
  ON mv_heatmap_celda_bucket (lng_cell, lat_cell, bucket_start);

CREATE INDEX idx_mv_heatmap_bucket
  ON mv_heatmap_celda_bucket (bucket_start DESC);
```

**Refresh.** `REFRESH MATERIALIZED VIEW CONCURRENTLY mv_heatmap_celda_bucket;` cada 15 min vía `pg_cron`. `CONCURRENTLY` evita lock de lectura (los GETs al endpoint siguen sirviendo la versión anterior mientras se refresca).

**Volumen estimado.** 30 sensores × 7 días × 288 buckets/día (12 por hora) = ~60k rows si todos los sensores publican constantemente. Si los sensores comparten celda (mismo ~100 m), menos. Cabe en free.

**Limitación honesta.** La cláusula `WHERE l.timestamp_medicion >= now() - interval '7 days'` se **congela** al momento del `CREATE MATERIALIZED VIEW` — Postgres no re-evalúa `now()` en cada refresh. Solución: re-crear la matview periódicamente (ej. una vez al mes con `DROP + CREATE`) o aceptar que la ventana se va corriendo "hacia adelante" sin perder datos pero acumulando rows viejos. Como la matview es delete-and-rebuild barato (~60k rows), el camino canónico es: drop + create en el cron mensual de mantenimiento.

### 13.4 Schedule con `pg_cron`

```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Rollup horario: minuto 5 de cada hora (margen para últimas lecturas)
SELECT cron.schedule(
  'refrescar_resumen_horario',
  '5 * * * *',
  $$SELECT public.refrescar_resumen_horario();$$
);

-- Matview heatmap: cada 15 min
SELECT cron.schedule(
  'refrescar_mv_heatmap',
  '*/15 * * * *',
  $$REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_heatmap_celda_bucket;$$
);
```

**Disponibilidad de `pg_cron` en Supabase.** Sí, en todos los planes incluido Free. Dashboard → Database → Extensions → activar `pg_cron`. La extensión vive en la base `postgres` (la default de Supabase) y schedule jobs sobre cualquier base del cluster.

**Inspección:**
```sql
SELECT * FROM cron.job;                       -- jobs registrados
SELECT * FROM cron.job_run_details
  ORDER BY start_time DESC LIMIT 20;          -- últimos runs (status, duración, errores)
```

### 13.5 Integración con el endpoint `/heatmaps`

La RPC `heatmap_agregado` (§5.4) **no cambia** (sigue funcionando contra `lectura` cruda). Lo que cambia es el adaptador:

`LecturaRepository.heatmap(bbox, time_start, time_end, bucket_minutes)`:
1. **Si** `bucket_minutes == 5` **y** `time_end >= now() - interval '7 days'` **y** `time_start >= now() - interval '7 days'`:
   - Sirve desde `mv_heatmap_celda_bucket` con filtro de bbox (`lng_cell BETWEEN … AND lat_cell BETWEEN …`).
2. **Si no**: invoca el RPC `heatmap_agregado` original.

Esto se decide en el adapter (`infrastructure/db/lectura_repo.py`), transparente para el use case y el endpoint. El response shape es idéntico — la matview proyecta las mismas columnas que el RPC.

### 13.6 Trazabilidad

| Objeto | Vive en | Refresh | Sirve a |
|---|---|---|---|
| `lectura_resumen_horaria` | Tabla | `pg_cron`: `'5 * * * *'` | `GET /api/v1/lecturas/resumen` (panel municipal) |
| `mv_heatmap_celda_bucket` | Materialized view | `pg_cron`: `'*/15 * * * *'` | `GET /api/v1/heatmaps` (vía adapter, fallback a RPC) |
| `refrescar_resumen_horario(p_desde)` | Function | — | Backfill manual + cron horario |

### 13.7 Por qué esto cuenta como "big data" para el proyecto de título

Aunque vive 100% dentro de Postgres, esta capa cubre las 3 V típicas del enunciado académico:

- **Volumen.** Diseño escala a ~100M rows/año en `lectura` (particionada). El rollup mantiene una capa servible en ~263k rows que evita escanear los 100M en cada request.
- **Velocidad.** Ingesta MQTT continua (cada 5–10s por sensor) → tabla particionada → agregaciones batch periódicas (pipeline lambda-arquitectónico minimalista: hot OLTP + warm OLAP precomputado).
- **Variedad.** Cross-join entre datos IoT (`lectura`), reportes ciudadanos (`reporte`), catálogo geoespacial (`sensor` con PostGIS), y derivados estadísticos (avg/p95/etc).

Patrón clásico de **downsampling de time-series** + **agregación geoespacial precomputada** + **scheduling declarativo (cron-as-SQL)**. Defensible en tribunal sin vender promesas de infra que no se sostienen ($0/mes en free tier).
