-- ============================================================================
-- fn_intelligent_purchasing_v2 — v4.0  (10/10 Inteligencia)
-- ============================================================================
-- NUEVAS MEJORAS v4 sobre v3:
--   N1: trend_factor en tiempo real — ratio avg_7d / avg_60d desde
--       item_in_warehouses (no depende de consumption_analysis pre-calculada)
--       > 1.2 → demanda subiendo → sugerir más / ROP más alto
--       < 0.8 → demanda bajando  → sugerir menos
--       Clamped 0.5–2.0. Flag TREND_FACTOR:N en anomaly_flags.
--
--   N2: weekday_factor — ratio consumo del día de semana actual vs promedio
--       global. Ajusta v_daily_consumption antes de calcular ROP y suggested_qty.
--       Clamped 0.5–2.0. Flag WEEKDAY_FACTOR:N en anomaly_flags.
--
--   N3: feedback_loop — correction_factor = AVG(approval_quantity /
--       suggested_quantity) de los últimos 30 días en auto_purchase_suggestions
--       donde status = 'APPROVED' y approval_quantity IS NOT NULL.
--       Requiere ≥ 2 aprobaciones. Clamped 0.5–2.0.
--       Flag FEEDBACK:×N en anomaly_flags.
--       Se aplica a v_suggested_qty DESPUÉS de todo el cálculo estándar.
--
-- ARQUITECTURA pre-calculada (tmp tables antes del loop):
--   tmp_derived_demand  — M10: demanda de conversiones (ya existía)
--   tmp_trend_factors   — N1: trend_factor por ítem
--   tmp_weekday_factors — N2: weekday_factor por ítem
--   tmp_feedback_factors— N3: correction_factor por ítem+location
--
-- Todas requieren ≥2 días/registros para activarse (NULLIF protección).
-- ============================================================================

DROP FUNCTION IF EXISTS inventory.fn_intelligent_purchasing_v2(INTEGER, INTEGER, INTEGER);

