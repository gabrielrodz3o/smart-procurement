import asyncio
from fastapi import APIRouter
from pydantic import BaseModel
from typing import List, Optional

from models.db import run_intelligent_purchasing, get_connection
from models.schemas import (
    ForecastRequest, SuggestionInput, ExplainRequest,
    AnomalyRequest,
)
from routers.forecast import _forecast_single
from routers.anomalies import _detect_single
from routers.explain import explain_batch

router = APIRouter(prefix="/generate", tags=["generate"])


class GenerateRequest(BaseModel):
    business_unit_id: int
    location_id: int
    urgency_threshold: int = 5          # 1=only critical … 5=all
    days_ahead: int = 14                # forecast horizon
    lookback_days: int = 180            # history window for Prophet


class SuggestionOut(BaseModel):
    suggestion_id:          Optional[int]
    item_id:                int
    item_name:              str
    warehouse_name:         str
    location_name:          str
    current_stock:          float
    min_level:              float
    max_level:              float
    reorder_point:          float
    safety_stock:           float
    suggested_quantity:     float
    optimal_order_qty:      float
    estimated_stockout_days: int
    estimated_cost:         float
    urgency_level:          int
    abc_class:              str
    xyz_class:              str
    suggested_supplier:     str
    suggested_supplier_id:  Optional[int]
    suggested_price:        float
    action_taken:           str
    recommendation:         str         # SQL text (overwritten by ai_reason if available)
    anomaly_flags:          List[str]
    delivery_window:        str
    trend_factor:           float
    weekday_factor:         float
    correction_factor:      float
    # ── AI enrichment ──────────────────────────────────────────
    ai_reason:              Optional[str]   # GPT-4o mini explanation
    ai_predicted_demand:    Optional[float] # Prophet 14d total
    ai_confidence_low:      Optional[float]
    ai_confidence_high:     Optional[float]
    ai_trend_direction:     Optional[str]   # UP | DOWN | STABLE
    ai_peak_day:            Optional[str]   # FRIDAY etc.
    ai_model_used:          Optional[str]   # prophet | fallback_wma
    ai_anomaly_score:       Optional[float] # Isolation Forest score
    ai_anomaly_status:      Optional[str]   # CLEAN | HAS_OUTLIERS | UNRELIABLE


class GenerateResponse(BaseModel):
    business_unit_id:   int
    location_id:        int
    total_suggestions:  int
    suggestions:        List[SuggestionOut]


