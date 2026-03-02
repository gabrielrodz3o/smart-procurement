import numpy as np
from fastapi import APIRouter
from models.schemas import (
    AnomalyRequest, AnomalyResponse,
    AnomalyBatchRequest, AnomalyBatchResponse,
)
from models.db import get_sales_history

router = APIRouter(prefix="/anomalies", tags=["anomalies"])


async def _detect_single(req: AnomalyRequest) -> AnomalyResponse:
    df = await get_sales_history(
        item_id=req.item_id,
        business_unit_id=req.business_unit_id,
        days=req.lookback_days,
    )

    if len(df) < 10:
        return AnomalyResponse(
            item_id=req.item_id,
            anomaly_dates=[],
            anomaly_score=1.0,
            recommendation="INSUFFICIENT_DATA",
        )

    from sklearn.ensemble import IsolationForest

    X = df["qty"].values.reshape(-1, 1)
    clf = IsolationForest(contamination=req.contamination, random_state=42)
    preds = clf.fit_predict(X)  # -1 = anomaly, 1 = normal

    anomaly_idx = np.where(preds == -1)[0]
    anomaly_dates = df.iloc[anomaly_idx]["date"].astype(str).tolist()

    score = 1.0 - (len(anomaly_dates) / len(df))
    if score > 0.95:
        recommendation = "CLEAN"
    elif score > 0.80:
        recommendation = "HAS_OUTLIERS"
    else:
        recommendation = "UNRELIABLE"

    return AnomalyResponse(
        item_id=req.item_id,
        anomaly_dates=anomaly_dates,
        anomaly_score=round(score, 3),
        recommendation=recommendation,
    )


@router.post("", response_model=AnomalyResponse)
async def detect_anomalies(req: AnomalyRequest):
    return await _detect_single(req)


@router.post("/batch", response_model=AnomalyBatchResponse)
async def detect_anomalies_batch(req: AnomalyBatchRequest):
    import asyncio
    results = await asyncio.gather(*[_detect_single(r) for r in req.items])
    return AnomalyBatchResponse(results=list(results))