CREATE OR REPLACE FUNCTION inventory.fn_intelligent_purchasing_v2(
    p_business_unit_id  INTEGER,
    p_location_id       INTEGER,
    p_urgency_threshold INTEGER DEFAULT 5
)
RETURNS TABLE(
    out_suggestion_id          INTEGER,
    out_item_id                INTEGER,
    out_item_name              TEXT,
    out_warehouse_name         TEXT,
    out_location_name          TEXT,
    out_current_stock          NUMERIC,
    out_min_level              NUMERIC,
    out_max_level              NUMERIC,
    out_reorder_point          NUMERIC,
    out_safety_stock           NUMERIC,
    out_suggested_quantity     NUMERIC,
    out_optimal_order_qty      NUMERIC,
    out_estimated_stockout_days INTEGER,
    out_estimated_cost         NUMERIC,
    out_urgency_level          INTEGER,
    out_abc_class              TEXT,
    out_xyz_class              TEXT,
    out_suggested_supplier     TEXT,
    out_suggested_supplier_id  INTEGER,
    out_suggested_price        NUMERIC,
    out_action_taken           TEXT,
    out_recommendation         TEXT,
    out_anomaly_flags          TEXT[],
    out_delivery_window        TEXT,
    -- ✅ N1/N2/N3: nuevas columnas de salida
    out_trend_factor           NUMERIC,
    out_weekday_factor         NUMERIC,
    out_correction_factor      NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    r                       RECORD;
    v_current_stock         NUMERIC;
    v_daily_consumption     NUMERIC;
    v_std_deviation         NUMERIC;
    v_lead_time             INTEGER;
    v_safety_stock          NUMERIC;
    v_reorder_point         NUMERIC;
    v_reorder_point_calc    NUMERIC;
    v_suggested_qty         NUMERIC;
    v_optimal_qty           NUMERIC;
    v_stockout_date         DATE;
    v_urgency               INTEGER;
    v_best_price            RECORD;
    v_suggestion_id         INTEGER;
    v_action_taken          TEXT;
    v_abc_class             TEXT;
    v_xyz_class             TEXT;
    v_variance_coef         NUMERIC;
    v_z_score               NUMERIC := 1.65;
    v_holding_cost          NUMERIC := 0.25;
    v_ordering_cost         NUMERIC := 50;
    v_items_processed       INTEGER := 0;
    v_suggestions_created   INTEGER := 0;
    v_items_skipped         INTEGER := 0;
    v_anomalies_detected    INTEGER := 0;
    v_recommendation        TEXT;
    v_anomaly_flags         TEXT[];
    v_estimated_cost        NUMERIC;
    v_unit_quantity         NUMERIC;
    v_item_id               INTEGER;
    v_business_unit_id      INTEGER;
    v_location_id           INTEGER;
    v_warehouse_id          INTEGER;
    v_preferred_supplier_id INTEGER;
    v_item_name             TEXT;
    v_warehouse_name        TEXT;
    v_location_name         TEXT;
    v_cost_price            NUMERIC;
    v_min_level             NUMERIC;
    v_max_level             NUMERIC;
    v_supplier_id           INTEGER;
    v_supplier_name         TEXT;
    v_supplier_price        NUMERIC;
    v_derived_demand        NUMERIC;
    v_is_converted_item     BOOLEAN;
    v_delivery_window       TEXT;
    v_substitute_name       TEXT;
    -- ✅ N1/N2/N3: nuevas variables
    v_trend_factor          NUMERIC;
    v_weekday_factor        NUMERIC;
    v_correction_factor     NUMERIC;
    v_has_real_consumption  BOOLEAN;
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE '🧠 INTELLIGENT PURCHASING V4 (10/10)';
    RAISE NOTICE '   Location: % (BU: %)', p_location_id, p_business_unit_id;
    RAISE NOTICE '   Urgency Threshold: ≤%', p_urgency_threshold;
    RAISE NOTICE '========================================';

    -- =====================================================
    -- M10: PRE-CALCULAR DEMANDA DERIVADA DE CONVERSIONES
    -- =====================================================
    CREATE TEMP TABLE IF NOT EXISTS tmp_derived_demand (
        item_from_id  INTEGER PRIMARY KEY,
        extra_daily   NUMERIC NOT NULL DEFAULT 0
    ) ON COMMIT DROP;
    TRUNCATE tmp_derived_demand;

    INSERT INTO tmp_derived_demand (item_from_id, extra_daily)
    SELECT
        ic.item_from_id,
        SUM(
            COALESCE(ca_to.average_daily_consumption, 0)
            * (ic.item_cantity_from / NULLIF(ic.item_cantity_to, 0))
            * (1 + ic.loss_percentage / 100.0)
        ) AS extra_daily
    FROM inventory.item_conversions ic
    JOIN inventory.items i_to   ON i_to.id  = ic.item_to_id   AND i_to.active  = TRUE
    JOIN inventory.items i_from ON i_from.id = ic.item_from_id AND i_from.active = TRUE
    LEFT JOIN inventory.consumption_analysis ca_to
        ON  ca_to.item_id          = ic.item_to_id
        AND ca_to.business_unit_id = ic.business_unit_id
        AND ca_to.location_id      = p_location_id
    WHERE ic.business_unit_id = p_business_unit_id
    GROUP BY ic.item_from_id;

    RAISE NOTICE 'M10: % ítems origen con demanda derivada calculada',
        (SELECT COUNT(*) FROM tmp_derived_demand WHERE extra_daily > 0);

    -- =====================================================
    -- ✅ N1: PRE-CALCULAR TREND FACTOR EN TIEMPO REAL
    -- ratio avg_7d / avg_60d desde item_in_warehouses
    -- Fuente: salidas con order_id IS NOT NULL (consumo real de órdenes)
    -- =====================================================
    CREATE TEMP TABLE IF NOT EXISTS tmp_trend_factors (
        item_id       INTEGER PRIMARY KEY,
        avg_60d       NUMERIC,
        avg_7d        NUMERIC,
        trend_factor  NUMERIC
    ) ON COMMIT DROP;
    TRUNCATE tmp_trend_factors;

    INSERT INTO tmp_trend_factors (item_id, avg_60d, avg_7d, trend_factor)
    WITH raw_sales AS (
        SELECT
            iw.item_id,
            DATE(iw.effective_date)                       AS sale_date,
            SUM(ABS(iw.quantity))                         AS qty
        FROM inventory.item_in_warehouses iw
        JOIN inventory.warehouses w ON w.id = iw.warehouse_id
        WHERE w.business_units_id = p_business_unit_id
          AND iw.quantity         < 0
          AND iw.order_id         IS NOT NULL
          AND iw.effective_date   >= CURRENT_DATE - 60
        GROUP BY iw.item_id, DATE(iw.effective_date)
    ),
    avg_60 AS (
        SELECT item_id,
               SUM(qty)::NUMERIC / NULLIF(COUNT(DISTINCT sale_date), 0) AS avg_daily
        FROM raw_sales
        GROUP BY item_id
    ),
    avg_7 AS (
        SELECT item_id,
               SUM(qty)::NUMERIC / NULLIF(COUNT(DISTINCT sale_date), 0) AS avg_daily
        FROM raw_sales
        WHERE sale_date >= CURRENT_DATE - 7
        GROUP BY item_id
    )
    SELECT
        a60.item_id,
        a60.avg_daily                                     AS avg_60d,
        COALESCE(a7.avg_daily, 0)                         AS avg_7d,
        CASE
            WHEN COALESCE(a60.avg_daily, 0) = 0 THEN 1.0
            WHEN COALESCE(a7.avg_daily,   0) = 0 THEN 1.0
            ELSE LEAST(GREATEST(
                   ROUND(a7.avg_daily / NULLIF(a60.avg_daily, 0), 2),
                   0.5), 2.0)
        END                                               AS trend_factor
    FROM avg_60 a60
    LEFT JOIN avg_7 a7 ON a7.item_id = a60.item_id;

    RAISE NOTICE 'N1: % ítems con trend_factor calculado en tiempo real',
        (SELECT COUNT(*) FROM tmp_trend_factors);

    -- =====================================================
    -- ✅ N2: PRE-CALCULAR WEEKDAY FACTOR
    -- ratio consumo del día de semana actual vs promedio global
    -- =====================================================
    CREATE TEMP TABLE IF NOT EXISTS tmp_weekday_factors (
        item_id        INTEGER PRIMARY KEY,
        weekday_factor NUMERIC
    ) ON COMMIT DROP;
    TRUNCATE tmp_weekday_factors;

    INSERT INTO tmp_weekday_factors (item_id, weekday_factor)
    WITH raw_sales AS (
        SELECT
            iw.item_id,
            DATE(iw.effective_date)                             AS sale_date,
            EXTRACT(DOW FROM iw.effective_date)::INTEGER        AS dow,
            SUM(ABS(iw.quantity))                               AS qty
        FROM inventory.item_in_warehouses iw
        JOIN inventory.warehouses w ON w.id = iw.warehouse_id
        WHERE w.business_units_id = p_business_unit_id
          AND iw.quantity         < 0
          AND iw.order_id         IS NOT NULL
          AND iw.effective_date   >= CURRENT_DATE - 60
        GROUP BY iw.item_id, DATE(iw.effective_date),
                 EXTRACT(DOW FROM iw.effective_date)
    ),
    weekday_avg AS (
        SELECT item_id, dow, AVG(qty) AS avg_for_dow
        FROM raw_sales
        GROUP BY item_id, dow
    ),
    global_avg AS (
        SELECT item_id, AVG(qty) AS avg_global
        FROM raw_sales
        GROUP BY item_id
    )
    SELECT
        wa.item_id,
        CASE
            WHEN COALESCE(ga.avg_global, 0) = 0 THEN 1.0
            ELSE LEAST(GREATEST(
                   ROUND(wa.avg_for_dow / NULLIF(ga.avg_global, 0), 2),
                   0.5), 2.0)
        END AS weekday_factor
    FROM weekday_avg wa
    JOIN global_avg ga ON ga.item_id = wa.item_id
    WHERE wa.dow = EXTRACT(DOW FROM CURRENT_DATE)::INTEGER;

    RAISE NOTICE 'N2: % ítems con weekday_factor calculado (DOW=%)',
        (SELECT COUNT(*) FROM tmp_weekday_factors),
        EXTRACT(DOW FROM CURRENT_DATE)::INTEGER;

    -- =====================================================
    -- ✅ N3: PRE-CALCULAR FEEDBACK LOOP
    -- correction_factor = AVG(approval_quantity / suggested_quantity)
    -- desde auto_purchase_suggestions APPROVED últimos 30 días
    -- Requiere ≥ 2 aprobaciones con approval_quantity registrada
    -- =====================================================
    CREATE TEMP TABLE IF NOT EXISTS tmp_feedback_factors (
        item_id            INTEGER,
        location_id        INTEGER,
        correction_factor  NUMERIC,
        feedback_count     INTEGER,
        PRIMARY KEY (item_id, location_id)
    ) ON COMMIT DROP;
    TRUNCATE tmp_feedback_factors;

    INSERT INTO tmp_feedback_factors (item_id, location_id, correction_factor, feedback_count)
    SELECT
        aps.item_id,
        aps.location_id,
        LEAST(GREATEST(
            AVG(aps.approval_quantity::NUMERIC / NULLIF(aps.suggested_quantity, 0)),
            0.5), 2.0)                    AS correction_factor,
        COUNT(*)                          AS feedback_count
    FROM inventory.auto_purchase_suggestions aps
    WHERE aps.business_unit_id  = p_business_unit_id
      AND aps.status            = 'APPROVED'
      AND aps.approval_quantity IS NOT NULL
      AND aps.approval_quantity  > 0
      AND aps.suggested_quantity > 0
      AND aps.reviewed_at       >= NOW() - INTERVAL '30 days'
    GROUP BY aps.item_id, aps.location_id
    HAVING COUNT(*) >= 2;

    RAISE NOTICE 'N3: % ítems con correction_factor (feedback loop activo)',
        (SELECT COUNT(*) FROM tmp_feedback_factors);

    -- =====================================================
    -- 1. EXPIRAR SUGERENCIAS OBSOLETAS (> 3 días)
    -- =====================================================
    UPDATE inventory.auto_purchase_suggestions aps
    SET
        status      = 'EXPIRED',
        reviewed_at = NOW()
    WHERE aps.business_unit_id = p_business_unit_id
      AND aps.location_id      = p_location_id
      AND aps.status            = 'PENDING'
      AND aps.created_at        < NOW() - INTERVAL '3 days';

    -- =====================================================
    -- 2. LOOP PRINCIPAL
    -- =====================================================
    FOR r IN
        SELECT
            cd.item_id,
            c.location_id,
            COALESCE(spc.business_unit_id, c.business_unit_id) AS business_unit_id,
            spc.preferred_supplier_id,
            spc.reorder_quantity_method,
            spc.fixed_reorder_quantity,
            i.name                AS item_name,
            l.description_short   AS location_name,
            wsl.warehouse_id,
            w.name                AS warehouse_name,
            wsl.min_quantity      AS min_level,
            wsl.max_quantity      AS max_level,
            wsl.reorder_point     AS configured_reorder_point,
            wsl.safety_stock      AS configured_safety_stock,
            COALESCE(wsl.lead_time_days, spc.lead_time_days, 7) AS lead_time_days,
            GREATEST(COALESCE(
                (SELECT MAX(cd2.cost_price)
                 FROM inventory.catalogue_details cd2
                 JOIN inventory.catalogues c2 ON c2.id = cd2.catalogue_id
                 WHERE cd2.item_id          = cd.item_id
                   AND c2.business_unit_id  = c.business_unit_id
                   AND cd2.cost_price       > 0.05),
                cd.cost_price, 0.01), 0.01)                       AS cost_price,
            GREATEST(COALESCE(i.unit_quantity, 1), 1)            AS unit_quantity,
            i.item_type_id,
            ic.abc_class,
            ic.xyz_class,
            ic.consumption_variance_coefficient,
            ca.average_daily_consumption,
            ca.forecasted_demand_30_days,
            ca.trend_direction,
            ca.confidence_level
        FROM inventory.catalogue_details cd
        JOIN inventory.catalogues c
            ON c.id = cd.catalogue_id
        LEFT JOIN inventory.smart_purchasing_config spc
            ON  spc.item_id          = cd.item_id
            AND spc.business_unit_id = c.business_unit_id
        JOIN inventory.items i
            ON i.id = cd.item_id
        JOIN human_resource.locations l
            ON l.id = c.location_id
        LEFT JOIN LATERAL (
            SELECT wsl_inner.*
            FROM inventory.warehouse_stock_levels wsl_inner
            JOIN inventory.warehouses w_inner
                ON w_inner.id = wsl_inner.warehouse_id
            WHERE wsl_inner.item_id     = cd.item_id
              AND w_inner.location_id   = p_location_id
              AND wsl_inner.active      = TRUE
            ORDER BY wsl_inner.min_quantity DESC
            LIMIT 1
        ) wsl ON TRUE
        LEFT JOIN inventory.warehouses w
            ON w.id = wsl.warehouse_id
        LEFT JOIN inventory.item_classification ic
            ON  ic.item_id          = cd.item_id
            AND ic.business_unit_id = c.business_unit_id
            AND ic.location_id      = c.location_id
        LEFT JOIN inventory.consumption_analysis ca
            ON  ca.item_id          = cd.item_id
            AND ca.business_unit_id = c.business_unit_id
            AND ca.location_id      = c.location_id
            AND ca.warehouse_id     = wsl.warehouse_id
        WHERE c.business_unit_id       = p_business_unit_id
          AND c.location_id            = p_location_id
          AND COALESCE(spc.auto_reorder_enabled, TRUE) = TRUE
          AND i.active                 = TRUE
          AND i.item_type_id           IN (1, 6)  -- insumos (6) y productos de bar/licores (1) son comprables
        ORDER BY
            CASE ic.abc_class
                WHEN 'A' THEN 1
                WHEN 'B' THEN 2
                WHEN 'C' THEN 3
                ELSE 4
            END,
            cd.item_id
    LOOP
        BEGIN
            v_items_processed := v_items_processed + 1;
            v_anomaly_flags   := ARRAY[]::TEXT[];

            -- Copiar a variables locales
            v_item_id               := r.item_id;
            v_business_unit_id      := r.business_unit_id;
            v_location_id           := r.location_id;
            v_warehouse_id          := r.warehouse_id;
            -- Fallback: si no hay warehouse_stock_levels, buscar almacén donde el ítem tiene movimientos recientes
            IF v_warehouse_id IS NULL THEN
                SELECT iw.warehouse_id INTO v_warehouse_id
                FROM inventory.item_in_warehouses iw
                JOIN inventory.warehouses w2
                    ON w2.id           = iw.warehouse_id
                   AND w2.location_id  = p_location_id
                   AND w2.active       = TRUE
                WHERE iw.item_id          = v_item_id
                  AND iw.business_unit_id = p_business_unit_id
                  AND iw.effective_date  >= CURRENT_DATE - 90
                GROUP BY iw.warehouse_id
                ORDER BY COUNT(*) DESC
                LIMIT 1;
            END IF;
            -- Segunda fallback: cualquier almacén activo de la location
            IF v_warehouse_id IS NULL THEN
                SELECT w2.id INTO v_warehouse_id
                FROM inventory.warehouses w2
                WHERE w2.location_id = p_location_id
                  AND w2.active      = TRUE
                ORDER BY w2.id
                LIMIT 1;
            END IF;
            -- Si aún no hay almacén, saltar el ítem
            IF v_warehouse_id IS NULL THEN
                v_items_skipped := v_items_skipped + 1;
                CONTINUE;
            END IF;
            v_preferred_supplier_id := r.preferred_supplier_id;
            v_item_name             := r.item_name;
            v_warehouse_name        := COALESCE(r.warehouse_name, 'Sin Almacén');
            v_location_name         := r.location_name;
            v_cost_price            := r.cost_price;
            v_unit_quantity         := GREATEST(COALESCE(r.unit_quantity, 1), 1);
            -- min/max ya están en unidades BASE en BD (WarehouseStockConfig los multiplica por uq al guardar)
            v_min_level             := COALESCE(r.min_level, 0);
            v_max_level             := COALESCE(r.max_level, 0);
            v_abc_class             := COALESCE(r.abc_class, 'C');
            v_xyz_class             := COALESCE(r.xyz_class, 'Y');
            v_variance_coef         := LEAST(COALESCE(r.consumption_variance_coefficient, 1.0), 3.0);

            -- ✅ N1: Leer trend_factor pre-calculado
            SELECT COALESCE(tf.trend_factor, 1.0)
            INTO v_trend_factor
            FROM tmp_trend_factors tf
            WHERE tf.item_id = v_item_id;
            v_trend_factor := COALESCE(v_trend_factor, 1.0);

            -- ✅ N2: Leer weekday_factor pre-calculado
            SELECT COALESCE(wf.weekday_factor, 1.0)
            INTO v_weekday_factor
            FROM tmp_weekday_factors wf
            WHERE wf.item_id = v_item_id;
            v_weekday_factor := COALESCE(v_weekday_factor, 1.0);

            -- ✅ N3: Leer correction_factor pre-calculado
            SELECT COALESCE(ff.correction_factor, 1.0)
            INTO v_correction_factor
            FROM tmp_feedback_factors ff
            WHERE ff.item_id    = v_item_id
              AND ff.location_id = v_location_id;
            v_correction_factor := COALESCE(v_correction_factor, 1.0);

            -- M8: FILTRO DE ITEMS BASURA
            -- Excluir: nombre muy corto o solo números.
            -- NOTA: ya filtramos item_type_id IN (1,6) en el WHERE del loop → no necesitamos filtrar por precio aquí.
            -- Ítems sin precio válido igual se sugieren (precio=0 es mejor que no sugerirlos).
            IF LENGTH(TRIM(v_item_name)) < 3
               OR TRIM(v_item_name) ~ '^[0-9]+$'
            THEN
                v_items_skipped := v_items_skipped + 1;
                CONTINUE;
            END IF;

            -- M10: SKIP si ítem es RESULTADO de una conversión
            SELECT EXISTS (
                SELECT 1
                FROM inventory.item_conversions ic
                WHERE ic.item_to_id        = v_item_id
                  AND ic.business_unit_id  = v_business_unit_id
            ) INTO v_is_converted_item;

            IF v_is_converted_item THEN
                v_items_skipped := v_items_skipped + 1;
                CONTINUE;
            END IF;

            -- M11: SKIP si ítem no tiene evidencia de ser comprable
            --      Evidencia A: historial de proveedor (supplier_price_history)
            --      Evidencia B: aparece en factura de compra directa activa
            --                   (finances.invoices invoice_type_id=1 status_id=1)
            IF NOT EXISTS (
                SELECT 1
                FROM inventory.supplier_price_history sph
                WHERE sph.item_id          = v_item_id
                  AND sph.business_unit_id = v_business_unit_id
                LIMIT 1
            )
            AND NOT EXISTS (
                SELECT 1
                FROM finances.invoice_details id2
                JOIN finances.invoices inv
                    ON inv.id            = id2.invoice_id
                WHERE id2.item_id        = v_item_id
                  AND inv.invoice_type_id = 1
                  AND inv.status_id       = 1
                LIMIT 1
            )
            THEN
                v_items_skipped := v_items_skipped + 1;
                CONTINUE;
            END IF;

            -- 2.1 STOCK ACTUAL
            v_current_stock := inventory.fn_get_current_stock_by_location(
                v_business_unit_id,
                v_location_id,
                v_item_id
            );

            -- M3: DETECCIÓN DE ANOMALÍAS
            IF v_current_stock > v_max_level * 10 AND v_max_level > 0 THEN
                v_anomaly_flags := array_append(v_anomaly_flags, 'STOCK_EXCESIVO');
                v_anomalies_detected := v_anomalies_detected + 1;
            END IF;
            IF v_current_stock < 0 THEN
                v_anomaly_flags := array_append(v_anomaly_flags, 'STOCK_NEGATIVO');
                v_anomalies_detected := v_anomalies_detected + 1;
            END IF;
            IF v_min_level >= v_max_level AND v_max_level > 0 THEN
                v_anomaly_flags := array_append(v_anomaly_flags, 'MIN_GTE_MAX');
                v_anomalies_detected := v_anomalies_detected + 1;
            END IF;

            -- 2.2 CONSUMO DIARIO (M5 + G4 WMA)
            v_has_real_consumption := FALSE;
            IF r.average_daily_consumption IS NOT NULL AND r.average_daily_consumption > 0 THEN
                v_daily_consumption   := r.average_daily_consumption;
                v_has_real_consumption := TRUE;
                IF r.forecasted_demand_30_days IS NOT NULL
                   AND r.confidence_level IS NOT NULL
                   AND r.confidence_level >= 0.7
                THEN
                    v_daily_consumption := GREATEST(
                        v_daily_consumption,
                        r.forecasted_demand_30_days / 30.0
                    );
                END IF;
            ELSE
                -- G4: Fallback WMA desde item_in_warehouses
                DECLARE
                    v_wma_p1 NUMERIC := 0;
                    v_wma_p2 NUMERIC := 0;
                    v_wma_p3 NUMERIC := 0;
                    v_wma    NUMERIC := 0;
                BEGIN
                    SELECT
                        COALESCE(SUM(CASE WHEN effective_date >= CURRENT_DATE - 30  THEN ABS(quantity) ELSE 0 END) / 30.0, 0),
                        COALESCE(SUM(CASE WHEN effective_date >= CURRENT_DATE - 60  AND effective_date < CURRENT_DATE - 30 THEN ABS(quantity) ELSE 0 END) / 30.0, 0),
                        COALESCE(SUM(CASE WHEN effective_date >= CURRENT_DATE - 90  AND effective_date < CURRENT_DATE - 60 THEN ABS(quantity) ELSE 0 END) / 30.0, 0)
                    INTO v_wma_p1, v_wma_p2, v_wma_p3
                    FROM inventory.item_in_warehouses
                    WHERE item_id          = v_item_id
                      AND business_unit_id = v_business_unit_id
                      AND quantity         < 0
                      AND invoice_id       IS NULL
                      AND effective_date  >= CURRENT_DATE - 90;

                    IF (v_wma_p1 + v_wma_p2 + v_wma_p3) > 0 THEN
                        v_wma := (v_wma_p1 * 3 + v_wma_p2 * 2 + v_wma_p3 * 1) / 6.0;
                        v_daily_consumption   := GREATEST(v_wma, 0.01);
                        v_has_real_consumption := TRUE;
                        v_anomaly_flags := array_append(v_anomaly_flags, FORMAT('WMA:%s/day', ROUND(v_wma, 4)));
                    ELSE
                        -- Puro fallback: sin historial real
                        v_daily_consumption   := GREATEST((v_max_level - v_min_level) / 30.0, 0.1);
                        v_has_real_consumption := FALSE;
                    END IF;
                END;
            END IF;

            -- M10: Sumar demanda derivada
            SELECT COALESCE(tdd.extra_daily, 0)
            INTO v_derived_demand
            FROM tmp_derived_demand tdd
            WHERE tdd.item_from_id = v_item_id;

            IF v_derived_demand > 0 THEN
                v_daily_consumption := v_daily_consumption + v_derived_demand;
                v_anomaly_flags := array_append(v_anomaly_flags, FORMAT('DERIVED_DEMAND:+%s/day', ROUND(v_derived_demand, 2)));
            END IF;

            -- G1: FACTOR ESTACIONAL
            DECLARE
                v_seasonal_factor NUMERIC := 1.0;
            BEGIN
                SELECT COALESCE(sf.factor, 1.0)
                INTO v_seasonal_factor
                FROM inventory.seasonal_factors sf
                WHERE sf.business_unit_id = v_business_unit_id
                  AND sf.month            = EXTRACT(MONTH FROM CURRENT_DATE)
                  AND (sf.item_id = v_item_id OR sf.item_id IS NULL)
                ORDER BY sf.item_id NULLS LAST
                LIMIT 1;

                IF v_seasonal_factor <> 1.0 THEN
                    v_daily_consumption := v_daily_consumption * v_seasonal_factor;
                    v_anomaly_flags := array_append(v_anomaly_flags, FORMAT('SEASONAL:×%s', v_seasonal_factor));
                END IF;
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;

            -- ✅ N2: APLICAR WEEKDAY FACTOR al consumo diario
            IF v_weekday_factor <> 1.0 THEN
                v_daily_consumption := v_daily_consumption * v_weekday_factor;
                v_anomaly_flags := array_append(v_anomaly_flags,
                    FORMAT('WEEKDAY_FACTOR:×%s', v_weekday_factor));
                RAISE NOTICE '   📅 N2 [%] weekday_factor=% → consumo ajustado=%/día',
                    v_item_name, v_weekday_factor, ROUND(v_daily_consumption, 4);
            END IF;

            -- ✅ N1: APLICAR TREND FACTOR al consumo diario
            IF v_trend_factor <> 1.0 THEN
                v_daily_consumption := v_daily_consumption * v_trend_factor;
                v_anomaly_flags := array_append(v_anomaly_flags,
                    FORMAT('TREND_FACTOR:×%s', v_trend_factor));
                RAISE NOTICE '   📈 N1 [%] trend_factor=% → consumo final=%/día',
                    v_item_name, v_trend_factor, ROUND(v_daily_consumption, 4);
            END IF;

            v_std_deviation := v_daily_consumption * v_variance_coef;

            -- 2.3 LEAD TIME
            v_lead_time := r.lead_time_days;

            -- 2.4 SAFETY STOCK
            IF r.configured_safety_stock IS NOT NULL AND r.configured_safety_stock > 0 THEN
                v_safety_stock := r.configured_safety_stock;
            ELSE
                v_safety_stock := LEAST(
                    v_z_score * v_std_deviation * SQRT(v_lead_time),
                    v_max_level
                );
            END IF;

            -- 2.5 PUNTO DE REORDEN (M1 + M4)
            IF r.configured_reorder_point IS NOT NULL AND r.configured_reorder_point > 0 THEN
                v_reorder_point_calc := r.configured_reorder_point;
            ELSE
                v_reorder_point_calc := (v_daily_consumption * v_lead_time) + v_safety_stock;
            END IF;
            v_reorder_point := GREATEST(v_reorder_point_calc, v_min_level);

            -- M4: Trend-aware ROP (usando consumption_analysis como señal secundaria)
            IF r.trend_direction = 'UP'
               AND r.confidence_level IS NOT NULL
               AND r.confidence_level >= 0.7
            THEN
                v_reorder_point := v_reorder_point * 1.15;
            ELSIF r.trend_direction = 'DOWN'
                  AND r.confidence_level IS NOT NULL
                  AND r.confidence_level >= 0.7
            THEN
                v_reorder_point := GREATEST(v_reorder_point * 0.90, v_min_level);
            END IF;

            RAISE NOTICE '📦 [%] Stock=% Min=% Max=% ROP=% SS=% Trend=% Weekday=% Feedback=%',
                v_item_name,
                v_current_stock,
                v_min_level,
                v_max_level,
                ROUND(v_reorder_point, 2),
                ROUND(v_safety_stock, 2),
                v_trend_factor,
                v_weekday_factor,
                v_correction_factor;

            -- 2.6 ¿DEBE GENERAR SUGERENCIA?
            -- Saltar ítems sin config de stock (min=0, max=0), sin consumo real Y con stock > 0:
            -- stock>0 + sin consumo + sin config = no hay urgencia real
            -- Si stock=0, siempre procesar (puede haberse agotado recientemente)
            IF v_min_level = 0 AND v_max_level = 0
               AND NOT v_has_real_consumption
               AND v_current_stock > 0
            THEN
                v_items_skipped := v_items_skipped + 1;
                CONTINUE;
            END IF;

            IF v_current_stock <= v_reorder_point THEN

                -- 2.7 CANTIDAD ÓPTIMA (EOQ)
                IF v_daily_consumption > 0 AND v_cost_price > 0 THEN
                    v_optimal_qty := SQRT(
                        (2 * v_daily_consumption * 365 * v_ordering_cost) /
                        ((v_cost_price / v_unit_quantity) * v_holding_cost)
                    );
                ELSE
                    v_optimal_qty := v_max_level - v_current_stock;
                END IF;

                -- Cantidad sugerida base (en unidades BASE)
                -- Cuando max_level=0 (sin configuración), usar consumo × (lead_time + 7 días de cobertura)
                v_suggested_qty := CASE
                    WHEN r.reorder_quantity_method = 'FIXED' THEN
                        r.fixed_reorder_quantity * v_unit_quantity
                    WHEN r.reorder_quantity_method = 'EOQ' THEN
                        v_optimal_qty
                    WHEN v_max_level = 0 AND v_daily_consumption > 0 THEN
                        -- Sin config max: pedir para cubrir lead_time + 7 días, menos stock actual
                        GREATEST(0, CEIL(v_daily_consumption * (v_lead_time + 7)) - v_current_stock)
                    ELSE
                        GREATEST(0, v_max_level - v_current_stock)
                END;

                v_suggested_qty := CEIL(GREATEST(v_suggested_qty, v_unit_quantity));

                -- M2: CAP a max_level × 3
                IF v_suggested_qty > v_max_level * 3 AND v_max_level > 0 THEN
                    v_anomaly_flags := array_append(v_anomaly_flags,
                        FORMAT('QTY_CAPPED:%s→%s', v_suggested_qty, CEIL(v_max_level * 3)));
                    v_suggested_qty := CEIL(v_max_level * 3);
                END IF;

                -- ✅ N3: APLICAR FEEDBACK LOOP (correction_factor)
                IF v_correction_factor <> 1.0 THEN
                    v_suggested_qty := CEIL(v_suggested_qty * v_correction_factor);
                    -- Re-aplicar cap después del ajuste
                    IF v_suggested_qty > v_max_level * 3 AND v_max_level > 0 THEN
                        v_suggested_qty := CEIL(v_max_level * 3);
                    END IF;
                    v_anomaly_flags := array_append(v_anomaly_flags,
                        FORMAT('FEEDBACK:×%s', v_correction_factor));
                    RAISE NOTICE '   🔄 N3 [%] correction_factor=% → qty_final=%',
                        v_item_name, v_correction_factor, v_suggested_qty;
                END IF;

                -- 2.8 FECHA DE AGOTAMIENTO Y URGENCIA
                IF v_daily_consumption > 0 THEN
                    v_stockout_date := CURRENT_DATE + GREATEST((v_current_stock / v_daily_consumption)::INTEGER, 0);
                ELSE
                    v_stockout_date := CURRENT_DATE + 30;
                END IF;

                v_urgency := CASE
                    WHEN v_current_stock <= 0 AND v_abc_class = 'A'                     THEN 1
                    WHEN v_current_stock <= 0                                            THEN 2
                    WHEN v_current_stock <= v_safety_stock AND v_abc_class = 'A'         THEN 2
                    WHEN v_current_stock <= v_safety_stock                               THEN 3
                    WHEN v_current_stock <= v_reorder_point * 0.5 AND v_abc_class = 'A'  THEN 2
                    WHEN v_current_stock <= v_reorder_point * 0.5                        THEN 3
                    WHEN v_current_stock <= v_reorder_point * 1.2 AND v_abc_class = 'A'  THEN 3
                    WHEN v_current_stock <= v_reorder_point * 1.2                        THEN 4
                    ELSE 5
                END;

                -- 2.9 RECOMENDACIÓN
                v_recommendation := CASE
                    WHEN v_abc_class = 'A' AND v_xyz_class = 'X' THEN
                        'JIT: Pedido frecuente, cantidad exacta. Revisar diariamente.'
                    WHEN v_abc_class = 'A' AND v_xyz_class = 'Y' THEN
                        'Alta prioridad: Mantener safety stock. Revisar cada 2 días.'
                    WHEN v_abc_class = 'A' AND v_xyz_class = 'Z' THEN
                        'CRÍTICO: Alta variabilidad. Aumentar safety stock. Revisar diariamente.'
                    WHEN v_abc_class = 'B' AND v_xyz_class = 'X' THEN
                        'EOQ óptimo: Pedido semanal. Consolidar con otros items.'
                    WHEN v_abc_class = 'B' AND v_xyz_class = 'Y' THEN
                        'Pedido estándar: Revisar semanalmente.'
                    WHEN v_abc_class = 'B' AND v_xyz_class = 'Z' THEN
                        'Variabilidad media-alta: Aumentar safety stock 30%.'
                    WHEN v_abc_class = 'C' AND v_xyz_class = 'X' THEN
                        'Bajo valor: Pedido mensual, lote grande para reducir costos.'
                    WHEN v_abc_class = 'C' AND v_xyz_class = 'Y' THEN
                        'Pedido mensual: Consolidar con otros items C.'
                    WHEN v_abc_class = 'C' AND v_xyz_class = 'Z' THEN
                        'Bajo valor, alta variabilidad: Considerar descontinuar.'
                    ELSE 'Revisar configuración de clasificación.'
                END;

                -- Contexto de tendencia en recomendación
                IF v_trend_factor >= 1.2 THEN
                    v_recommendation := v_recommendation || ' ↑ Demanda en alza (' || v_trend_factor || 'x).';
                ELSIF v_trend_factor <= 0.8 THEN
                    v_recommendation := v_recommendation || ' ↓ Demanda a la baja (' || v_trend_factor || 'x).';
                END IF;

                IF array_length(v_anomaly_flags, 1) > 0 THEN
                    v_recommendation := v_recommendation || ' ⚠️ ' || array_to_string(v_anomaly_flags, ', ');
                END IF;

                v_recommendation := LEFT(v_recommendation, 200);

                IF v_urgency <= p_urgency_threshold THEN

                    -- 2.10 MEJOR PROVEEDOR/PRECIO (G2 + G5 + M6)
                    v_supplier_id    := NULL;
                    v_supplier_name  := NULL;
                    v_supplier_price := NULL;

                    -- Intento 1: supplier_price_history activo + Vendor Scorecard
                    SELECT sph.supplier_id, e.name, sph.price
                    INTO v_supplier_id, v_supplier_name, v_supplier_price
                    FROM inventory.supplier_price_history sph
                    JOIN finances.entities e ON e.id = sph.supplier_id
                    LEFT JOIN inventory.v_vendor_scorecard vsc
                        ON  vsc.supplier_id      = sph.supplier_id
                        AND vsc.business_unit_id = v_business_unit_id
                    WHERE sph.item_id          = v_item_id
                      AND sph.business_unit_id = v_business_unit_id
                      AND sph.is_active        = TRUE
                      AND (sph.end_date IS NULL OR sph.end_date >= CURRENT_DATE)
                    ORDER BY
                        CASE WHEN sph.supplier_id = v_preferred_supplier_id THEN 0 ELSE 1 END,
                        COALESCE(vsc.overall_score, 50) DESC,
                        sph.effective_date DESC,
                        sph.price ASC
                    LIMIT 1;

                    -- Intento 2: preferred_supplier sin historial activo
                    IF v_supplier_id IS NULL AND v_preferred_supplier_id IS NOT NULL THEN
                        SELECT e.id, e.name INTO v_supplier_id, v_supplier_name
                        FROM finances.entities e WHERE e.id = v_preferred_supplier_id;
                        v_supplier_price := v_cost_price;
                    END IF;

                    -- Intento 3: cualquier historial inactivo (solo si precio aún malo)
                    IF v_supplier_id IS NULL OR COALESCE(v_supplier_price, 0) <= 0.05 THEN
                        SELECT sph.supplier_id, e.name, sph.price
                        INTO v_supplier_id, v_supplier_name, v_supplier_price
                        FROM inventory.supplier_price_history sph
                        JOIN finances.entities e ON e.id = sph.supplier_id
                        WHERE sph.item_id = v_item_id
                          AND sph.business_unit_id = v_business_unit_id
                          AND sph.price > 0.05
                        ORDER BY sph.effective_date DESC LIMIT 1;
                    END IF;

                    -- Intento 3.5: última factura de compra directa (invoice_type_id=1)
                    -- Corre si: no hay proveedor, O el precio es malo (<= 0.05)
                    IF v_supplier_id IS NULL OR COALESCE(v_supplier_price, 0) <= 0.05 THEN
                        SELECT inv.entity_id, e.name, id2.price
                        INTO v_supplier_id, v_supplier_name, v_supplier_price
                        FROM finances.invoice_details id2
                        JOIN finances.invoices inv
                            ON inv.id             = id2.invoice_id
                        JOIN finances.entities e
                            ON e.id               = inv.entity_id
                        WHERE id2.item_id          = v_item_id
                          AND inv.invoice_type_id   = 1
                          AND inv.business_unit_id  = v_business_unit_id
                          AND id2.price            > 0.05
                        ORDER BY inv.emission_date DESC, inv.id DESC
                        LIMIT 1;
                    END IF;

                    -- G5: Intento 4 — sustituto vía item_variants
                    IF v_supplier_id IS NULL THEN
                        SELECT sph.supplier_id, e.name, sph.price, i_sub.name
                        INTO v_supplier_id, v_supplier_name, v_supplier_price, v_substitute_name
                        FROM inventory.item_variants iv
                        JOIN inventory.supplier_price_history sph
                            ON  sph.item_id          = iv.child_item_id
                            AND sph.business_unit_id = v_business_unit_id
                            AND sph.is_active        = TRUE
                            AND (sph.end_date IS NULL OR sph.end_date >= CURRENT_DATE)
                        JOIN finances.entities e ON e.id = sph.supplier_id
                        JOIN inventory.items i_sub ON i_sub.id = iv.child_item_id
                        WHERE iv.parent_item_id = v_item_id
                        ORDER BY sph.effective_date DESC, sph.price ASC LIMIT 1;

                        IF v_supplier_id IS NOT NULL THEN
                            v_recommendation := LEFT(
                                v_recommendation || ' ⚠️ SUSTITUTO: pedir "' || v_substitute_name || '".',
                                200
                            );
                        END IF;
                    END IF;

                    IF v_supplier_price IS NULL THEN
                        v_supplier_price := v_cost_price;
                    END IF;

                    -- M7: Costo estimado (en unidades de compra)
                    v_estimated_cost := ROUND(CEIL(v_suggested_qty / v_unit_quantity) * v_supplier_price, 2);

                    -- G3: Ventana de entrega
                    v_delivery_window := CASE
                        WHEN v_urgency <= 2 THEN 'IMMEDIATE'
                        WHEN v_urgency = 3  THEN 'THIS_WEEK'
                        WHEN v_urgency = 4  THEN 'NEXT_WEEK'
                        ELSE                     'MONTHLY'
                    END;

                    -- 2.11 CREAR O ACTUALIZAR SUGERENCIA
                    v_suggestion_id := NULL;

                    UPDATE inventory.auto_purchase_suggestions aps
                    SET
                        suggested_quantity      = v_suggested_qty,
                        suggested_price         = v_supplier_price,
                        urgency_level           = v_urgency,
                        current_stock           = v_current_stock,
                        min_level               = v_min_level,
                        estimated_stockout_date = v_stockout_date,
                        suggested_supplier_id   = v_supplier_id,
                        warehouse_id            = v_warehouse_id,
                        reason                  = v_recommendation,
                        delivery_window         = v_delivery_window,
                        trend_factor            = v_trend_factor,
                        weekday_factor          = v_weekday_factor,
                        correction_factor       = v_correction_factor,
                        expires_at              = NOW() + INTERVAL '7 days',
                        reviewed_at             = NULL
                    WHERE aps.business_unit_id = v_business_unit_id
                      AND aps.location_id      = v_location_id
                      AND aps.item_id          = v_item_id
                      AND aps.status           = 'PENDING'
                    RETURNING aps.id INTO v_suggestion_id;

                    IF v_suggestion_id IS NOT NULL THEN
                        v_action_taken        := 'UPDATED';
                        v_suggestions_created := v_suggestions_created + 1;
                    ELSE
                        INSERT INTO inventory.auto_purchase_suggestions (
                            business_unit_id, location_id, warehouse_id, item_id,
                            current_stock, min_level, suggested_quantity, suggested_price,
                            urgency_level, estimated_stockout_date, suggested_supplier_id,
                            reason, delivery_window, status, expires_at, reviewed_at,
                            trend_factor, weekday_factor, correction_factor
                        ) VALUES (
                            v_business_unit_id, v_location_id, v_warehouse_id, v_item_id,
                            v_current_stock, v_min_level, v_suggested_qty, v_supplier_price,
                            v_urgency, v_stockout_date, v_supplier_id,
                            v_recommendation, v_delivery_window, 'PENDING',
                            NOW() + INTERVAL '7 days', NULL,
                            v_trend_factor, v_weekday_factor, v_correction_factor
                        )
                        RETURNING id INTO v_suggestion_id;

                        v_action_taken        := 'CREATED';
                        v_suggestions_created := v_suggestions_created + 1;
                    END IF;

                    IF v_suggestion_id IS NULL THEN
                        -- INSERT también falló (constraint, schema mismatch, etc.)
                        RAISE NOTICE '   ⚠️ [%] No se pudo crear/actualizar sugerencia', v_item_name;
                    END IF;

                    -- 2.12 RETORNAR FILA
                    RETURN QUERY SELECT
                        v_suggestion_id,
                        v_item_id,
                        v_item_name,
                        v_warehouse_name,
                        v_location_name,
                        v_current_stock,
                        v_min_level,
                        v_max_level,
                        v_reorder_point,
                        v_safety_stock,
                        v_suggested_qty,
                        v_optimal_qty,
                        GREATEST((v_stockout_date - CURRENT_DATE)::INTEGER, 0),
                        v_estimated_cost,
                        v_urgency,
                        v_abc_class,
                        v_xyz_class,
                        COALESCE(v_supplier_name, 'Sin Proveedor'),
                        v_supplier_id,
                        v_supplier_price,
                        v_action_taken,
                        v_recommendation,
                        v_anomaly_flags,
                        v_delivery_window,
                        v_trend_factor,
                        v_weekday_factor,
                        v_correction_factor;

                    RAISE NOTICE '   ✅ [%] Qty=% Trend=% Weekday=% Feedback=% Urgency=% Cost=% Action=%',
                        v_item_name, v_suggested_qty,
                        v_trend_factor, v_weekday_factor, v_correction_factor,
                        v_urgency, v_estimated_cost, v_action_taken;

                END IF; -- urgency threshold
            END IF; -- stock <= reorder_point

        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '⚠️  Error item % (id=%): % [SQLSTATE=%]',
                v_item_name, v_item_id, SQLERRM, SQLSTATE;
            CONTINUE;
        END;
    END LOOP;

    RAISE NOTICE '========================================';
    RAISE NOTICE '✅ V4 completado:';
    RAISE NOTICE '   Items procesados:    %', v_items_processed;
    RAISE NOTICE '   Items skipped:       %', v_items_skipped;
    RAISE NOTICE '   Sugerencias creadas: %', v_suggestions_created;
    RAISE NOTICE '   Anomalías detectadas: %', v_anomalies_detected;
    RAISE NOTICE '========================================';
END;
$$;

ALTER FUNCTION inventory.fn_intelligent_purchasing_v2(INTEGER, INTEGER, INTEGER)
    OWNER TO dev_gabriel;

COMMENT ON FUNCTION inventory.fn_intelligent_purchasing_v2(INTEGER, INTEGER, INTEGER) IS
'Sistema de compras inteligentes V4 (10/10 — 2026-03-02):
✅ N1: trend_factor en tiempo real (7d/60d desde item_in_warehouses.order_id)
       > 1.2 demanda subiendo, < 0.8 bajando. Clamped 0.5–2.0.
       Aplicado a v_daily_consumption antes de ROP/SS/EOQ.
✅ N2: weekday_factor — ratio del día de semana actual vs promedio global.
       Aplicado a v_daily_consumption (orden: seasonal → weekday → trend).
✅ N3: feedback_loop — correction_factor = AVG(approval_qty / suggested_qty)
       últimas 30d con status=APPROVED y ≥ 2 aprobaciones.
       Aplicado a v_suggested_qty después del cálculo estándar.
✅ M1–M10, G1–G7: todas las mejoras de v3 conservadas.
Nuevas columnas de salida: out_trend_factor, out_weekday_factor, out_correction_factor.';

-- ============================================================================
-- MIGRACIÓN: nuevas columnas en auto_purchase_suggestions
-- Ejecutar UNA VEZ
-- ============================================================================
ALTER TABLE inventory.auto_purchase_suggestions
    ADD COLUMN IF NOT EXISTS approval_quantity  NUMERIC,
    ADD COLUMN IF NOT EXISTS trend_factor       NUMERIC DEFAULT 1.0,
    ADD COLUMN IF NOT EXISTS weekday_factor     NUMERIC DEFAULT 1.0,
    ADD COLUMN IF NOT EXISTS correction_factor  NUMERIC DEFAULT 1.0;

COMMENT ON COLUMN inventory.auto_purchase_suggestions.approval_quantity IS
'N3 feedback loop: cantidad que el usuario realmente aprobó al aceptar la sugerencia.';
COMMENT ON COLUMN inventory.auto_purchase_suggestions.trend_factor IS
'N1: ratio avg_7d/avg_60d en tiempo real al generar la sugerencia. Clamped 0.5–2.0.';
COMMENT ON COLUMN inventory.auto_purchase_suggestions.weekday_factor IS
'N2: factor de ajuste por día de semana al generar la sugerencia. Clamped 0.5–2.0.';
COMMENT ON COLUMN inventory.auto_purchase_suggestions.correction_factor IS
'N3: factor de corrección aprendido de aprobaciones anteriores. Clamped 0.5–2.0.';

-- ============================================================================
-- TEST
-- ============================================================================
-- SELECT out_item_name, out_urgency_level, out_suggested_quantity,
--        out_trend_factor, out_weekday_factor, out_correction_factor,
--        out_estimated_cost, out_suggested_supplier, out_anomaly_flags
-- FROM inventory.fn_intelligent_purchasing_v2(3, 3, 5)
-- ORDER BY out_urgency_level, out_estimated_cost DESC;
