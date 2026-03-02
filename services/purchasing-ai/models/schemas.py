from pydantic import BaseModel, Field
from typing import List, Optional


# ─── Forecast ───────────────────────────────────────────────

class ForecastRequest(BaseModel):
    item_id: int
    business_unit_id: int
    location_id: int
    days_ahead: int = 14
    lookback_days: int = 180


class ForecastResponse(BaseModel):
    item_id: int
    predicted_demand_total: float
    predicted_daily_avg: float
    confidence_low: float
    confidence_high: float
    trend_direction: str          # "UP" | "DOWN" | "STABLE"
    trend_pct: float
    peak_day: str                 # "FRIDAY" | "SATURDAY" etc.
    model_used: str               # "prophet" | "ets" | "fallback_wma"
    data_points: int


class ForecastBatchRequest(BaseModel):
    business_unit_id: int
    location_id: int
    days_ahead: int = 14
    lookback_days: int = 180
    item_ids: List[int]


class ForecastBatchResponse(BaseModel):
    results: List[ForecastResponse]
    processed: int
    failed: int


# ─── Anomalies ──────────────────────────────────────────────

class AnomalyRequest(BaseModel):
    item_id: int
    business_unit_id: int
    lookback_days: int = 90
    contamination: float = Field(default=0.05, ge=0.01, le=0.5)


class AnomalyResponse(BaseModel):
    item_id: int
    anomaly_dates: List[str]
    anomaly_score: float
    recommendation: str     # "CLEAN" | "HAS_OUTLIERS" | "UNRELIABLE" | "INSUFFICIENT_DATA"


class AnomalyBatchRequest(BaseModel):
    items: List[AnomalyRequest]


class AnomalyBatchResponse(BaseModel):
    results: List[AnomalyResponse]


# ─── Explain ────────────────────────────────────────────────

class SuggestionInput(BaseModel):
    item_id: int
    item_name: str
    current_stock: float
    min_level: float
    estimated_stockout_days: int
    daily_consumption: float
    suggested_quantity: float
    suggested_price: float = 0.0
    suggested_supplier_name: str = ""
    urgency_level: int = 3          # 1=critical … 5=low
    trend_direction: str = "STABLE"
    trend_pct: float = 0.0
    abc_class: str = "C"            # "A" | "B" | "C"
    unit_of_measure: str = "unidades"


class ExplainRequest(BaseModel):
    business_unit_id: Optional[int] = None
    location_id: Optional[int] = None
    suggestions: List[SuggestionInput]


class ExplainResult(BaseModel):
    item_id: int
    reason_es: str


class ExplainResponse(BaseModel):
    results: List[ExplainResult]


# ─── Supplier Rank ──────────────────────────────────────────

class SupplierRankRequest(BaseModel):
    item_id: int
    business_unit_id: int
    location_id: Optional[int] = None
    required_quantity: float = 1.0
    candidate_supplier_ids: Optional[List[int]] = None   # None = all known suppliers


class SupplierScore(BaseModel):
    supplier_id: int
    supplier_name: str
    score: float
    avg_price: float
    avg_lead_days: Optional[int]
    on_time_pct: Optional[float]    # placeholder; 0.0–1.0
    rank: int


class SupplierRankResponse(BaseModel):
    item_id: int
    ranked: List[SupplierScore]
