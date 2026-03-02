# 🧠 Roadmap: Compra Inteligente con IA/Python/LLM
**Proyecto:** restaurante-comandpos  
**Versión actual:** `inventory.fn_intelligent_purchasing_v2` (lógica v4)  
**Fecha:** Marzo 2026

---

## 1. Estado Actual — Lo que ya tienes (v4 es sólido)

### Qué hace la función SQL actual
```
fn_intelligent_purchasing_v2(business_unit_id, location_id, urgency_threshold)
```

| Feature | Cómo funciona | Nivel |
|---------|--------------|-------|
| **WMA (Weighted Moving Average)** | Demanda promedio de 60 días desde `item_in_warehouses` | ✅ Funcional |
| **trend_factor** | avg_7d / avg_60d, clamped 0.5–2.0 | ✅ Funcional |
| **weekday_factor** | Ajuste por día de semana actual | ✅ Funcional |
| **feedback_loop** | correction_factor = aprobado/sugerido (últimos 30d) | ✅ Funcional |
| **ABC/XYZ classification** | `fn_update_item_classification` | ✅ Funcional |
| **EOQ (Economic Order Qty)** | `SQRT(2 * demand * ordering_cost / holding_cost)` | ✅ Funcional |
| **Safety stock** | z_score × std_dev × sqrt(lead_time) | ✅ Funcional |
| **Derived demand** | Demanda de transformaciones (ej. camaron → ceviche) | ✅ Funcional |
| **delivery_window** | IMMEDIATE / THIS_WEEK / NEXT_WEEK / MONTHLY | ✅ Funcional |
| **unit_quantity** | Conversión botellas↔ml para licores | ✅ Funcional |

### Limitaciones reales vs. sistemas enterprise 2026

| Limitación | Impacto | Solución |
|-----------|---------|----------|
| WMA no detecta estacionalidad anual | Navidad/Semana Santa = misma predicción que enero | Prophet / ETS |
| trend_factor inestable con pocos datos | Ítem con 3 ventas en 7d → ratio ruidoso | Bayesian smoothing |
| Sin detección de outliers pre-cálculo | Un evento (fiesta, daño) distorsiona la media 60d | Isolation Forest |
| El campo `reason` es string hardcodeado | El comprador no entiende *por qué* se sugiere | LLM explicación |
| Sin factores externos | Feriados, clima, eventos locales ignorados | Calendar features |
| Selección de proveedor = 1 sola opción | No compara múltiples precios dinámicamente | ML ranking |
| Sin confianza en la predicción | No sé si confiar en la sugerencia | Intervalos de confianza |

---

## 2. Arquitectura Target — Sistema Híbrido PostgreSQL + Python

```
┌─────────────────────────────────────────────────────────────────┐
│                     NUXT 4 (Node.js)                           │
│  /api/restaurant/shop/generate-suggestions.ts                   │
│  /api/restaurant/shop/purchase-suggestions.ts                   │
└────────────────┬────────────────────────────────────────────────┘
                 │ HTTP POST /forecast
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│              PYTHON MICROSERVICE (FastAPI)                       │
│              http://localhost:8001  (o Docker container)        │
│                                                                 │
│  POST /forecast        → Prophet/XGBoost demand prediction      │
│  POST /anomalies       → Isolation Forest outlier detection      │
│  POST /explain         → LLM reason generation (GPT-4o mini)    │
│  POST /supplier-rank   → ML supplier scoring                     │
│  GET  /health          → Health check                           │
└────────────────┬────────────────────────────────────────────────┘
                 │ psycopg2 / SQLAlchemy
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                     PostgreSQL                                  │
│  inventory.item_in_warehouses  (historial de movimientos)       │
│  inventory.auto_purchase_suggestions  (sugerencias)             │
│  inventory.fn_intelligent_purchasing_v2  (función actual)       │
│  restaurant.catalogue_details  (precios por proveedor)          │
└─────────────────────────────────────────────────────────────────┘
```

### Flujo de generación mejorado

```
1. Node llama fn_intelligent_purchasing_v2 (SQL) → base suggestions
2. Node llama Python /forecast por cada item_id    → predicted_demand + confidence
3. Node llama Python /anomalies                    → filtra outliers del historial
4. Node llama Python /explain (batch)              → reason en español natural
5. Node actualiza auto_purchase_suggestions con los campos enriquecidos
6. Frontend lee purchase-suggestions.ts (sin cambios)
```

---

## 3. Estructura del Microservicio Python

