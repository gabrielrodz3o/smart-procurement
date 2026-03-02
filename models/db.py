import os
import asyncpg
import pandas as pd
from typing import Optional
from dotenv import load_dotenv

load_dotenv()

# Build DATABASE_URL from individual vars if not set directly
def _get_database_url() -> str:
    url = os.getenv("DATABASE_URL")
    if url:
        return url
    host = os.getenv("DB_HOST", "localhost")
    port = os.getenv("DB_PORT", "6432")
    db   = os.getenv("DB_DATABASE", "gcode")
    user = os.getenv("DB_USER", "dev_gabriel")
    pwd  = os.getenv("DB_PASSWORD", "")
    return f"postgresql://{user}:{pwd}@{host}:{port}/{db}"

DATABASE_URL = _get_database_url()


async def get_connection() -> asyncpg.Connection:
    return await asyncpg.connect(DATABASE_URL)


async def get_sales_history(
    item_id: int,
    business_unit_id: int,
    days: int = 180,
    location_id: Optional[int] = None,
) -> pd.DataFrame:
    conn = await get_connection()
    try:
        query = """
            SELECT
                DATE(iw.effective_date)  AS date,
                SUM(ABS(iw.quantity))    AS qty
            FROM inventory.item_in_warehouses iw
            JOIN inventory.warehouses w ON w.id = iw.warehouse_id
            WHERE w.business_units_id = $1
              AND iw.item_id           = $2
              AND iw.quantity          < 0
              AND iw.order_id          IS NOT NULL
              AND iw.effective_date   >= CURRENT_DATE - ($3 * INTERVAL '1 day')
        """
        params = [business_unit_id, item_id, days]

        if location_id is not None:
            query += " AND w.location_id = $4"
            params.append(location_id)

        query += " GROUP BY DATE(iw.effective_date) ORDER BY date ASC"

        rows = await conn.fetch(query, *params)
        return pd.DataFrame([dict(r) for r in rows], columns=["date", "qty"])
    finally:
        await conn.close()


async def get_items_for_business_unit(business_unit_id: int) -> list[dict]:
    conn = await get_connection()
    try:
        rows = await conn.fetch("""
            SELECT DISTINCT
                cd.item_id,
                i.name AS item_name
            FROM inventory.catalogue_details cd
            JOIN inventory.catalogues c ON c.id = cd.catalogue_id
            JOIN inventory.items i ON i.id = cd.item_id
            WHERE c.business_unit_id = $1
              AND i.active = TRUE
              AND i.item_type_id IN (1, 6)
            ORDER BY cd.item_id
        """, business_unit_id)
        return [dict(r) for r in rows]
    finally:
        await conn.close()


async def get_supplier_history(
    item_id: int,
    business_unit_id: int,
) -> list[dict]:
    conn = await get_connection()
    try:
        rows = await conn.fetch("""
            SELECT
                sph.supplier_id,
                s.name          AS supplier_name,
                sph.price,
                sph.created_at  AS recorded_at,
                sph.lead_time_days
            FROM inventory.supplier_price_history sph
            JOIN public.suppliers s ON s.id = sph.supplier_id
            WHERE sph.item_id          = $1
              AND sph.business_unit_id = $2
            ORDER BY sph.created_at DESC
            LIMIT 50
        """, item_id, business_unit_id)
        return [dict(r) for r in rows]
    finally:
        await conn.close()


async def run_intelligent_purchasing(
    business_unit_id: int,
    location_id: int,
    urgency_threshold: int = 5,
) -> list:
    conn = await get_connection()
    try:
        rows = await conn.fetch(
            "SELECT * FROM inventory.fn_intelligent_purchasing_v2($1, $2, $3)",
            business_unit_id, location_id, urgency_threshold,
        )
        return [dict(r) for r in rows]
    finally:
        await conn.close()


async def get_supplier_on_time_pct(
    business_unit_id: int,
    supplier_ids: Optional[list] = None,
) -> dict:
    """Returns {supplier_id: on_time_pct} from finances.invoices purchase history."""
    conn = await get_connection()
    try:
        query = """
            SELECT
                inv.entity_id                                        AS supplier_id,
                COUNT(*)                                             AS total_orders,
                SUM(CASE
                    WHEN inv.delivery_date IS NOT NULL
                     AND inv.delivery_date <= inv.expected_delivery_date
                    THEN 1 ELSE 0
                END)::NUMERIC / NULLIF(COUNT(*), 0)                 AS on_time_pct
            FROM finances.invoices inv
            WHERE inv.invoice_type_id  = 1
              AND inv.business_unit_id = $1
              AND inv.status_id        = 1
              AND inv.created_at      >= CURRENT_DATE - (365 * INTERVAL '1 day')
        """
        params: list = [business_unit_id]

        if supplier_ids:
            query += f" AND inv.entity_id = ANY($2::int[])"
            params.append(supplier_ids)

        query += " GROUP BY inv.entity_id"

        rows = await conn.fetch(query, *params)
        return {
            row["supplier_id"]: round(float(row["on_time_pct"]), 3)
            for row in rows
            if row["on_time_pct"] is not None
        }
    except Exception:
        return {}
    finally:
        await conn.close()


async def ping_db() -> bool:
    try:
        conn = await get_connection()
        await conn.fetchval("SELECT 1")
        await conn.close()
        return True
    except Exception:
        return False
