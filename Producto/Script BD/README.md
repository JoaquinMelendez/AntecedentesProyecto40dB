# Script de Base de Datos — 40dB

**Motor:** PostgreSQL + PostGIS (sobre Supabase).
**Fuente:** repositorio backend (carpeta `supabase/`) — https://github.com/JoaquinMelendez/40db-backend

## Contenido de esta carpeta

### `migrations/` — estructura de la base de datos (DDL)

- **`20260519000000_initial_schema.sql`**
  - **Tablas:** `comuna`, `tipo_estado`, `usuario`, `sensor`, `lectura` (particionada por mes), `reporte`, `historial_estado`.
  - **Procedimientos almacenados** (funciones PL/pgSQL y triggers):
    - Triggers: `handle_new_user`, `set_initial_estado`, `set_updated_at`.
    - RPCs: `validar_reporte_ruido`, `validar_reporte_ruido_top_n`, `crear_reporte_con_validacion`, `heatmap_agregado`, `sensores_con_salud`, `resumen_salud_sensores`.
  - **Seguridad:** Row Level Security (RLS) y grants para `service_role`.
- **`20260524000000_extra_comunas_gran_santiago.sql`** — carga de comunas del Gran Santiago.
- **`20260524010000_reportes_admin_archivos.sql`** — campos/archivos admin en reportes.
- **`20260524020000_agregacion_olap.sql`** — capa OLAP: rollups horarios + matview de heatmap.
- **`20260524030000_reporte_comentarios.sql`** — tabla `reporte_comentario` (comentarios internos/externos).

### `seed.sql` — datos de prueba

Catálogo de estados, 32 comunas de Santiago, sensores y lecturas mock para probar el matching IoT.

## Cómo ejecutar (entorno local con Supabase CLI)

```bash
supabase db reset    # aplica migraciones en orden + carga seed.sql
```