### Directorio del proyecto
```
restaurante-comandpos/
└── services/
    └── purchasing-ai/
        ├── main.py                 ← FastAPI app entry point
        ├── requirements.txt
        ├── Dockerfile
        ├── .env.example
        ├── routers/
        │   ├── forecast.py         ← Prophet + XGBoost
        │   ├── anomalies.py        ← Isolation Forest
        │   ├── explain.py          ← OpenAI LLM
        │   └── supplier_rank.py    ← Supplier ML scoring
        ├── models/
        │   ├── schemas.py          ← Pydantic request/response models
        │   └── db.py               ← psycopg2 connection to PostgreSQL
        └── utils/
            ├── calendar_features.py ← Feriados RD, weekday patterns
            └── cache.py            ← Redis/memory cache para modelos
```

### `requirements.txt`
```txt
fastapi==0.110.0
uvicorn==0.29.0
pydantic==2.6.0

# Forecasting
prophet==1.1.5
xgboost==2.0.3
scikit-learn==1.4.0
numpy==1.26.4
pandas==2.2.1

# Database
psycopg2-binary==2.9.9
sqlalchemy==2.0.29

# LLM
openai==1.14.0

# Utils
python-dotenv==1.0.1
httpx==0.27.0
redis==5.0.3
```

---

## 4. Módulo 1: Forecasting (Prophet + XGBoost)

### Por qué Prophet para un restaurante
- Maneja **estacionalidad semanal** (viernes/sábados = picos)
- Maneja **feriados nacionales** (Semana Santa, Navidad, Independencia RD)
- Funciona bien con **pocos datos** (mínimo 30 días)
- Produce **intervalos de confianza** (yhat_lower, yhat_upper)

### `routers/forecast.py`
```python
from fastapi import APIRouter
from pydantic import BaseModel
from typing import List, Optional
import pandas as pd
from prophet import Prophet
from models.db import get_sales_history

router = APIRouter(prefix="/forecast", tags=["forecast"])

class ForecastRequest(BaseModel):
    item_id: int
    business_unit_id: int
    location_id: int
    days_ahead: int = 14        # cuántos días predecir hacia adelante
    lookback_days: int = 180    # historial a usar

class ForecastResponse(BaseModel):
    item_id: int
    predicted_demand_total: float     # total para days_ahead
    predicted_daily_avg: float        # promedio diario
    confidence_low: float             # percentil 10
    confidence_high: float            # percentil 90
    trend_direction: str              # "UP" | "DOWN" | "STABLE"
    trend_pct: float                  # % de cambio vs. 30d anteriores
    seasonality_peak_day: str         # "FRIDAY" | "SATURDAY" etc.
    model_used: str                   # "prophet" | "ets" | "fallback_wma"
    data_points: int                  # cuántos días de datos se usaron

@router.post("/", response_model=ForecastResponse)
async def forecast_item(req: ForecastRequest):
    # 1. Obtener historial de ventas desde PostgreSQL
    df = await get_sales_history(
        item_id=req.item_id,
        business_unit_id=req.business_unit_id,
        days=req.lookback_days
    )

    if len(df) < 14:
        # Fallback: WMA simple (mismo que SQL actual)
        return _fallback_wma(df, req)

    # 2. Prophet forecast
    df_prophet = df[["date", "qty"]].rename(columns={"date": "ds", "qty": "y"})

    model = Prophet(
        seasonality_mode="multiplicative",
        weekly_seasonality=True,
        yearly_seasonality=len(df) > 90,   # solo si hay >90 días
        daily_seasonality=False,
        interval_width=0.80,
    )
    # Agregar feriados de República Dominicana
    model.add_country_holidays(country_name="DO")
    model.fit(df_prophet)

    future = model.make_future_dataframe(periods=req.days_ahead)
    forecast = model.predict(future)

    # 3. Extraer valores del periodo futuro
    future_rows = forecast.tail(req.days_ahead)
    predicted_total = max(0, future_rows["yhat"].sum())
    predicted_avg   = predicted_total / req.days_ahead
    conf_low        = max(0, future_rows["yhat_lower"].sum())
    conf_high       = future_rows["yhat_upper"].sum()

    # 4. Dirección de tendencia
    last_30 = forecast.iloc[-req.days_ahead-30:-req.days_ahead]["yhat"].mean()
    trend_pct = ((predicted_avg - last_30) / last_30 * 100) if last_30 > 0 else 0
    trend_direction = "UP" if trend_pct > 10 else ("DOWN" if trend_pct < -10 else "STABLE")

    # 5. Día pico de estacionalidad (para info al usuario)
    weekly = model.seasonalities.get("weekly", {})
    peak_day = _get_peak_weekday(forecast)

    return ForecastResponse(
        item_id=req.item_id,
        predicted_demand_total=round(predicted_total, 2),
        predicted_daily_avg=round(predicted_avg, 4),
        confidence_low=round(conf_low, 2),
        confidence_high=round(conf_high, 2),
        trend_direction=trend_direction,
        trend_pct=round(trend_pct, 1),
        seasonality_peak_day=peak_day,
        model_used="prophet",
        data_points=len(df)
    )
```

