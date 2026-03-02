"""
POST /feedback — recibe la aprobación del frontend y actualiza
approval_quantity en auto_purchase_suggestions.

El SQL fn_intelligent_purchasing_v2 ya lee correction_factor desde
las últimas 30 aprobaciones (status=APPROVED, approval_quantity IS NOT NULL),
así que solo hay que persistir aquí y el próximo /generate usa el dato.
"""
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from typing import Optional
from models.db import get_connection

router = APIRouter(prefix="/feedback", tags=["feedback"])


class FeedbackRequest(BaseModel):
    suggestion_id:     int
    approved:          bool            # True = aprobado, False = rechazado
    approval_quantity: Optional[float] = None   # cantidad real que el usuario aprobó
    notes:             Optional[str]   = None


class FeedbackResponse(BaseModel):
    suggestion_id: int
    status:        str   # "APPROVED" | "REJECTED"
    correction_factor_updated: bool


@router.post("", response_model=FeedbackResponse)
async def submit_feedback(req: FeedbackRequest):
    new_status = "APPROVED" if req.approved else "REJECTED"

    conn = await get_connection()
    try:
        # 1. Actualizar status + approval_quantity + reviewed_at
        result = await conn.execute(
            """
            UPDATE inventory.auto_purchase_suggestions
               SET status            = $1,
                   approval_quantity = COALESCE($2, suggested_quantity),
                   reviewed_at       = NOW()
             WHERE id = $3
            """,
            new_status,
            req.approval_quantity,
            req.suggestion_id,
        )

        if result == "UPDATE 0":
            raise HTTPException(status_code=404, detail=f"suggestion_id {req.suggestion_id} not found")

        # 2. Recalcular correction_factor para ese ítem en ese business_unit
        #    (mismo cálculo que usa el SQL fn_intelligent_purchasing_v2 N3)
        #    Solo si hay >= 2 aprobaciones en los últimos 30 días
        cf_updated = False
        if req.approved:
            row = await conn.fetchrow(
                """
                SELECT
                    aps.item_id,
                    aps.business_unit_id,
                    AVG(aps.approval_quantity / NULLIF(aps.suggested_quantity, 0)) AS new_cf
                FROM inventory.auto_purchase_suggestions aps
                WHERE aps.id = $1
                  AND aps.status = 'APPROVED'
                  AND aps.reviewed_at >= NOW() - INTERVAL '30 days'
                  AND aps.approval_quantity IS NOT NULL
                  AND aps.suggested_quantity > 0
                GROUP BY aps.item_id, aps.business_unit_id
                HAVING COUNT(*) >= 2
                """,
                req.suggestion_id,
            )

            if row and row["new_cf"]:
                # Clamp 0.5–2.0 (mismo que el SQL)
                new_cf = max(0.5, min(2.0, float(row["new_cf"])))
                # Persistir en todas las sugerencias PENDING de ese ítem
                await conn.execute(
                    """
                    UPDATE inventory.auto_purchase_suggestions
                       SET correction_factor = $1
                     WHERE item_id          = $2
                       AND business_unit_id = $3
                       AND status           = 'PENDING'
                    """,
                    new_cf,
                    row["item_id"],
                    row["business_unit_id"],
                )
                cf_updated = True

    finally:
        await conn.close()

    return FeedbackResponse(
        suggestion_id=req.suggestion_id,
        status=new_status,
        correction_factor_updated=cf_updated,
    )
