# 40dB — Patrones de Diseño

## Visión general

La arquitectura de 40dB combina ingesta de datos desde dos fuentes heterogéneas (ciudadanos + sensores IoT), procesamiento con cruce de datos, y múltiples vistas de consumo (heatmap público, perfil vecino, dashboard municipal). Los patrones seleccionados atacan tres ejes: separación de responsabilidades, extensibilidad del procesamiento de datos, y desacoplamiento entre módulos.

---

## 1. Repository Pattern

**Problema que resuelve:** Los endpoints de FastAPI no deberían contener queries SQL directas. Si mañana cambian de PostgreSQL a otro motor, o si quieren mockear la base de datos en tests, tendrían que reescribir cada endpoint.

**Dónde se aplica:** Acceso a datos en todos los módulos (reportes, sensores, usuarios, alertas).

**Cómo funciona en 40dB:**

Cada entidad tiene un repositorio que encapsula todas las operaciones de base de datos. Los endpoints y servicios solo interactúan con el repositorio, nunca con SQLAlchemy directamente.

```
app/
├── repositories/
│   ├── reporte_repository.py
│   ├── sensor_repository.py
│   ├── usuario_repository.py
│   └── alerta_repository.py
├── services/
│   └── ...
└── routes/
    └── ...
```

```python
# repositories/reporte_repository.py

class ReporteRepository:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def crear(self, reporte: ReporteCreate, user_id: str) -> Reporte:
        nuevo = Reporte(
            user_id=user_id,
            geom=func.ST_MakePoint(reporte.lng, reporte.lat),
            db_nivel=reporte.db_nivel,
            fuente_tipo=reporte.fuente_tipo,
            timestamp=reporte.timestamp,
        )
        self.db.add(nuevo)
        await self.db.commit()
        return nuevo

    async def obtener_por_usuario(self, user_id: str, page: int, limit: int):
        query = (
            select(Reporte)
            .where(Reporte.user_id == user_id)
            .order_by(Reporte.timestamp.desc())
            .offset((page - 1) * limit)
            .limit(limit)
        )
        result = await self.db.execute(query)
        return result.scalars().all()

    async def obtener_cercanos_a_sensor(self, lat, lng, radio_m, ventana_min):
        """Busca reportes dentro de un radio y ventana temporal de un sensor."""
        query = select(Reporte).where(
            func.ST_DWithin(
                Reporte.geom,
                func.ST_MakePoint(lng, lat),
                radio_m
            ),
            Reporte.timestamp >= datetime.utcnow() - timedelta(minutes=ventana_min)
        )
        result = await self.db.execute(query)
        return result.scalars().all()
```

```python
# En el endpoint, se inyecta el repositorio
@router.post("/reportes", status_code=201)
async def crear_reporte(
    data: ReporteCreate,
    user: Usuario = Depends(get_current_user),
    repo: ReporteRepository = Depends(get_reporte_repo)
):
    return await reporte_service.crear_reporte(repo, data, user)
```

**Beneficio concreto:** Los tests pueden inyectar un `FakeReporteRepository` que usa listas en memoria en vez de PostgreSQL, sin tocar una línea del servicio ni del endpoint.

---

## 2. Strategy Pattern

**Problema que resuelve:** El cálculo de confiabilidad de un reporte podría cambiar según el contexto. Quizás inicialmente es una comparación simple de dB, pero después quieran incorporar factores como hora del día, historial del usuario, o densidad de reportes en la zona. Hardcodear esa lógica impide evolucionar el algoritmo sin romper lo existente.

**Dónde se aplica:** Motor de cruce de datos y cálculo de confiabilidad (módulo Heatmap).

**Cómo funciona en 40dB:**

Se define una interfaz `EstrategiaConfiabilidad` con un método `calcular`. Cada implementación es una estrategia distinta. El servicio de heatmap recibe la estrategia como dependencia y la ejecuta sin saber cuál es.