### `models/db.py` — Consulta al PostgreSQL real
```python
import asyncpg
import pandas as pd
import os

DATABASE_URL = os.getenv("DATABASE_URL")  # postgresql://user:pass@host:5432/db

async def get_sales_history(item_id: int, business_unit_id: int, days: int) -> pd.DataFrame:
    conn = await asyncpg.connect(DATABASE_URL)
    rows = await conn.fetch("""
        SELECT
            DATE(iw.effective_date) AS date,
            SUM(ABS(iw.quantity))   AS qty
        FROM inventory.item_in_warehouses iw
        JOIN inventory.warehouses w ON w.id = iw.warehouse_id
        WHERE w.business_units_id = $1
          AND iw.item_id           = $2
          AND iw.quantity          < 0
          AND iw.order_id          IS NOT NULL   -- solo consumo real de órdenes
          AND iw.effective_date    >= CURRENT_DATE - $3
        GROUP BY DATE(iw.effective_date)
        ORDER BY date ASC
    """, business_unit_id, item_id, days)
    await conn.close()
    return pd.DataFrame(rows, columns=["date", "qty"])
```

---

## 5. Módulo 2: Detección de Anomalías (Isolation Forest)

### Para qué sirve
Antes de calcular el WMA/Prophet, detectar si hay registros anómalos en el historial (eventos puntuales, errores de entrada, robo) que distorsionen la predicción.

### `routers/anomalies.py`
```python
from fastapi import APIRouter
from sklearn.ensemble import IsolationForest
import numpy as np

router = APIRouter(prefix="/anomalies", tags=["anomalies"])

class AnomalyRequest(BaseModel):
    item_id: int
    business_unit_id: int
    contamination: float = 0.05    # asumir 5% de datos anómalos

class AnomalyResponse(BaseModel):
    item_id: int
    anomaly_dates: List[str]        # fechas detectadas como anómalas
    anomaly_score: float            # 0-1, qué tan limpio está el historial
    recommendation: str             # "CLEAN" | "HAS_OUTLIERS" | "UNRELIABLE"

@router.post("/", response_model=AnomalyResponse)
async def detect_anomalies(req: AnomalyRequest):
    df = await get_sales_history(req.item_id, req.business_unit_id, days=90)

    if len(df) < 10:
        return AnomalyResponse(
            item_id=req.item_id,
            anomaly_dates=[],
            anomaly_score=1.0,
            recommendation="INSUFFICIENT_DATA"
        )

    X = df["qty"].values.reshape(-1, 1)
    clf = IsolationForest(contamination=req.contamination, random_state=42)
    preds = clf.fit_predict(X)    # -1 = anomalía, 1 = normal

    anomaly_idx = np.where(preds == -1)[0]
    anomaly_dates = df.iloc[anomaly_idx]["date"].astype(str).tolist()

    score = 1.0 - (len(anomaly_dates) / len(df))
    recommendation = (
        "CLEAN" if score > 0.95
        else "HAS_OUTLIERS" if score > 0.80
        else "UNRELIABLE"
    )

    return AnomalyResponse(
        item_id=req.item_id,
        anomaly_dates=anomaly_dates,
        anomaly_score=round(score, 3),
        recommendation=recommendation
    )
```

---

## 6. Módulo 3: Explicabilidad con LLM (GPT-4o mini)

### El mayor ROI práctico — Bajo costo, alto impacto UX
Costo estimado: **~$0.001 por sugerencia** con GPT-4o mini.  
Para 107 sugerencias = ~$0.11 por generación completa.