@router.post("", response_model=GenerateResponse)
async def generate_suggestions(req: GenerateRequest):

    # ── 1. Run the SQL intelligence function ────────────────────────────────
    raw_rows = await run_intelligent_purchasing(
        business_unit_id=req.business_unit_id,
        location_id=req.location_id,
        urgency_threshold=req.urgency_threshold,
    )

    if not raw_rows:
        return GenerateResponse(
            business_unit_id=req.business_unit_id,
            location_id=req.location_id,
            total_suggestions=0,
            suggestions=[],
        )

    # ── 2. Forecast + Anomaly detection in parallel (one task per item) ─────
    forecast_reqs = [
        ForecastRequest(
            item_id=r["out_item_id"],
            business_unit_id=req.business_unit_id,
            location_id=req.location_id,
            days_ahead=req.days_ahead,
            lookback_days=req.lookback_days,
        )
        for r in raw_rows
    ]
    anomaly_reqs = [
        AnomalyRequest(
            item_id=r["out_item_id"],
            business_unit_id=req.business_unit_id,
            lookback_days=90,
            contamination=0.05,
        )
        for r in raw_rows
    ]

    forecast_tasks = [_forecast_single(fr) for fr in forecast_reqs]
    anomaly_tasks  = [_detect_single(ar) for ar in anomaly_reqs]

    forecast_results, anomaly_results = await asyncio.gather(
        asyncio.gather(*forecast_tasks, return_exceptions=True),
        asyncio.gather(*anomaly_tasks,  return_exceptions=True),
    )

    forecast_map = {}
    for item_id, outcome in zip([r["out_item_id"] for r in raw_rows], forecast_results):
        if not isinstance(outcome, Exception):
            forecast_map[item_id] = outcome

    anomaly_map = {}
    for item_id, outcome in zip([r["out_item_id"] for r in raw_rows], anomaly_results):
        if not isinstance(outcome, Exception):
            anomaly_map[item_id] = outcome

    # ── 3. LLM explanations — batch, parallel ───────────────────────────────
    explain_inputs = [
        SuggestionInput(
            item_id=r["out_item_id"],
            item_name=r["out_item_name"],
            current_stock=float(r["out_current_stock"] or 0),
            min_level=float(r["out_min_level"] or 0),
            estimated_stockout_days=int(r["out_estimated_stockout_days"] or 0),
            daily_consumption=(
                float(r["out_suggested_quantity"] or 0) / req.days_ahead
            ),
            suggested_quantity=float(r["out_suggested_quantity"] or 0),
            suggested_price=float(r["out_suggested_price"] or 0),
            suggested_supplier_name=r["out_suggested_supplier"] or "",
            urgency_level=int(r["out_urgency_level"] or 3),
            trend_direction=forecast_map.get(r["out_item_id"], None) and
                            forecast_map[r["out_item_id"]].trend_direction or "STABLE",
            trend_pct=forecast_map.get(r["out_item_id"], None) and
                      forecast_map[r["out_item_id"]].trend_pct or 0.0,
            abc_class=r["out_abc_class"] or "C",
        )
        for r in raw_rows
    ]

    explain_req = ExplainRequest(
        business_unit_id=req.business_unit_id,
        location_id=req.location_id,
        suggestions=explain_inputs,
    )
    explain_resp = await explain_batch(explain_req)
    explain_map = {e.item_id: e.reason_es for e in explain_resp.results}

    # ── 4. Merge everything ─────────────────────────────────────────────────
    suggestions = []
    for r in raw_rows:
        iid       = r["out_item_id"]
        forecast  = forecast_map.get(iid)
        anomaly   = anomaly_map.get(iid)
        ai_reason = explain_map.get(iid)

        suggestions.append(SuggestionOut(
            suggestion_id=r["out_suggestion_id"],
            item_id=iid,
            item_name=r["out_item_name"],
            warehouse_name=r["out_warehouse_name"] or "",
            location_name=r["out_location_name"] or "",
            current_stock=float(r["out_current_stock"] or 0),
            min_level=float(r["out_min_level"] or 0),
            max_level=float(r["out_max_level"] or 0),
            reorder_point=float(r["out_reorder_point"] or 0),
            safety_stock=float(r["out_safety_stock"] or 0),
            suggested_quantity=float(r["out_suggested_quantity"] or 0),
            optimal_order_qty=float(r["out_optimal_order_qty"] or 0),
            estimated_stockout_days=int(r["out_estimated_stockout_days"] or 0),
            estimated_cost=float(r["out_estimated_cost"] or 0),
            urgency_level=int(r["out_urgency_level"] or 3),
            abc_class=r["out_abc_class"] or "",
            xyz_class=r["out_xyz_class"] or "",
            suggested_supplier=r["out_suggested_supplier"] or "",
            suggested_supplier_id=r["out_suggested_supplier_id"],
            suggested_price=float(r["out_suggested_price"] or 0),
            action_taken=r["out_action_taken"] or "",
            recommendation=ai_reason or r["out_recommendation"] or "",
            anomaly_flags=list(r["out_anomaly_flags"] or []),
            delivery_window=r["out_delivery_window"] or "",
            trend_factor=float(r["out_trend_factor"] or 1.0),
            weekday_factor=float(r["out_weekday_factor"] or 1.0),
            correction_factor=float(r["out_correction_factor"] or 1.0),
            # AI enrichment
            ai_reason=ai_reason,
            ai_predicted_demand=forecast.predicted_demand_total if forecast else None,
            ai_confidence_low=forecast.confidence_low if forecast else None,
            ai_confidence_high=forecast.confidence_high if forecast else None,
            ai_trend_direction=forecast.trend_direction if forecast else None,
            ai_peak_day=forecast.peak_day if forecast else None,
            ai_model_used=forecast.model_used if forecast else None,
            ai_anomaly_score=anomaly.anomaly_score if anomaly else None,
            ai_anomaly_status=anomaly.recommendation if anomaly else None,
        ))

    # Sort by urgency asc, then estimated_cost desc
    suggestions.sort(key=lambda s: (s.urgency_level, -s.estimated_cost))

    # ── 5. Persist ai_* back to auto_purchase_suggestions ───────────────────
    try:
        conn = await get_connection()
        try:
            await conn.executemany(
                """
                UPDATE inventory.auto_purchase_suggestions
                   SET ai_predicted_demand  = $1,
                       ai_confidence_low    = $2,
                       ai_confidence_high   = $3,
                       ai_trend_direction   = $4,
                       ai_peak_day          = $5,
                       ai_reason            = $6,
                       ai_anomaly_score     = $7,
                       ai_model_used        = $8,
                       ai_enriched_at       = NOW()
                 WHERE id = $9
                """,
                [
                    (
                        s.ai_predicted_demand,
                        s.ai_confidence_low,
                        s.ai_confidence_high,
                        s.ai_trend_direction,
                        s.ai_peak_day,
                        s.ai_reason,
                        s.ai_anomaly_score,
                        s.ai_model_used,
                        s.suggestion_id,
                    )
                    for s in suggestions
                    if s.suggestion_id is not None
                ],
            )
        finally:
            await conn.close()
    except Exception as e:
        print(f"[generate] Warning: could not persist ai_* fields: {e}")

    return GenerateResponse(
        business_unit_id=req.business_unit_id,
        location_id=req.location_id,
        total_suggestions=len(suggestions),
        suggestions=suggestions,
    )
