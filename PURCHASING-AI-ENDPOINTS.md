# Purchasing AI — Referencia completa de endpoints

**Base URL:** `http://localhost:8001`  
**Docs interactivos:** `http://localhost:8001/docs`

---

## Resumen de endpoints

| Método | Ruta | Descripción |
|--------|------|-------------|
| GET | `/health` | Estado del servicio y BD |
| POST | `/generate` | ⭐ Principal: SQL + Prophet + GPT-4o mini todo junto |
| POST | `/forecast` | Forecast de demanda individual (Prophet / WMA) |
| POST | `/forecast/batch` | Forecast para múltiples ítems |
| POST | `/anomalies` | Detección de anomalías individual (Isolation Forest) |
| POST | `/anomalies/batch` | Detección de anomalías múltiples ítems |
| POST | `/explain` | Explicación LLM en español (GPT-4o mini) |
| POST | `/supplier-rank` | Ranking de proveedores por precio, lead time y puntualidad |

---

## GET `/health`

Verifica que el servicio esté corriendo y conectado a la BD.

**Response `200`:**
```json
{
  "status": "ok",
  "db_connected": true,
  "models_loaded": ["prophet", "isolation_forest"],
  "version": "1.0.0"
}
```

**curl:**
```bash
curl http://localhost:8001/health
```

---

## POST `/generate` ⭐

Endpoint principal. Ejecuta la función SQL `fn_intelligent_purchasing_v2`, luego enriquece automáticamente cada sugerencia con Prophet, Isolation Forest y GPT-4o mini. Persiste los campos `ai_*` en `auto_purchase_suggestions`.

**Request:**
```json
{
  "business_unit_id": 16,
  "location_id": 12,
  "urgency_threshold": 5,
  "days_ahead": 14,
  "lookback_days": 180
}
```

| Campo | Tipo | Default | Descripción |
|---|---|---|---|
| `business_unit_id` | int | requerido | ID del negocio |
| `location_id` | int | requerido | ID de la ubicación |
| `urgency_threshold` | int | `5` | 1 = solo críticos, 5 = todos |
| `days_ahead` | int | `14` | Horizonte de forecast Prophet |
| `lookback_days` | int | `180` | Días de historial para Prophet |

**Response `200`:**
```json
{
  "business_unit_id": 16,
  "location_id": 12,
  "total_suggestions": 107,
  "suggestions": [
    {
      "suggestion_id": 42,
      "item_id": 3106,
      "item_name": "COCA COLA REGULAR 16 ONZ",
      "warehouse_name": "BAR",
      "location_name": "T. PRINCIPAL",
      "current_stock": 159.4,
      "min_level": 100.0,
      "max_level": 125.0,
      "reorder_point": 221.76,
      "safety_stock": 85.18,
      "suggested_quantity": 1.0,
      "optimal_order_qty": 325.54,
      "estimated_stockout_days": 8,
      "estimated_cost": 26.88,
      "urgency_level": 4,
      "abc_class": "C",
      "xyz_class": "Y",
      "suggested_supplier": "BEPENSA DOMINICANA S A",
      "suggested_supplier_id": 231,
      "suggested_price": 26.88,
      "action_taken": "UPDATED",
      "recommendation": "Texto del SQL (sobrescrito por ai_reason)",
      "anomaly_flags": ["WMA:23.8/day", "WEEKDAY_FACTOR:×0.89", "TREND_FACTOR:×0.92"],
      "delivery_window": "NEXT_WEEK",
      "trend_factor": 0.92,
      "weekday_factor": 0.89,
      "correction_factor": 1.0,
      "ai_reason": "Debemos comprar una Coca Cola ahora porque estamos a solo 8 días de quedarnos sin stock...",
      "ai_predicted_demand": 42.5,
      "ai_confidence_low": 30.0,
      "ai_confidence_high": 55.0,
      "ai_trend_direction": "STABLE",
      "ai_peak_day": "FRIDAY",
      "ai_model_used": "prophet",
      "ai_anomaly_score": 0.944,
      "ai_anomaly_status": "HAS_OUTLIERS"
    }
  ]
}
```