### `routers/explain.py`
```python
from fastapi import APIRouter
from openai import AsyncOpenAI
import os

router = APIRouter(prefix="/explain", tags=["explain"])
client = AsyncOpenAI(api_key=os.getenv("OPENAI_API_KEY"))

class ExplainRequest(BaseModel):
    suggestions: List[dict]    # batch de sugerencias a explicar

class ExplainResponse(BaseModel):
    results: List[dict]        # [{item_id, reason_es}]

SYSTEM_PROMPT = """
Eres el asistente de compras de un restaurante dominicano.
Tu trabajo es explicar en 1-2 oraciones cortas, en español informal,
por qué se debe comprar un ítem ahora.
Sé específico con los números. Menciona la urgencia si aplica.
NO uses tecnicismos. NO uses puntos al final.
"""

@router.post("/", response_model=ExplainResponse)
async def explain_batch(req: ExplainRequest):
    results = []

    for s in req.suggestions:
        user_msg = f"""
Ítem: {s['item_name']}
Stock actual: {s['current_stock']} {s.get('unit_of_measure', 'unidades')}
Stock mínimo: {s['min_level']}
Días hasta ruptura: {s['estimated_stockout_days']}
Consumo diario promedio: {round(s['daily_consumption'], 1)}
Tendencia 7 días: {s.get('trend_direction', 'STABLE')} ({s.get('trend_pct', 0):+.0f}%)
Proveedor sugerido: {s['suggested_supplier_name']}
Precio por unidad: RD${s['suggested_price']:,.2f}
Cantidad sugerida: {s['suggested_quantity']} unidades
Urgencia: {s['urgency_text']}
"""
        response = await client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_msg}
            ],
            max_tokens=120,
            temperature=0.3
        )
        reason = response.choices[0].message.content.strip()
        results.append({"item_id": s["item_id"], "reason_es": reason})

    return ExplainResponse(results=results)
```

### Ejemplo de salida del LLM
**Antes (hardcodeado):**
```
"Stock bajo del umbral mínimo, se requiere reposición"
```

**Después (LLM):**
```
"Barceló Blanco tiene solo 3 botellas — con el consumo actual de fin 
de semana se acaba en 2 días. La tendencia está subiendo 35% esta semana"
```

---

## 7. Integración en Node.js (`generate-suggestions.ts`)

### Cambios en el flujo actual

```typescript
// server/api/restaurant/shop/generate-suggestions.ts
// NUEVO: llamar al microservicio Python después del SQL

const PYTHON_SERVICE_URL = process.env.PYTHON_AI_SERVICE_URL || 'http://localhost:8001'

export default defineEventHandler(async (event) => {
  // ... código actual sin cambios hasta resultRows ...

  // ✅ NUEVO PASO 3.5: Enriquecer con Python AI (opcional, no bloquea si falla)
  let aiEnrichedRows = resultRows
  try {
    // a) Detección de anomalías (batch)
    const anomalyRes = await $fetch(`${PYTHON_SERVICE_URL}/anomalies/batch`, {
      method: 'POST',
      body: { items: resultRows.map(r => ({ item_id: r.item_id, business_unit_id })) }
    })

    // b) Forecast mejorado (solo para ítems críticos para no sobrecargar)
    const criticalItems = resultRows.filter(r => r.urgency_level <= 2)
    const forecastRes = await $fetch(`${PYTHON_SERVICE_URL}/forecast/batch`, {
      method: 'POST',
      body: {
        items: criticalItems.map(r => ({
          item_id: r.item_id, business_unit_id, location_id, days_ahead: 14
        }))
      }
    })

    // c) LLM explanations (batch, todos los ítems)
    const explainRes = await $fetch(`${PYTHON_SERVICE_URL}/explain`, {
      method: 'POST',
      body: {
        suggestions: resultRows.map(r => ({
          item_id: r.item_id,
          item_name: r.item_name,
          current_stock: r.current_stock,
          min_level: r.min_level,
          estimated_stockout_days: r.estimated_stockout_days,
          daily_consumption: r.suggested_quantity / 14,
          trend_direction: r.anomaly_flags?.includes('TREND_UP') ? 'UP' : 'STABLE',
          trend_pct: 0,
          suggested_supplier_name: r.suggested_supplier_name,
          suggested_price: r.suggested_price,
          suggested_quantity: r.suggested_quantity,
          urgency_text: r.urgency_level <= 2 ? 'Crítico' : r.urgency_level === 3 ? 'Alto' : 'Medio',
          unit_of_measure: 'unidades'
        }))
      }
    })

    // Merge de los resultados AI en las filas
    const forecastMap = Object.fromEntries(
      (forecastRes as any).results?.map((f: any) => [f.item_id, f]) ?? []
    )
    const explainMap = Object.fromEntries(
      (explainRes as any).results?.map((e: any) => [e.item_id, e]) ?? []
    )

    aiEnrichedRows = resultRows.map(r => ({
      ...r,
      // Reemplazar reason con explicación LLM si está disponible
      recommendation: explainMap[r.item_id]?.reason_es || r.recommendation,
      // Agregar datos del forecast
      ai_forecast: forecastMap[r.item_id] ? {
        predicted_14d: forecastMap[r.item_id].predicted_demand_total,
        confidence_low: forecastMap[r.item_id].confidence_low,
        confidence_high: forecastMap[r.item_id].confidence_high,
        trend_direction: forecastMap[r.item_id].trend_direction,
        peak_day: forecastMap[r.item_id].seasonality_peak_day,
      } : null,
    }))
  } catch (aiError) {
    // ⚠️ El microservicio Python es OPCIONAL — si falla, seguir con los resultados SQL
    console.warn('[GENERATE] Python AI service unavailable, using SQL-only results:', aiError)
  }

  // ... resto del código actual sin cambios ...
  return { success: true, data: { suggestions: aiEnrichedRows, ... } }
})
```

