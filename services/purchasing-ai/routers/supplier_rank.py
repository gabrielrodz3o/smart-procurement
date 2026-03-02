from fastapi import APIRouter
from models.schemas import SupplierRankRequest, SupplierRankResponse, SupplierScore
from models.db import get_supplier_history, get_supplier_on_time_pct

router = APIRouter(prefix="/supplier-rank", tags=["supplier-rank"])


@router.post("", response_model=SupplierRankResponse)
async def rank_suppliers(req: SupplierRankRequest):
    history = await get_supplier_history(
        item_id=req.item_id,
        business_unit_id=req.business_unit_id,
    )

    if not history:
        return SupplierRankResponse(item_id=req.item_id, ranked=[])

    # Filter to candidate_supplier_ids if specified
    if req.candidate_supplier_ids:
        history = [r for r in history if r["supplier_id"] in req.candidate_supplier_ids]

    if not history:
        return SupplierRankResponse(item_id=req.item_id, ranked=[])

    # Fetch real on_time_pct from finances.invoices
    all_supplier_ids = list({r["supplier_id"] for r in history})
    on_time_map = await get_supplier_on_time_pct(
        business_unit_id=req.business_unit_id,
        supplier_ids=all_supplier_ids,
    )

    # Aggregate: for each supplier keep all prices + avg lead time
    agg: dict[int, dict] = {}
    for row in history:
        sid = row["supplier_id"]
        if sid not in agg:
            agg[sid] = {
                "supplier_id": sid,
                "supplier_name": row["supplier_name"],
                "prices": [],
                "lead_times": [],
            }
        agg[sid]["prices"].append(float(row["price"] or 0))
        if row["lead_time_days"]:
            agg[sid]["lead_times"].append(int(row["lead_time_days"]))

    # Score each supplier: lower price + lower lead time = higher score
    all_prices = [min(v["prices"]) for v in agg.values() if v["prices"]]
    max_price = max(all_prices) if all_prices else 1
    min_price = min(all_prices) if all_prices else 0

    all_leads = [
        (sum(v["lead_times"]) / len(v["lead_times"]))
        for v in agg.values()
        if v["lead_times"]
    ]
    max_lead = max(all_leads) if all_leads else 1
    min_lead = min(all_leads) if all_leads else 0

    def _score(supplier: dict) -> float:
        price = min(supplier["prices"]) if supplier["prices"] else max_price
        lead  = (
            sum(supplier["lead_times"]) / len(supplier["lead_times"])
            if supplier["lead_times"]
            else max_lead
        )
        price_range = max_price - min_price or 1
        lead_range  = max_lead - min_lead or 1
        price_norm  = 1 - (price - min_price) / price_range   # higher = cheaper
        lead_norm   = 1 - (lead  - min_lead)  / lead_range    # higher = faster
        otp         = on_time_map.get(supplier["supplier_id"], 0.5)  # default 50% if unknown
        return round(0.60 * price_norm + 0.25 * lead_norm + 0.15 * otp, 4)

    scored = []
    for v in agg.values():
        avg_lead = (
            int(sum(v["lead_times"]) / len(v["lead_times"]))
            if v["lead_times"]
            else None
        )
        scored.append(
            SupplierScore(
                supplier_id=v["supplier_id"],
                supplier_name=v["supplier_name"],
                avg_price=round(sum(v["prices"]) / len(v["prices"]), 2) if v["prices"] else 0.0,
                avg_lead_days=avg_lead,
                on_time_pct=on_time_map.get(v["supplier_id"]),  # real from finances.invoices
                score=_score(v),
                rank=0,
            )
        )

    scored.sort(key=lambda x: x.score, reverse=True)
    for i, s in enumerate(scored, start=1):
        s.rank = i

    return SupplierRankResponse(item_id=req.item_id, ranked=scored)