| Campo AI | Descripción |
|---|---|
| `ai_reason` | Explicación en español generada por GPT-4o mini |
| `ai_predicted_demand` | Demanda total predicha por Prophet en `days_ahead` días |
| `ai_confidence_low` | Límite inferior del intervalo de confianza 80% |
| `ai_confidence_high` | Límite superior del intervalo de confianza 80% |
| `ai_trend_direction` | `UP` / `DOWN` / `STABLE` según Prophet |
| `ai_peak_day` | Día de mayor demanda (`FRIDAY`, `SATURDAY`, etc.) |
| `ai_model_used` | `prophet` (≥14 datos) o `fallback_wma` |
| `ai_anomaly_score` | Isolation Forest: 1.0 = historial limpio, <0.8 = no confiable |
| `ai_anomaly_status` | `CLEAN` / `HAS_OUTLIERS` / `UNRELIABLE` / `INSUFFICIENT_DATA` |

**`urgency_level`:**
| Valor | Significado | `delivery_window` |
|---|---|---|
| 1 | Crítico — stock 0, clase A | `IMMEDIATE` |
| 2 | Muy alto — stock 0 o safety stock clase A | `IMMEDIATE` |
| 3 | Alto — bajo safety stock | `THIS_WEEK` |
| 4 | Medio — bajo reorder point | `NEXT_WEEK` |
| 5 | Normal — preventivo | `MONTHLY` |

**curl:**
```bash
curl -s -X POST http://localhost:8001/generate \
  -H "Content-Type: application/json" \
  -d '{
    "business_unit_id": 16,
    "location_id": 12,
    "urgency_threshold": 5,
    "days_ahead": 14,
    "lookback_days": 180
  }' | python3 -m json.tool
```

---

## POST `/forecast`

Forecast de demanda para un ítem individual. Usa Prophet si hay ≥14 días de historial, si no usa Weighted Moving Average.

**Request:**
```json
{
  "business_unit_id": 16,
  "location_id": 12,
  "item_id": 345,
  "days_ahead": 14,
  "lookback_days": 180
}
```

**Response `200`:**
```json
{
  "item_id": 345,
  "predicted_demand_total": 42.5,
  "predicted_daily_avg": 3.04,
  "confidence_low": 30.0,
  "confidence_high": 55.0,
  "trend_direction": "UP",
  "trend_pct": 18.5,
  "peak_day": "FRIDAY",
  "model_used": "prophet",
  "data_points": 87
}
```

**curl:**
```bash
curl -s -X POST http://localhost:8001/forecast \
  -H "Content-Type: application/json" \
  -d '{
    "business_unit_id": 16,
    "location_id": 12,
    "item_id": 345,
    "days_ahead": 14,
    "lookback_days": 180
  }' | python3 -m json.tool
```

---

## POST `/forecast/batch`

Forecast para múltiples ítems en paralelo.

**Request:**
```json
{
  "business_unit_id": 16,
  "location_id": 12,
  "days_ahead": 14,
  "lookback_days": 180,
  "item_ids": [345, 346, 789, 1024]
}
```

**Response `200`:**
```json
{
  "results": [
    {
      "item_id": 345,
      "predicted_demand_total": 42.5,
      "predicted_daily_avg": 3.04,
      "confidence_low": 30.0,
      "confidence_high": 55.0,
      "trend_direction": "UP",
      "trend_pct": 18.5,
      "peak_day": "FRIDAY",
      "model_used": "prophet",
      "data_points": 87
    }
  ],
  "processed": 3,
  "failed": 1
}
```

**curl:**
```bash
curl -s -X POST http://localhost:8001/forecast/batch \
  -H "Content-Type: application/json" \
  -d '{
    "business_unit_id": 16,
    "location_id": 12,
    "days_ahead": 14,
    "item_ids": [345, 346, 789]
  }' | python3 -m json.tool
```