---

## 8. Nuevos campos en `auto_purchase_suggestions` (migración SQL)

```sql
-- docs/shop/ai-enrichment-migration.sql
-- Agregar columnas para datos del microservicio AI

ALTER TABLE inventory.auto_purchase_suggestions
  ADD COLUMN IF NOT EXISTS ai_predicted_demand   NUMERIC,
  ADD COLUMN IF NOT EXISTS ai_confidence_low     NUMERIC,
  ADD COLUMN IF NOT EXISTS ai_confidence_high    NUMERIC,
  ADD COLUMN IF NOT EXISTS ai_trend_direction    TEXT,     -- 'UP' | 'DOWN' | 'STABLE'
  ADD COLUMN IF NOT EXISTS ai_peak_day           TEXT,     -- 'FRIDAY' | 'SATURDAY' etc.
  ADD COLUMN IF NOT EXISTS ai_reason             TEXT,     -- LLM explanation in Spanish
  ADD COLUMN IF NOT EXISTS ai_anomaly_score      NUMERIC,  -- 0-1, calidad del historial
  ADD COLUMN IF NOT EXISTS ai_enriched_at        TIMESTAMPTZ;

COMMENT ON COLUMN inventory.auto_purchase_suggestions.ai_predicted_demand
  IS 'Prophet/XGBoost predicted demand for next 14 days';
COMMENT ON COLUMN inventory.auto_purchase_suggestions.ai_reason
  IS 'LLM-generated explanation in Spanish for why this item needs to be ordered';
```

---

## 9. Frontend — Nuevos campos en las cards de sugerencias

### En `SmartSuggestion` interface (Create.vue / shop/index.vue)
```typescript
interface SmartSuggestion {
  // ... campos actuales ...

  // Nuevos campos AI
  ai_forecast?: {
    predicted_14d: number
    confidence_low: number
    confidence_high: number
    trend_direction: 'UP' | 'DOWN' | 'STABLE'
    peak_day: string           // "VIERNES" | "SÁBADO" etc.
  }
  ai_anomaly_score?: number    // 0-1
  ai_reason?: string           // LLM explanation (reemplaza `recommendation`)
}
```

### Nuevos elementos UI en las cards
```vue
<!-- Chip de tendencia AI (reemplaza solo el trend_factor numérico actual) -->
<v-chip v-if="suggestion.ai_forecast?.trend_direction === 'UP'"
  color="error" size="x-small" variant="tonal" prepend-icon="mdi-trending-up">
  +{{ suggestion.ai_forecast.trend_pct }}% tendencia
</v-chip>

<!-- Reason con LLM (reemplaza string hardcodeado) -->
<div v-if="suggestion.ai_reason || suggestion.recommendation"
  class="text-caption text-grey-darken-2 mt-1 font-italic">
  "{{ suggestion.ai_reason || suggestion.recommendation }}"
</div>

<!-- Intervalo de confianza del forecast -->
<div v-if="suggestion.ai_forecast" class="text-caption text-grey">
  Predicción 14d: {{ suggestion.ai_forecast.confidence_low.toFixed(0) }}–
  {{ suggestion.ai_forecast.confidence_high.toFixed(0) }} unidades
</div>
```

---