```python
# strategies/confiabilidad.py
from abc import ABC, abstractmethod

class EstrategiaConfiabilidad(ABC):
    @abstractmethod
    def calcular(self, reporte_db: float, sensor_db: float, distancia_m: float) -> float:
        """Retorna un float entre 0.0 y 1.0"""
        pass


class ConfiabilidadPorDiferencia(EstrategiaConfiabilidad):
    """Estrategia base: compara la diferencia absoluta de dB."""
    def calcular(self, reporte_db, sensor_db, distancia_m) -> float:
        diff = abs(reporte_db - sensor_db)
        if diff < 5:
            return round(0.8 + (5 - diff) * 0.04, 2)   # 0.80 – 1.00
        elif diff < 15:
            return round(0.7 - (diff - 5) * 0.03, 2)    # 0.40 – 0.70
        else:
            return round(max(0.1, 0.3 - (diff - 15) * 0.01), 2)  # 0.10 – 0.30


class ConfiabilidadPonderada(EstrategiaConfiabilidad):
    """Estrategia avanzada: pondera por distancia al sensor."""
    def calcular(self, reporte_db, sensor_db, distancia_m) -> float:
        diff = abs(reporte_db - sensor_db)
        factor_distancia = max(0.5, 1 - (distancia_m / 500))
        base = ConfiabilidadPorDiferencia().calcular(reporte_db, sensor_db, distancia_m)
        return round(base * factor_distancia, 2)
```

```python
# services/heatmap_service.py

class HeatmapService:
    def __init__(self, estrategia: EstrategiaConfiabilidad):
        self.estrategia = estrategia

    async def calcular_confiabilidad_reporte(self, reporte, sensor, distancia_m):
        return self.estrategia.calcular(
            reporte_db=reporte.db_nivel,
            sensor_db=sensor.db_actual,
            distancia_m=distancia_m
        )
```

```python
# En la configuración de la app, se elige la estrategia
# Fácil de cambiar sin tocar el servicio
estrategia = ConfiabilidadPonderada()
heatmap_service = HeatmapService(estrategia=estrategia)
```

**Beneficio concreto:** Cuando el profesor pregunte "¿y si quieren cambiar el algoritmo de confiabilidad?", la respuesta es "creamos una nueva clase que implemente la interfaz, la inyectamos, y el resto del sistema no se entera".

---

## 3. Observer Pattern (Event-Driven)

**Problema que resuelve:** Cuando llega un reporte nuevo o una lectura de sensor, deben pasar varias cosas: almacenarlo, recalcular el heatmap de la zona, verificar si genera una alerta crítica, actualizar el ranking de silencio. Si todo eso va en el mismo endpoint, queda un monolito frágil donde agregar un paso nuevo implica modificar código existente.

**Dónde se aplica:** Procesamiento post-ingesta de reportes y lecturas IoT.

**Cómo funciona en 40dB:**

Un sistema simple de eventos donde los módulos se suscriben a eventos y reaccionan de forma independiente.

```python
# events/event_bus.py
from collections import defaultdict
from typing import Callable

class EventBus:
    def __init__(self):
        self._handlers: dict[str, list[Callable]] = defaultdict(list)

    def subscribe(self, evento: str, handler: Callable):
        self._handlers[evento].append(handler)

    async def publish(self, evento: str, data: dict):
        for handler in self._handlers[evento]:
            await handler(data)


# Instancia global
event_bus = EventBus()
```

