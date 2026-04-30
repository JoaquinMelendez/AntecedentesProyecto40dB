# 40dB — Backend: Payloads y Responsabilidades

## Resumen de módulos

| Módulo | Responsable | Descripción |
|--------|-------------|-------------|
| Auth | Por definir | Autenticación Google OAuth 2.0, emisión de JWT, gestión de roles |
| Reportes | Por definir | CRUD de reportes ciudadanos, validación de datos, rate limiting |
| Sensores IoT | Por definir | Ingesta de lecturas desde AWS IoT Core, monitoreo de estado |
| Heatmap | Por definir | Generación del mapa de calor, interpolación, cruce de datos |
| Dashboard / Admin | Por definir | Métricas agregadas, alertas, analytics, exportación |
| Ranking | Por definir | Cálculo de ranking de silencio por sector |

---

## 1. Módulo Auth

### Responsabilidades
- Recibir el token de Google desde el frontend y validarlo contra la API de Google.
- Determinar el rol del usuario: si el dominio del correo es institucional (`@maipu.cl`) → `funcionario`, si no → `vecino`.
- Emitir un JWT propio con el `user_id`, `rol` y `email` en el payload.
- Si el usuario es nuevo, marcarlo como `es_nuevo: true` para que el frontend muestre el flujo de onboarding (selección de sector).
- Guardar/actualizar el usuario en la base de datos.

### Endpoints

#### `POST /api/auth/google-callback`
Intercambia el token de Google por un JWT de 40dB.

**Request:**
```json
{
  "google_token": "eyJhbGciOiJSUzI1NiIs..."
}
```

**Response (200):**
```json
{
  "jwt": "eyJhbGciOiJIUzI1NiIs...",
  "user": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "email": "juan.perez@gmail.com",
    "nombre": "Juan Pérez",
    "rol": "vecino",
    "sector": null,
    "es_nuevo": true
  }
}
```

**Response (401):**
```json
{
  "detail": "Token de Google inválido o expirado"
}
```

#### `PUT /api/auth/completar-perfil`
Completa el onboarding del vecino nuevo asignándole un sector.

**Headers:** `Authorization: Bearer <jwt>`

**Request:**
```json
{
  "sector_id": 12,
  "comuna": "Maipú"
}
```

**Response (200):**
```json
{
  "ok": true,
  "user": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "sector": "Villa El Abrazo",
    "sector_id": 12
  }
}
```

#### `GET /api/auth/me`
Retorna el perfil del usuario autenticado. Útil para que el frontend sepa qué rol y sector tiene al recargar la página.

**Headers:** `Authorization: Bearer <jwt>`