## 10. Dockerfile del microservicio

```dockerfile
# services/purchasing-ai/Dockerfile
FROM python:3.11-slim

WORKDIR /app

# Dependencias del sistema para Prophet/psycopg2
RUN apt-get update && apt-get install -y \
    gcc g++ libpq-dev python3-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8001

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001", "--workers", "2"]
```

### `docker-compose.yml` (agregar al proyecto)
```yaml
# Agregar a docker-compose.yml existente o crear nuevo:
services:
  purchasing-ai:
    build: ./services/purchasing-ai
    ports:
      - "8001:8001"
    environment:
      - DATABASE_URL=${DATABASE_URL}
      - OPENAI_API_KEY=${OPENAI_API_KEY}
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8001/health"]
      interval: 30s
      timeout: 10s
      retries: 3
```

---

## 11. Variables de entorno necesarias

```env
# Agregar al .env del proyecto Nuxt
PYTHON_AI_SERVICE_URL=http://localhost:8001

# Agregar al .env del microservicio Python
DATABASE_URL=postgresql://usuario:password@host:5432/nombre_db
OPENAI_API_KEY=sk-...        # Para LLM explanations (opcional)
REDIS_URL=redis://localhost:6379  # Para cache de modelos (opcional)
```

---

## 12. Plan de Implementación por Fases

### FASE 1 — Estructura base del microservicio (1-2 días)
- [ ] Crear `services/purchasing-ai/` con estructura de carpetas
- [ ] `main.py` + `requirements.txt` + `Dockerfile`
- [ ] `models/db.py` con conexión al PostgreSQL existente
- [ ] Endpoint `/health` funcionando
- [ ] Verificar conexión desde Node.js

### FASE 2 — Forecast con Prophet (2-3 días)
- [ ] `routers/forecast.py` con Prophet
- [ ] Agregar feriados dominicanos (`country_name="DO"`)
- [ ] Endpoint `/forecast` probado con items reales
- [ ] Integrar en `generate-suggestions.ts` (solo para críticos)
- [ ] Comparar predicción Prophet vs. WMA actual con datos históricos

### FASE 3 — Detección de anomalías (1 día)
- [ ] `routers/anomalies.py` con Isolation Forest
- [ ] Filtrar outliers ANTES de enviar datos a Prophet
- [ ] Agregar `ai_anomaly_score` en las sugerencias generadas

### FASE 4 — LLM Explanations (1 día)
- [ ] `routers/explain.py` con OpenAI GPT-4o mini
- [ ] Prompt tuneado para restaurante dominicano
- [ ] Batch processing para las 107 sugerencias
- [ ] Mostrar `ai_reason` en cards (reemplaza `recommendation` hardcodeado)

### FASE 5 — Optimización (continuo)
- [ ] Cache de modelos Prophet entrenados en Redis (evitar re-entrenar cada vez)
- [ ] Modelo XGBoost como alternativa para ítems con >1 año de datos
- [ ] Dashboard de accuracy: comparar Prophet prediction vs. consumo real

---

## 13. Decisión clave — ¿Reemplazar o complementar el SQL?

**Respuesta: COMPLEMENTAR, no reemplazar.**

La función SQL `fn_intelligent_purchasing_v2` sigue siendo el núcleo:
- Es **transaccional** — escribe directamente en `auto_purchase_suggestions`
- Es **rápida** — corre en <2 segundos para 924 ítems
- Es **confiable** — ya probada en producción con feedback loop

Python **complementa** con lo que SQL no puede hacer bien:
- Estacionalidad anual (Prophet)
- Explicaciones en lenguaje natural (LLM)
- Detección de outliers estadísticos (Isolation Forest)

**El SQL calcula CUÁNTO comprar. Python mejora CUÁNDO y explica POR QUÉ.**

---

## 14. Costo estimado en producción

| Servicio | Uso | Costo mensual est. |
|---------|-----|-------------------|
| OpenAI GPT-4o mini | 107 items × 30 generaciones/mes | ~$3-5/mes |
| Servidor Python (VPS) | 512MB RAM es suficiente | $5-10/mes |
| Redis cache (modelos) | Opcional | $0 (memory) |
| **Total adicional** | | **~$8-15/mes** |

---

*Documento creado: Marzo 2026*  
*Función SQL base: `inventory.fn_intelligent_purchasing_v2` (v4)*  
*Stack: Nuxt 4 + PostgreSQL + Python FastAPI + Prophet + OpenAI*