```python
# Al iniciar la app, se suscriben los handlers

from events.event_bus import event_bus

# Handler 1: recalcular heatmap de la zona
async def on_reporte_nuevo_heatmap(data):
    await heatmap_service.recalcular_zona(data["lat"], data["lng"])

# Handler 2: evaluar si es alerta crítica
async def on_reporte_nuevo_alerta(data):
    if data["db_nivel"] >= 76:
        await alerta_service.crear_alerta(data)

# Handler 3: actualizar ranking del sector
async def on_reporte_nuevo_ranking(data):
    await ranking_service.invalidar_cache(data["sector_id"])

event_bus.subscribe("reporte.nuevo", on_reporte_nuevo_heatmap)
event_bus.subscribe("reporte.nuevo", on_reporte_nuevo_alerta)
event_bus.subscribe("reporte.nuevo", on_reporte_nuevo_ranking)
event_bus.subscribe("lectura_sensor.nueva", on_reporte_nuevo_heatmap)
```

```python
# En el servicio de reportes, después de guardar:
async def crear_reporte(self, repo, data, user):
    reporte = await repo.crear(data, user.id)
    await event_bus.publish("reporte.nuevo", {
        "reporte_id": reporte.id,
        "lat": data.lat,
        "lng": data.lng,
        "db_nivel": data.db_nivel,
        "sector_id": user.sector_id,
    })
    return reporte
```

**Beneficio concreto:** Si mañana quieren agregar notificaciones push al vecino cuando su reporte es confirmado por un sensor, solo crean un handler nuevo y lo suscriben al evento. Cero cambios al código existente. Esto es el principio Open/Closed en acción.

---

## 4. DTO Pattern (Data Transfer Objects) con Pydantic

**Problema que resuelve:** Sin DTOs, los endpoints reciben diccionarios sin estructura, el modelo de base de datos se expone directamente al frontend (filtrando campos sensibles), y no hay validación centralizada.

**Dónde se aplica:** Todos los endpoints — request y response schemas.

**Cómo funciona en 40dB:**

Pydantic v2 (integrado en FastAPI) actúa como sistema de DTOs con validación automática. Se definen schemas de entrada (lo que recibe el endpoint) y schemas de salida (lo que retorna), separados del modelo de base de datos.

```python
# schemas/reporte.py
from pydantic import BaseModel, Field, field_validator
from datetime import datetime
from enum import Enum

class FuenteTipo(str, Enum):
    TRAFICO = "trafico"
    CONSTRUCCION = "construccion"
    LOCAL_NOCTURNO = "local_nocturno"
    VECINOS = "vecinos"
    EVENTO = "evento"
    OTRO = "otro"

class ReporteCreate(BaseModel):
    """DTO de entrada — lo que manda el frontend."""
    lat: float = Field(ge=-33.55, le=-33.44)
    lng: float = Field(ge=-70.82, le=-70.71)
    db_nivel: float = Field(ge=0, le=140)
    fuente_tipo: FuenteTipo
    timestamp: datetime

    @field_validator("timestamp")
    @classmethod
    def timestamp_no_futuro(cls, v):
        if v > datetime.utcnow():
            raise ValueError("El timestamp no puede ser futuro")
        return v

class ReporteResponse(BaseModel):
    """DTO de salida — lo que ve el frontend. No incluye user_id."""
    id: str
    lat: float
    lng: float
    db_nivel: float
    fuente_tipo: FuenteTipo
    timestamp: datetime
    estado: str
    confiabilidad: float | None = None

    model_config = {"from_attributes": True}
```

```python
# El endpoint usa los DTOs explícitamente
@router.post("/reportes", response_model=ReporteCreateResponse, status_code=201)
async def crear_reporte(data: ReporteCreate, ...):
    # FastAPI valida automáticamente:
    #   - lat/lng dentro de Maipú
    #   - db_nivel entre 0 y 140
    #   - fuente_tipo es un enum válido
    #   - timestamp no es futuro
    # Si algo falla → 422 automático con detalle del error
    ...
```

**Beneficio concreto:** La validación del bounding box de Maipú, el rango de dB, y el enum de fuentes se definen una sola vez en el schema y aplican en todos lados. El frontend nunca ve campos internos como `user_id` o `geom` de PostGIS porque el DTO de salida no los incluye.

