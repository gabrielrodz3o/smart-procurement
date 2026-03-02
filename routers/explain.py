import os
import asyncio
from fastapi import APIRouter
from openai import AsyncOpenAI
from models.schemas import ExplainRequest, ExplainResponse, ExplainResult, SuggestionInput

router = APIRouter(prefix="/explain", tags=["explain"])

SYSTEM_PROMPT = """
Eres el asistente de compras de un restaurante dominicano.
Tu trabajo es explicar en 1-2 oraciones cortas, en español informal,
por qué se debe comprar un ítem ahora.
Sé específico con los números. Menciona la urgencia si aplica.
NO uses tecnicismos. NO uses puntos al final.
"""


@router.post("", response_model=ExplainResponse)
async def explain_batch(req: ExplainRequest):
    api_key = os.getenv("OPENAI_API_KEY", "")
    if not api_key or api_key.startswith("sk-..."):
        # Return sensible fallback if no key configured
        results = [
            ExplainResult(
                item_id=s.item_id,
                reason_es=(
                    f"{s.item_name} tiene stock bajo ({s.current_stock} unidades) "
                    f"y se agota en {s.estimated_stockout_days} días con el consumo actual"
                ),
            )
            for s in req.suggestions
        ]
        return ExplainResponse(results=results)

    client = AsyncOpenAI(api_key=api_key)

    URGENCY_LABELS = {1: "Crítico", 2: "Muy alto", 3: "Alto", 4: "Medio", 5: "Normal"}

    async def _explain_one(s: SuggestionInput) -> ExplainResult:
        urgency_text = URGENCY_LABELS.get(s.urgency_level, "Normal")
        user_msg = f"""
Ítem: {s.item_name} (Clase {s.abc_class})
Stock actual: {s.current_stock} {s.unit_of_measure}
Stock mínimo: {s.min_level}
Días hasta ruptura: {s.estimated_stockout_days}
Consumo diario promedio: {round(s.daily_consumption, 1)}
Tendencia 7 días: {s.trend_direction} ({s.trend_pct:+.0f}%)
Proveedor sugerido: {s.suggested_supplier_name}
Precio por unidad: RD${s.suggested_price:,.2f}
Cantidad sugerida: {s.suggested_quantity} unidades
Urgencia: {urgency_text}
"""
        try:
            response = await client.chat.completions.create(
                model="gpt-4o-mini",
                messages=[
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": user_msg},
                ],
                max_tokens=120,
                temperature=0.3,
            )
            reason = response.choices[0].message.content.strip()
        except Exception:
            reason = (
                f"{s.item_name} necesita reposición — quedan {s.current_stock} "
                f"{s.unit_of_measure} y se acaba en {s.estimated_stockout_days} días"
            )
        return ExplainResult(item_id=s.item_id, reason_es=reason)

    # Parallel calls — 107 items en ~2-3s en vez de 30-60s en serie
    results = await asyncio.gather(*[_explain_one(s) for s in req.suggestions])
    return ExplainResponse(results=list(results))