---

## POST `/anomalies`

Detección de outliers en el historial de ventas de un ítem usando Isolation Forest.

**Request:**
```json
{
  "business_unit_id": 16,
  "item_id": 345,
  "lookback_days": 90,
  "contamination": 0.05
}
```

| Campo | Tipo | Default | Descripción |
|---|---|---|---|
| `lookback_days` | int | `90` | Días de historial a analizar |
| `contamination` | float | `0.05` | Proporción esperada de anomalías (0.01–0.50) |

**Response `200`:**
```json
{
  "item_id": 345,
  "anomaly_dates": ["2025-12-24", "2026-01-01"],
  "anomaly_score": 0.944,
  "recommendation": "HAS_OUTLIERS"
}
```

| `recommendation` | Condición |
|---|---|
| `CLEAN` | Score > 0.95 — historial confiable |
| `HAS_OUTLIERS` | Score 0.80–0.95 — usar con precaución |
| `UNRELIABLE` | Score < 0.80 — historial muy ruidoso |
| `INSUFFICIENT_DATA` | Menos de 10 días de datos |

**curl:**
```bash
curl -s -X POST http://localhost:8001/anomalies \
  -H "Content-Type: application/json" \
  -d '{
    "business_unit_id": 16,
    "item_id": 345,
    "lookback_days": 90,
    "contamination": 0.05
  }' | python3 -m json.tool
```

---

## POST `/anomalies/batch`

Detección de anomalías para múltiples ítems en paralelo.

**Request:**
```json
{
  "items": [
    { "business_unit_id": 16, "item_id": 345, "lookback_days": 90, "contamination": 0.05 },
    { "business_unit_id": 16, "item_id": 346, "lookback_days": 90, "contamination": 0.05 }
  ]
}
```

**Response `200`:**
```json
{
  "results": [
    { "item_id": 345, "anomaly_dates": [], "anomaly_score": 0.98, "recommendation": "CLEAN" },
    { "item_id": 346, "anomaly_dates": ["2025-12-31"], "anomaly_score": 0.91, "recommendation": "HAS_OUTLIERS" }
  ]
}
```

**curl:**
```bash
curl -s -X POST http://localhost:8001/anomalies/batch \
  -H "Content-Type: application/json" \
  -d '{
    "items": [
      { "business_unit_id": 16, "item_id": 345, "lookback_days": 90 },
      { "business_unit_id": 16, "item_id": 346, "lookback_days": 90 }
    ]
  }' | python3 -m json.tool
```

---

## POST `/explain`

Genera explicaciones en español informal usando GPT-4o mini. Procesa todas las sugerencias en paralelo (~2-3s para 100 ítems).

**Request:**
```json
{
  "business_unit_id": 16,
  "location_id": 12,
  "suggestions": [
    {
      "item_id": 345,
      "item_name": "BARCELÓ BLANCO 700ML",
      "current_stock": 3,
      "min_level": 6,
      "estimated_stockout_days": 2,
      "daily_consumption": 1.5,
      "suggested_quantity": 12,
      "suggested_price": 4200.00,
      "suggested_supplier_name": "DISTRIBUIDORA CENTRAL",
      "urgency_level": 1,
      "trend_direction": "UP",
      "trend_pct": 35.0,
      "abc_class": "A",
      "unit_of_measure": "unidades"
    }
  ]
}
```

| Campo de suggestion | Tipo | Default | Descripción |
|---|---|---|---|
| `item_id` | int | requerido | |
| `item_name` | str | requerido | |
| `current_stock` | float | requerido | |
| `min_level` | float | requerido | |
| `estimated_stockout_days` | int | requerido | |
| `daily_consumption` | float | requerido | |
| `suggested_quantity` | float | requerido | |
| `suggested_price` | float | `0.0` | |
| `suggested_supplier_name` | str | `""` | |
| `urgency_level` | int | `3` | 1=Crítico … 5=Normal |
| `trend_direction` | str | `"STABLE"` | `UP` / `DOWN` / `STABLE` |
| `trend_pct` | float | `0.0` | % de cambio en tendencia |
| `abc_class` | str | `"C"` | `A` / `B` / `C` |
| `unit_of_measure` | str | `"unidades"` | |