---

## 5. Service Layer Pattern

**Problema que resuelve:** Si la lógica de negocio vive dentro de los endpoints (rutas de FastAPI), se vuelve imposible reutilizarla. Por ejemplo, la lógica de "crear un reporte" se necesita en el endpoint REST y potencialmente en un job de procesamiento batch. Además, los endpoints quedan gigantes y difíciles de testear.

**Dónde se aplica:** Toda la lógica de negocio de cada módulo.

**Cómo funciona en 40dB:**

Tres capas claras: Route → Service → Repository.

```
Route (FastAPI)          → Recibe HTTP, valida DTO, llama al servicio
Service (lógica)         → Reglas de negocio, orquestación, eventos
Repository (datos)       → Queries a PostgreSQL/PostGIS
```

```python
# services/reporte_service.py

class ReporteService:
    def __init__(self, repo: ReporteRepository, event_bus: EventBus):
        self.repo = repo
        self.event_bus = event_bus

    async def crear_reporte(self, data: ReporteCreate, user: Usuario):
        # Regla de negocio: rate limiting
        ultimo = await self.repo.obtener_ultimo_del_usuario(user.id)
        if ultimo and (datetime.utcnow() - ultimo.timestamp).seconds < 120:
            raise HTTPException(429, "Debes esperar 2 minutos entre reportes")

        # Persistencia vía repositorio
        reporte = await self.repo.crear(data, user.id)

        # Disparar eventos post-creación
        await self.event_bus.publish("reporte.nuevo", {
            "reporte_id": reporte.id,
            "lat": data.lat,
            "lng": data.lng,
            "db_nivel": data.db_nivel,
            "sector_id": user.sector_id,
        })

        return reporte
```

```python
# routes/reportes.py — el endpoint queda delgado

@router.post("/reportes", response_model=ReporteCreateResponse, status_code=201)
async def crear_reporte(
    data: ReporteCreate,
    user: Usuario = Depends(get_current_user),
    service: ReporteService = Depends(get_reporte_service),
):
    reporte = await service.crear_reporte(data, user)
    return ReporteCreateResponse(
        id=str(reporte.id),
        estado=reporte.estado,
        mensaje="Reporte registrado exitosamente"
    )
```

**Beneficio concreto:** El endpoint tiene 5 líneas. Toda la lógica (rate limit, persistencia, eventos) está en el servicio, que se puede testear unitariamente sin levantar un servidor HTTP.

---

## 6. Middleware / Chain of Responsibility

**Problema que resuelve:** Cada request pasa por una serie de verificaciones secuenciales: ¿tiene JWT válido? → ¿el rol tiene permiso? → ¿no excede rate limit? → ¿las coordenadas están en Maipú? Si estas verificaciones se repiten en cada endpoint, hay duplicación masiva.

**Dónde se aplica:** Pipeline de validación transversal en FastAPI.

**Cómo funciona en 40dB:**

FastAPI permite encadenar dependencias (`Depends`) que actúan como eslabones de una cadena. Cada uno valida una cosa y pasa al siguiente, o corta la cadena con un error.

```python
# dependencies/auth.py

async def get_current_user(
    token: str = Depends(oauth2_scheme),
    db: AsyncSession = Depends(get_db)
) -> Usuario:
    """Eslabón 1: Valida JWT y extrae usuario."""
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=["HS256"])
        user_id = payload.get("sub")
    except JWTError:
        raise HTTPException(401, "Token inválido")
    
    user = await db.get(Usuario, user_id)
    if not user:
        raise HTTPException(401, "Usuario no encontrado")
    return user


def require_role(rol_requerido: str):
    """Eslabón 2: Verifica que el usuario tenga el rol correcto."""
    async def dependency(user: Usuario = Depends(get_current_user)):
        if user.rol != rol_requerido:
            raise HTTPException(403, f"Se requiere rol: {rol_requerido}")
        return user
    return dependency
```

