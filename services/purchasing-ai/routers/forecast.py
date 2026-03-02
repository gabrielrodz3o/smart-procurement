import pandas as pd
import numpy as np
from fastapi import APIRouter
from models.schemas import (
    ForecastRequest, ForecastResponse,
    ForecastBatchRequest, ForecastBatchResponse,
)
from models.db import get_sales_history
from utils.cache import cache_get, cache_set

router = APIRouter(prefix="/forecast", tags=["forecast"])


def _get_peak_weekday(forecast: pd.DataFrame) -> str:
    days = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]
    try:
        forecast["dow"] = pd.to_datetime(forecast["ds"]).dt.dayofweek
        # pandas dow: 0=Monday … 6=Sunday → map to our Sunday-first list
        day_avg = forecast.groupby("dow")["yhat"].mean()
        peak_dow = int(day_avg.idxmax())
        # pandas: 0=Mon…6=Sun; our list is Sun=0…Sat=6
        pandas_to_list = {0: 1, 1: 2, 2: 3, 3: 4, 4: 5, 5: 6, 6: 0}
        return days[pandas_to_list[peak_dow]]
    except Exception:
        return "UNKNOWN"


def _fallback_wma(df: pd.DataFrame, req: ForecastRequest) -> ForecastResponse:
    if len(df) == 0:
        daily_avg = 0.01
    else:
        weights = np.arange(1, len(df) + 1, dtype=float)
        daily_avg = float(np.average(df["qty"].values, weights=weights))

    total = daily_avg * req.days_ahead
    return ForecastResponse(
        item_id=req.item_id,
        predicted_demand_total=round(total, 2),
        predicted_daily_avg=round(daily_avg, 4),
        confidence_low=round(total * 0.7, 2),
        confidence_high=round(total * 1.3, 2),
        trend_direction="STABLE",
        trend_pct=0.0,
        peak_day="UNKNOWN",
        model_used="fallback_wma",
        data_points=len(df),
    )


async def _forecast_single(req: ForecastRequest) -> ForecastResponse:
    df = await get_sales_history(
        item_id=req.item_id,
        business_unit_id=req.business_unit_id,
        days=req.lookback_days,
        location_id=req.location_id,
    )

    if len(df) < 14:
        return _fallback_wma(df, req)

    try:
        from prophet import Prophet

        df_prophet = df[["date", "qty"]].rename(columns={"date": "ds", "qty": "y"})
        df_prophet["ds"] = pd.to_datetime(df_prophet["ds"])

        # Try to load cached model (keyed by item+bu+data_points to invalidate on new data)
        cache_key_args = dict(
            item_id=req.item_id,
            bu=req.business_unit_id,
            loc=req.location_id,
            n=len(df),
        )
        model = cache_get("prophet_model", **cache_key_args)

        if model is None:
            from utils.calendar_features import build_prophet_regressors

            model = Prophet(
                seasonality_mode="multiplicative",
                weekly_seasonality=True,
                yearly_seasonality=len(df) > 90,
                daily_seasonality=False,
                interval_width=0.80,
            )
            model.add_country_holidays(country_name="DO")

            # RD-specific regressors: Semana Santa, tourism peak, rainy season, holidays
            REGRESSORS = [
                "semana_santa", "tourism_peak", "rainy_season", "high_season",
                "dia_independencia", "dia_restauracion", "navidad", "anio_nuevo",
                "rd_holiday",
            ]
            for reg in REGRESSORS:
                model.add_regressor(reg, standardize=False)

            regs_train = build_prophet_regressors(df_prophet["ds"])
            for reg in REGRESSORS:
                df_prophet[reg] = regs_train[reg].values

            model.fit(df_prophet)
            cache_set("prophet_model", model, ttl=3600, **cache_key_args)

        future = model.make_future_dataframe(periods=req.days_ahead)
        regs_future = build_prophet_regressors(future["ds"])
        for reg in REGRESSORS:
            future[reg] = regs_future[reg].values
        forecast = model.predict(future)

        future_rows = forecast.tail(req.days_ahead)
        predicted_total = max(0.0, float(future_rows["yhat"].sum()))
        predicted_avg   = predicted_total / req.days_ahead
        conf_low        = max(0.0, float(future_rows["yhat_lower"].sum()))
        conf_high       = float(future_rows["yhat_upper"].sum())

        # Trend vs. prior 30-day window
        prior_rows = forecast.iloc[-(req.days_ahead + 30):-req.days_ahead]
        last_30_avg = float(prior_rows["yhat"].mean()) if len(prior_rows) > 0 else predicted_avg
        trend_pct = ((predicted_avg - last_30_avg) / last_30_avg * 100) if last_30_avg > 0 else 0.0
        if trend_pct > 10:
            trend_direction = "UP"
        elif trend_pct < -10:
            trend_direction = "DOWN"
        else:
            trend_direction = "STABLE"

        peak_day = _get_peak_weekday(forecast)

        return ForecastResponse(
            item_id=req.item_id,
            predicted_demand_total=round(predicted_total, 2),
            predicted_daily_avg=round(predicted_avg, 4),
            confidence_low=round(conf_low, 2),
            confidence_high=round(conf_high, 2),
            trend_direction=trend_direction,
            trend_pct=round(trend_pct, 1),
            peak_day=peak_day,
            model_used="prophet",
            data_points=len(df),
        )

    except Exception as exc:
        # Prophet failed — graceful fallback
        return _fallback_wma(df, req)


@router.post("", response_model=ForecastResponse)
async def forecast_item(req: ForecastRequest):
    return await _forecast_single(req)


@router.post("/batch", response_model=ForecastBatchResponse)
async def forecast_batch(req: ForecastBatchRequest):
    import asyncio

    single_reqs = [
        ForecastRequest(
            item_id=item_id,
            business_unit_id=req.business_unit_id,
            location_id=req.location_id,
            days_ahead=req.days_ahead,
            lookback_days=req.lookback_days,
        )
        for item_id in req.item_ids
    ]

    raw = await asyncio.gather(
        *[_forecast_single(r) for r in single_reqs],
        return_exceptions=True,
    )

    results = []
    failed = 0
    for item_id, outcome in zip(req.item_ids, raw):
        if isinstance(outcome, Exception):
            failed += 1
            print(f"[forecast/batch] item_id={item_id} FAILED: {type(outcome).__name__}: {outcome}")
        else:
            results.append(outcome)

    return ForecastBatchResponse(
        results=results,
        processed=len(results),
        failed=failed,
    )