**Response (200):**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "email": "juan.perez@gmail.com",
  "nombre": "Juan Pérez",
  "rol": "vecino",
  "sector": "Villa El Abrazo",
  "sector_id": 12,
  "comuna": "Maipú",
  "creado_en": "2026-04-10T08:00:00Z"
}
```

#### `GET /api/auth/sectores?comuna=maipu`
Lista los sectores disponibles para el selector de onboarding.

**Response (200):**
```json
{
  "sectores": [
    { "id": 1, "nombre": "Av. Pajaritos", "centro_lat": -33.5090, "centro_lng": -70.7580 },
    { "id": 2, "nombre": "Villa El Abrazo", "centro_lat": -33.5120, "centro_lng": -70.7600 },
    { "id": 12, "nombre": "El Trébol", "centro_lat": -33.5050, "centro_lng": -70.7550 }
  ]
}
```

---

## 2. Módulo Reportes

### Responsabilidades
- Recibir reportes ciudadanos con nivel de dB, geolocalización, tipo de fuente y timestamp.
- Validar que el nivel de dB esté en un rango plausible (0–140 dB).
- Validar que las coordenadas estén dentro de los límites de la comuna de Maipú.
- Aplicar rate limiting por usuario (máx. 1 reporte cada 2 minutos por usuario).
- Almacenar el reporte con referencia al usuario y geometría PostGIS.
- Exponer el historial de reportes del usuario autenticado.

### Endpoints

#### `POST /api/reportes`
Crea un nuevo reporte ciudadano.

**Headers:** `Authorization: Bearer <jwt>`

**Request:**
```json
{
  "lat": -33.5102,
  "lng": -70.7574,
  "db_nivel": 72.4,
  "fuente_tipo": "construccion",
  "timestamp": "2026-04-18T14:30:00Z"
}
```

**Validaciones del backend:**
- `db_nivel`: float, rango [0, 140]. Rechazar valores fuera de rango.
- `fuente_tipo`: enum → `"trafico"`, `"construccion"`, `"local_nocturno"`, `"vecinos"`, `"evento"`, `"otro"`.
- `lat/lng`: deben caer dentro del bounding box de Maipú (aprox. lat: -33.44 a -33.55, lng: -70.82 a -70.71).
- `timestamp`: no puede ser futuro ni tener más de 10 minutos de antigüedad.
- Rate limit: si el usuario envió un reporte hace menos de 2 minutos → rechazar.

**Response (201):**
```json
{
  "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "estado": "recibido",
  "mensaje": "Reporte registrado exitosamente"
}
```

**Response (429 — rate limit):**
```json
{
  "detail": "Debes esperar al menos 2 minutos entre reportes"
}
```

**Response (422 — validación):**
```json
{
  "detail": "db_nivel fuera de rango permitido (0-140)"
}
```

#### `GET /api/reportes/mis-reportes`
Historial de reportes del usuario autenticado con paginación.

**Headers:** `Authorization: Bearer <jwt>`

**Query params:** `page` (default 1), `limit` (default 10, max 50), `desde` (fecha ISO opcional), `hasta` (fecha ISO opcional)

**Response (200):**
```json
{
  "reportes": [
    {
      "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "lat": -33.5102,
      "lng": -70.7574,
      "db_nivel": 72.4,
      "fuente_tipo": "construccion",
      "timestamp": "2026-04-18T14:30:00Z",
      "estado": "visto",
      "confiabilidad": 0.85
    }
  ],
  "total": 23,
  "page": 1,
  "pages": 3
}
```

**Estados posibles de un reporte:** `"recibido"` → `"visto"` → `"en_proceso"` → `"cerrado"`

---

## 3. Módulo Sensores IoT

### Responsabilidades
- Recibir lecturas periódicas de los sensores ESP32 reenviadas por AWS IoT Core (vía HTTP action rule).
- Autenticar las lecturas con un API key o token de dispositivo.
- Almacenar cada lectura con coordenadas fijas del sensor, timestamp y nivel de dB.
- Monitorear el estado de los sensores: detectar si un sensor dejó de reportar (timeout > 15 minutos).
- Exponer el estado de hardware para el dashboard municipal.

### Endpoints

#### `POST /api/sensores/lectura`
Recibe una lectura desde AWS IoT Core.

**Headers:** `X-Device-Token: <token_dispositivo>`

**Request:**
```json
{
  "sensor_id": "sensor-001",
  "db_nivel": 64.3,
  "timestamp": "2026-04-18T14:32:00Z"
}
```

**Notas:**
- Las coordenadas no se envían en cada lectura porque son fijas. Se registran una vez al dar de alta el sensor en la base de datos.
- El `sensor_id` debe existir en la tabla de sensores registrados.
- `db_nivel`: float, rango [0, 140].

**Response (201):**
```json
{
  "ok": true,
  "sensor_id": "sensor-001",
  "lectura_id": "uuid"
}
```

**Response (403):**
```json
{
  "detail": "Token de dispositivo inválido"
}
```

#### `GET /api/admin/sensores`
Lista todos los sensores con su estado actual. **Solo rol `funcionario`.**

**Headers:** `Authorization: Bearer <jwt>`

**Response (200):**
```json
{
  "sensores": [
    {
      "id": "sensor-001",
      "nombre": "Sensor Av. Pajaritos",
      "ubicacion": "Av. Pajaritos / 5 de Abril",
      "lat": -33.5090,
      "lng": -70.7580,
      "ultimo_dato": "2026-04-18T14:32:00Z",
      "db_actual": 64.3,
      "bateria_pct": 78,
      "calibracion_ok": true,
      "estado": "activo"
    },
    {
      "id": "sensor-002",
      "nombre": "Sensor Plaza de Maipú",
      "ubicacion": "Plaza de Maipú",
      "lat": -33.5110,
      "lng": -70.7560,
      "ultimo_dato": "2026-04-18T13:55:00Z",
      "db_actual": 51.2,
      "bateria_pct": 45,
      "calibracion_ok": true,
      "estado": "warning"
    }
  ]
}
```

**Lógica de `estado`:**
- `"activo"`: último dato hace menos de 15 min, batería > 20%.
- `"warning"`: último dato hace 15–30 min, o batería entre 10–20%.
- `"offline"`: último dato hace más de 30 min, o batería < 10%.

---

## 4. Módulo Heatmap

### Responsabilidades
- Agregar todos los puntos de datos (reportes ciudadanos + lecturas de sensores) para una ventana de tiempo y filtros dados.
- Ejecutar el cruce de datos: comparar cada reporte con la lectura del sensor más cercano (si existe dentro de un radio de 500m y ventana de ±15 min) para asignar un índice de confiabilidad al reporte.
- Ponderar los puntos según confiabilidad al generar el heatmap.
- Calcular el `nivel_indice_emergencia` (1–5) basado en umbrales de dB.
- Servir los datos al frontend para que Leaflet renderice el heatmap.

### Lógica del índice de emergencia

| Nivel | Rango dB | Significado |
|-------|----------|-------------|
| 1 | 0–45 | Silencioso (dentro de norma nocturna) |
| 2 | 46–55 | Normal (dentro de norma diurna) |
| 3 | 56–65 | Moderado (límite de norma) |
| 4 | 66–75 | Alto (supera norma) |
| 5 | 76+ | Crítico (muy por sobre norma) |

### Lógica de confiabilidad

- Reporte sin sensor cercano → `confiabilidad: null` (se usa con peso base).
- Reporte con sensor cercano: se compara `db_nivel` del reporte vs lectura del sensor. Si la diferencia es < 5 dB → confiabilidad alta (0.8–1.0). Si es 5–15 dB → media (0.4–0.7). Si es > 15 dB → baja (0.1–0.3), posible falso positivo.

### Endpoints

#### `GET /api/heatmap`
Retorna los puntos de datos para renderizar el mapa de calor.

**Query params:**
- `hora_inicio` (HH:MM, default "00:00")
- `hora_fin` (HH:MM, default "23:59")
- `fuente` (enum o "todas", default "todas")
- `origen` ("todos", "sensores", "reportes", default "todos")
- `fecha` (ISO date, default hoy)

**Response (200):**
```json
{
  "puntos": [
    {
      "lat": -33.5102,
      "lng": -70.7574,
      "db": 68.5,
      "nivel_indice_emergencia": 3,
      "confiabilidad": 0.85,
      "fuente_principal": "trafico",
      "num_reportes": 12,
      "tiene_sensor_cercano": true,
      "origen": "reporte"
    },
    {
      "lat": -33.5090,
      "lng": -70.7580,
      "db": 64.3,
      "nivel_indice_emergencia": 3,
      "confiabilidad": 1.0,
      "fuente_principal": null,
      "num_reportes": 0,
      "tiene_sensor_cercano": false,
      "origen": "sensor"
    }
  ],
  "metadata": {
    "total_puntos": 347,
    "rango_horario": "08:00-22:00",
    "fecha": "2026-04-18",
    "ultima_actualizacion": "2026-04-18T14:35:00Z"
  }
}
```

---

## 5. Módulo Dashboard / Admin

### Responsabilidades
- Proveer estadísticas agregadas de la comuna (promedio dB, reportes totales, zonas críticas).
- Gestionar alertas críticas (nivel ≥ 4) y permitir marcarlas como atendidas.
- Proveer datos de analytics: tendencias, distribución por fuente, reportes por sector.
- Exportar datos en CSV y PDF.
- **Todos los endpoints de este módulo requieren `rol: funcionario`.**

### Endpoints

#### `GET /api/stats/comunal`
Estadísticas generales para la landing pública. **No requiere autenticación.**

**Response (200):**
```json
{
  "promedio_db": 58.3,
  "reportes_hoy": 34,
  "sensores_activos": 3,
  "zona_mas_ruidosa": "Av. Pajaritos",
  "zona_mas_silenciosa": "Villa El Abrazo",
  "total_reportes_mes": 412
}
```

#### `GET /api/admin/alertas`
Lista alertas críticas. **Solo rol `funcionario`.**

**Headers:** `Authorization: Bearer <jwt>`

**Query params:** `nivel_min` (int, default 4), `estado` ("pendiente", "atendida", "todas"), `limit`, `page`

**Response (200):**
```json
{
  "alertas": [
    {
      "id": "uuid",
      "lat": -33.5050,
      "lng": -70.7620,
      "db": 89.2,
      "nivel_indice_emergencia": 5,
      "fuente_tipo": "construccion",
      "timestamp": "2026-04-18T13:45:00Z",
      "confirmado_por_sensor": true,
      "sensor_id": "sensor-001",
      "estado": "pendiente",
      "sector": "Av. Pajaritos"
    }
  ],
  "total": 5,
  "page": 1
}
```

#### `PATCH /api/admin/alertas/{id}`
Marca una alerta como atendida. **Solo rol `funcionario`.**

**Headers:** `Authorization: Bearer <jwt>`

**Request:**
```json
{
  "estado": "atendida",
  "nota": "Se envió inspector a terreno"
}
```

**Response (200):**
```json
{
  "ok": true,
  "alerta_id": "uuid",
  "estado": "atendida",
  "atendida_por": "funcionario@maipu.cl",
  "atendida_en": "2026-04-18T15:00:00Z"
}
```

#### `GET /api/admin/analytics`
Datos para los gráficos del dashboard. **Solo rol `funcionario`.**

**Headers:** `Authorization: Bearer <jwt>`

**Query params:** `desde` (ISO date), `hasta` (ISO date)

**Response (200):**
```json
{
  "tendencia_diaria": [
    {
      "fecha": "2026-04-17",
      "promedio_db": 56.8,
      "total_reportes": 42,
      "total_lecturas_sensor": 288
    }
  ],
  "reportes_por_sector": [
    { "sector": "Av. Pajaritos", "total": 128, "promedio_db": 67.2 },
    { "sector": "Villa El Abrazo", "total": 45, "promedio_db": 48.1 }
  ],
  "distribucion_fuentes": [
    { "fuente": "trafico", "porcentaje": 45, "total": 185 },
    { "fuente": "construccion", "porcentaje": 25, "total": 103 },
    { "fuente": "local_nocturno", "porcentaje": 15, "total": 62 },
    { "fuente": "vecinos", "porcentaje": 8, "total": 33 },
    { "fuente": "evento", "porcentaje": 4, "total": 16 },
    { "fuente": "otro", "porcentaje": 3, "total": 13 }
  ],
  "horarios_criticos": [
    { "hora": 8, "promedio_db": 62.1 },
    { "hora": 13, "promedio_db": 65.4 },
    { "hora": 18, "promedio_db": 68.9 },
    { "hora": 22, "promedio_db": 59.3 }
  ]
}
```

#### `GET /api/admin/exportar`
Exporta datos en CSV o PDF. **Solo rol `funcionario`.**

**Headers:** `Authorization: Bearer <jwt>`

**Query params:** `formato` ("csv" o "pdf"), `desde`, `hasta`, `sector_id` (opcional)

**Response:** Archivo descargable con header `Content-Disposition: attachment; filename="40db_reporte_2026-04-18.csv"`

---

## 6. Módulo Ranking

### Responsabilidades
- Calcular el ranking de silencio por sector basado en el promedio de dB de las últimas 24 horas.
- Servir el ranking general y la posición del sector del usuario autenticado.

### Endpoints

#### `GET /api/ranking/silencio`
**Query params:** `comuna` (default "maipu"), `top` (int, default 5)

**Response (200):**
```json
{
  "ranking": [
    { "posicion": 1, "sector": "Villa El Abrazo", "sector_id": 2, "promedio_db": 42.1 },
    { "posicion": 2, "sector": "Parque Los Héroes", "sector_id": 7, "promedio_db": 44.8 },
    { "posicion": 3, "sector": "El Trébol", "sector_id": 12, "promedio_db": 46.2 },
    { "posicion": 4, "sector": "Las Rejas", "sector_id": 5, "promedio_db": 49.5 },
    { "posicion": 5, "sector": "Av. Pajaritos", "sector_id": 1, "promedio_db": 52.3 }
  ],
  "total_sectores": 15,
  "calculado_en": "2026-04-18T14:00:00Z"
}
```

#### `GET /api/ranking/mi-sector`
Retorna la posición del sector del usuario autenticado.

**Headers:** `Authorization: Bearer <jwt>`

**Response (200):**
```json
{
  "posicion": 3,
  "sector": "El Trébol",
  "sector_id": 12,
  "promedio_db": 46.2,
  "total_sectores": 15,
  "mejor_que_pct": 80
}
```

---

## Resumen de autenticación y permisos

| Endpoint | Auth | Rol requerido |
|----------|------|---------------|
| `POST /api/auth/google-callback` | No | — |
| `PUT /api/auth/completar-perfil` | JWT | cualquiera |
| `GET /api/auth/me` | JWT | cualquiera |
| `GET /api/auth/sectores` | No | — |
| `POST /api/reportes` | JWT | vecino |
| `GET /api/reportes/mis-reportes` | JWT | vecino |
| `POST /api/sensores/lectura` | Device Token | — (M2M) |
| `GET /api/heatmap` | No | — |
| `GET /api/stats/comunal` | No | — |
| `GET /api/admin/sensores` | JWT | funcionario |
| `GET /api/admin/alertas` | JWT | funcionario |
| `PATCH /api/admin/alertas/{id}` | JWT | funcionario |
| `GET /api/admin/analytics` | JWT | funcionario |
| `GET /api/admin/exportar` | JWT | funcionario |
| `GET /api/ranking/silencio` | No | — |
| `GET /api/ranking/mi-sector` | JWT | vecino |

---

## Middleware y responsabilidades transversales

### Middleware de autenticación JWT
- Extrae el token del header `Authorization: Bearer <token>`.
- Decodifica y valida el JWT (expiración, firma).
- Inyecta el objeto `current_user` en el request con `id`, `email`, `rol`, `sector_id`.
- Endpoints públicos lo omiten.

### Middleware de roles
- Verifica que `current_user.rol` tenga permiso para el endpoint.
- Retorna 403 si no tiene el rol requerido.

### Rate limiting
- Por usuario autenticado: máx. 1 reporte cada 2 minutos.
- Por IP para endpoints públicos: máx. 60 requests/minuto.
- Para sensores: máx. 1 lectura cada 30 segundos por `sensor_id`.

### Validación geoespacial
- Bounding box de Maipú: lat [-33.55, -33.44], lng [-70.82, -70.71].
- Reportes fuera del bounding box se rechazan con 422.

### Manejo de errores estándar
Todos los errores siguen el formato:
```json
{
  "detail": "Mensaje descriptivo del error",
  "code": "CODIGO_INTERNO"
}
```

Códigos HTTP usados: 200, 201, 400, 401, 403, 404, 422, 429, 500.
