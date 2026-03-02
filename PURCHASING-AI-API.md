# Purchasing AI — Guía de integración con Nuxt

Microservicio Python en `services/purchasing-ai/` corriendo en `http://localhost:8001`.

---

## Endpoint principal (el que usarás en Nuxt)

### `POST /generate`

Llama la función SQL `fn_intelligent_purchasing_v2`, enriquece con Prophet + Isolation Forest + GPT-4o mini, y persiste los campos `ai_*` en `auto_purchase_suggestions`.

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

| Parámetro | Tipo | Default | Descripción |
|---|---|---|---|
| `business_unit_id` | int | requerido | ID del negocio |
| `location_id` | int | requerido | ID de la ubicación |
| `urgency_threshold` | int | 5 | 1=solo críticos, 5=todos |
| `days_ahead` | int | 14 | Horizonte de forecast Prophet |
| `lookback_days` | int | 180 | Días de historial a usar |

**Response:**
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
      "suggested_quantity": 1.0,
      "estimated_cost": 26.88,
      "urgency_level": 4,
      "abc_class": "C",
      "xyz_class": "Y",
      "suggested_supplier": "BEPENSA DOMINICANA S A",
      "suggested_price": 26.88,
      "delivery_window": "NEXT_WEEK",
      "trend_factor": 0.92,
      "weekday_factor": 0.89,
      "correction_factor": 1.0,
      "anomaly_flags": ["WMA:23.8/day", "TREND_FACTOR:×0.92"],
      "recommendation": "Texto SQL original",
      "action_taken": "UPDATED",

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

---

## Integración en Nuxt 4

### 1. Variable de entorno

En tu `.env` del proyecto Nuxt:
```bash
PURCHASING_AI_URL=http://localhost:8001
# Producción: PURCHASING_AI_URL=http://purchasing-ai:8001
```

### 2. Server route — `server/api/purchasing/generate.post.ts`

```typescript
export default defineEventHandler(async (event) => {
  const body = await readBody(event)

  const response = await $fetch(`${process.env.PURCHASING_AI_URL}/generate`, {
    method: 'POST',
    body: {
      business_unit_id: body.businessUnitId,
      location_id:      body.locationId,
      urgency_threshold: body.urgencyThreshold ?? 5,
      days_ahead:        body.daysAhead        ?? 14,
      lookback_days:     body.lookbackDays      ?? 180,
    },
  })

  return response
})
```

### 3. Llamada desde el composable o página

```typescript
// composable: useSmartPurchasing.ts
export const useSmartPurchasing = () => {
  const generate = async (businessUnitId: number, locationId: number) => {
    return await $fetch('/api/purchasing/generate', {
      method: 'POST',
      body: { businessUnitId, locationId },
    })
  }
  return { generate }
}
```

```vue
<!-- pages/compras/sugerencias.vue -->
<script setup lang="ts">
const { generate } = useSmartPurchasing()
const { data, pending } = await useAsyncData('suggestions',
  () => generate(16, 12)
)
</script>

<template>
  <div v-for="s in data.suggestions" :key="s.item_id">
    <p>{{ s.item_name }} — urgency {{ s.urgency_level }}</p>
    <p class="text-sm text-gray-600">{{ s.ai_reason }}</p>
  </div>
</template>
```

---

## Otros endpoints (opcionales, para casos específicos)

### `GET /health` — status del servicio
```typescript
await $fetch(`${PURCHASING_AI_URL}/health`)
// { status: "ok", db_connected: true, models_loaded: ["prophet", "isolation_forest"], version: "1.0.0" }
```

### `POST /forecast` — forecast individual
```typescript
await $fetch(`${PURCHASING_AI_URL}/forecast`, {
  method: 'POST',
  body: { business_unit_id: 16, location_id: 12, item_id: 345, days_ahead: 14 }
})
```

### `POST /explain` — LLM reason para sugerencias ya calculadas
Útil si ya tienes sugerencias del SQL y solo quieres el `ai_reason`:
```typescript
await $fetch(`${PURCHASING_AI_URL}/explain`, {
  method: 'POST',
  body: {
    business_unit_id: 16,
    location_id: 12,
    suggestions: [
      {
        item_id: 345,
        item_name: "BARCELÓ BLANCO 700ML",
        current_stock: 3,
        min_level: 6,
        estimated_stockout_days: 2,
        daily_consumption: 1.5,
        suggested_quantity: 12,
        suggested_price: 4200.00,
        suggested_supplier_name: "DISTRIBUIDORA CENTRAL",
        urgency_level: 1,
        trend_direction: "UP",
        trend_pct: 35.0,
        abc_class: "A"
      }
    ]
  }
})
// { results: [{ item_id: 345, reason_es: "Barceló Blanco tiene solo 3 botellas..." }] }
```

### `POST /supplier-rank` — ranking de proveedores
```typescript
await $fetch(`${PURCHASING_AI_URL}/supplier-rank`, {
  method: 'POST',
  body: {
    business_unit_id: 16,
    location_id: 12,
    item_id: 345,
    candidate_supplier_ids: [12, 45, 78]   // opcional
  }
})
// { item_id: 345, ranked: [{ supplier_id: 45, score: 0.92, avg_price: 4100, avg_lead_days: 2, on_time_pct: 0.95 }] }
```

---

## Para producción (Docker)

El servicio ya tiene `Dockerfile` y `docker-compose.yml` en `services/purchasing-ai/`.

```bash
# Levantar con Docker
cd services/purchasing-ai
docker-compose up --build -d
```

En producción el `DB_HOST` cambia automáticamente a `pgbouncer` (ya configurado en `docker-compose.yml`).

---

## Flujo completo resumido

```
Nuxt POST /api/purchasing/generate
    └─► Python POST /generate
            ├─► SQL fn_intelligent_purchasing_v2  (crea/actualiza sugerencias en BD)
            ├─► Prophet/WMA forecast por ítem     (paralelo)
            ├─► Isolation Forest anomaly score    (paralelo)
            ├─► GPT-4o mini ai_reason en español  (paralelo, ~2-3s para 107 ítems)
            └─► UPDATE auto_purchase_suggestions  (persiste ai_* en BD)
                    └─► Devuelve JSON enriquecido a Nuxt
```