```python
# En los endpoints se encadenan los eslabones necesarios

# Endpoint público: sin cadena
@router.get("/heatmap")
async def get_heatmap(params: HeatmapQuery = Depends()):
    ...

# Endpoint de vecino: JWT + cualquier rol
@router.post("/reportes")
async def crear_reporte(user: Usuario = Depends(get_current_user)):
    ...

# Endpoint admin: JWT + rol funcionario
@router.get("/admin/alertas")
async def get_alertas(user: Usuario = Depends(require_role("funcionario"))):
    ...
```

**Beneficio concreto:** La autenticación y autorización se declaran una vez y se reutilizan en todos los endpoints. Agregar un nuevo eslabón (ej: verificar que el vecino completó onboarding) es crear una dependencia más y encadenarla.

---

## Mapa de patrones por módulo

| Módulo | Patrones aplicados |
|--------|--------------------|
| Auth | DTO (Pydantic), Service Layer, Chain of Responsibility (middleware JWT) |
| Reportes | Repository, Service Layer, DTO, Observer (eventos post-creación), Chain of Responsibility |
| Sensores IoT | Repository, Service Layer, DTO, Observer (eventos post-lectura) |
| Heatmap | Strategy (cálculo de confiabilidad), Repository, Service Layer |
| Dashboard/Admin | Repository, Service Layer, DTO, Chain of Responsibility (rol funcionario) |
| Ranking | Repository, Service Layer, Observer (invalidación de caché) |

---

## Diagrama de flujo: Reporte nuevo (todos los patrones en acción)

```
[Frontend Vue 3]
       │
       ▼
  POST /api/reportes
  Body: ReporteCreate (DTO)
       │
       ▼
┌─────────────────────────┐
│  Chain of Responsibility │
│  1. JWT válido?          │──── 401
│  2. Rol vecino?          │──── 403
│  3. DTO válido?          │──── 422 (Pydantic auto)
└─────────┬───────────────┘
          │
          ▼
┌─────────────────────────┐
│     Service Layer        │
│  ReporteService          │
│  - rate limit check      │──── 429
│  - llama al repositorio  │
│  - publica evento        │
└─────────┬───────────────┘
          │
    ┌─────┴──────┐
    ▼            ▼
┌────────┐  ┌──────────────────────┐
│  Repo  │  │   Observer/EventBus  │
│ INSERT │  │   "reporte.nuevo"    │
│ PostGIS│  │                      │
└────────┘  │  ┌─ HeatmapHandler   │
            │  │  (Strategy para    │
            │  │   confiabilidad)   │
            │  ├─ AlertaHandler     │
            │  └─ RankingHandler    │
            └──────────────────────┘
```

---

## Justificación académica

Estos seis patrones no se eligieron por agregar complejidad, sino porque cada uno resuelve un problema real del dominio de 40dB:

**Repository** permite testear sin base de datos y cambiar de motor sin reescribir lógica. En un proyecto de 12 semanas con 2 personas, poder correr tests rápidos sin PostgreSQL ahorra días.

**Strategy** existe porque el algoritmo de confiabilidad es experimental — van a iterarlo durante todo el semestre. Encapsularlo permite cambiar la fórmula sin romper el resto.

**Observer** desacopla la ingesta de datos de sus consecuencias (heatmap, alertas, ranking). Cada módulo evoluciona independientemente, lo cual es clave cuando dos personas trabajan en paralelo.

**DTO** con Pydantic convierte la validación en declarativa: se define una vez en el schema y aplica en todos lados, eliminando bugs por datos malformados.

**Service Layer** separa la lógica de negocio de HTTP. Si mañana agregan un CLI o un worker async, reutilizan los servicios tal cual.

**Chain of Responsibility** evita duplicar auth y validaciones en cada endpoint, que es el error más común en APIs de proyectos académicos.
