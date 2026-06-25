# 40dB — Plataforma de reportes de ruido urbano

**40dB** es una plataforma web que permite a los vecinos reportar ruidos molestos a su
municipalidad, respaldando cada denuncia con mediciones de **sensores de audio IoT**.
Incluye un **mapa de calor** de niveles de ruido, un **panel municipal** para gestionar
los reportes y monitoreo del estado de los sensores.

> Proyecto de título — **TPY1101**, Equipo 4, Sección 001D.

## Características

- Reporte ciudadano georreferenciado, validado con sensores IoT cercanos.
- Mapa de calor (heatmap) de ruido por sector y franja horaria.
- Panel municipal: gestión de reportes, estados y analytics.
- Monitoreo de sensores (estado de salud: online / intermitente / offline).
- Autenticación con roles: ciudadano, municipalidad y admin.

## Tecnologías

| Capa | Stack |
|------|-------|
| Frontend | Vue 3 · TypeScript · Vite · Pinia · Vue Router · Leaflet (heatmap) · Chart.js |
| Backend | FastAPI (Python) · Pydantic · JWT |
| Base de datos | PostgreSQL + PostGIS (Supabase) |
| IoT | ESP32 + sensor de audio · MQTT (paho-mqtt) |
| Testing / QA | Vitest · Cypress · pytest · k6 · ruff · ESLint |
| Despliegue | Vercel (frontend) |

## Estructura del repositorio

```
Documentación/   Informe, presentación, WireFrame, MER, Gantt, diagramas, evidencias QA y diseño
Gestión/         Documento 1.1.2 (definición e identificación del proyecto)
Producto/        Código fuente (ZIP), script de base de datos y descripción
Integrantes.txt  Integrantes del equipo
```

## Repositorios de código

- **Frontend:** https://github.com/delll000/40db-frontend
- **Backend:** https://github.com/JoaquinMelendez/40db-backend
- **IoT:** https://github.com/JoaquinMelendez/40db-IoT

## Equipo — Grupo N°4 (40dB)

- **Joaquín Andrés Meléndez Henríquez**
- **Ignacio Benjamín Saavedra Del Canto**