**Response `200`:**
```json
{
  "results": [
    {
      "item_id": 345,
      "reason_es": "Hay que comprar el Barceló Blanco ya que solo quedan 3 botellas y en 2 días nos quedamos sin stock..."
    }
  ]
}
```

> Si `OPENAI_API_KEY` no está configurada, devuelve un fallback en español basado en los datos numéricos.

**curl:**
```bash
curl -s -X POST http://localhost:8001/explain \
  -H "Content-Type: application/json" \
  -d '{
    "business_unit_id": 16,
    "location_id": 12,
    "suggestions": [
      {
        "item_id": 345,
        "item_name": "BARCELÓ BLANCO 700ML",
        "current_stock": 3,
        "min_level": 6,
        "estimated_stockout_days": 2,
        "daily_consumption": 1.5,
        "suggested_quantity": 12,
        "suggested_price": 4200.00,
        "suggested_supplier_name": "DISTRIBUIDORA CENTRAL",
        "urgency_level": 1,
        "trend_direction": "UP",
        "trend_pct": 35.0,
        "abc_class": "A"
      }
    ]
  }' | python3 -m json.tool
```

---

## POST `/supplier-rank`

Rankea proveedores para un ítem por score compuesto: 60% precio + 25% lead time + 15% puntualidad de entrega (`on_time_pct` calculado desde `finances.invoices`).

**Request:**
```json
{
  "business_unit_id": 16,
  "location_id": 12,
  "item_id": 345,
  "required_quantity": 12.0,
  "candidate_supplier_ids": [12, 45, 78]
}
```

| Campo | Tipo | Default | Descripción |
|---|---|---|---|
| `item_id` | int | requerido | |
| `business_unit_id` | int | requerido | |
| `location_id` | int | `null` | Opcional |
| `required_quantity` | float | `1.0` | Cantidad requerida |
| `candidate_supplier_ids` | int[] | `null` | Si es null, evalúa todos los conocidos |

**Response `200`:**
```json
{
  "item_id": 345,
  "ranked": [
    {
      "supplier_id": 45,
      "supplier_name": "DISTRIBUIDORA CENTRAL",
      "score": 0.92,
      "avg_price": 4100.00,
      "avg_lead_days": 2,
      "on_time_pct": 0.95,
      "rank": 1
    },
    {
      "supplier_id": 12,
      "supplier_name": "CARVIS SRL",
      "score": 0.74,
      "avg_price": 4350.00,
      "avg_lead_days": 4,
      "on_time_pct": 0.81,
      "rank": 2
    }
  ]
}
```

| Campo | Descripción |
|---|---|
| `score` | 0.0–1.0, mayor = mejor proveedor |
| `avg_price` | Precio promedio histórico |
| `avg_lead_days` | Días de entrega promedio |
| `on_time_pct` | % de facturas entregadas a tiempo (de `finances.invoices`) |
| `rank` | 1 = mejor opción |

**curl:**
```bash
curl -s -X POST http://localhost:8001/supplier-rank \
  -H "Content-Type: application/json" \
  -d '{
    "business_unit_id": 16,
    "location_id": 12,
    "item_id": 345,
    "candidate_supplier_ids": [12, 45, 78]
  }' | python3 -m json.tool
```

---

## Correr el servicio

```bash
cd services/purchasing-ai
.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8001
# Con hot-reload para desarrollo:
.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8001 --reload
```

## Variables de entorno requeridas (`.env`)

```bash
DB_HOST=localhost
DB_PORT=6432
DB_USER=dev_gabriel
DB_PASSWORD=tu_password
DB_DATABASE=gcode
OPENAI_API_KEY=sk-...   # requerida para /explain y /generate
```
