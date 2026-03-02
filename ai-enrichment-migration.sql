-- ============================================================================
-- MIGRACIÓN: columnas AI en auto_purchase_suggestions
-- Ejecutar UNA VEZ en cada ambiente (local + producción)
-- Microservicio: purchasing-ai (FastAPI / Prophet / GPT-4o mini)
-- ============================================================================

ALTER TABLE inventory.auto_purchase_suggestions
    ADD COLUMN IF NOT EXISTS ai_predicted_demand   NUMERIC,
    ADD COLUMN IF NOT EXISTS ai_confidence_low     NUMERIC,
    ADD COLUMN IF NOT EXISTS ai_confidence_high    NUMERIC,
    ADD COLUMN IF NOT EXISTS ai_trend_direction    TEXT,       -- 'UP' | 'DOWN' | 'STABLE'
    ADD COLUMN IF NOT EXISTS ai_peak_day           TEXT,       -- 'FRIDAY' | 'SATURDAY' etc.
    ADD COLUMN IF NOT EXISTS ai_reason             TEXT,       -- LLM explanation in Spanish
    ADD COLUMN IF NOT EXISTS ai_anomaly_score      NUMERIC,    -- 0–1, calidad del historial
    ADD COLUMN IF NOT EXISTS ai_model_used         TEXT,       -- 'prophet' | 'fallback_wma'
    ADD COLUMN IF NOT EXISTS ai_enriched_at        TIMESTAMPTZ;

COMMENT ON COLUMN inventory.auto_purchase_suggestions.ai_predicted_demand
    IS 'Prophet/WMA predicted demand for next 14 days from purchasing-ai microservice';
COMMENT ON COLUMN inventory.auto_purchase_suggestions.ai_confidence_low
    IS 'Lower bound of Prophet prediction interval (80%)';
COMMENT ON COLUMN inventory.auto_purchase_suggestions.ai_confidence_high
    IS 'Upper bound of Prophet prediction interval (80%)';
COMMENT ON COLUMN inventory.auto_purchase_suggestions.ai_trend_direction
    IS 'AI trend direction: UP | DOWN | STABLE (from Prophet forecast)';
COMMENT ON COLUMN inventory.auto_purchase_suggestions.ai_peak_day
    IS 'Day of week with highest demand seasonality (e.g. FRIDAY)';
COMMENT ON COLUMN inventory.auto_purchase_suggestions.ai_reason
    IS 'LLM-generated explanation in Spanish (GPT-4o mini) for why this item needs to be ordered';
COMMENT ON COLUMN inventory.auto_purchase_suggestions.ai_anomaly_score
    IS 'Isolation Forest data quality score: 1.0 = clean history, <0.8 = unreliable';
COMMENT ON COLUMN inventory.auto_purchase_suggestions.ai_model_used
    IS 'Forecast model used: prophet (>=14 data points) or fallback_wma';
COMMENT ON COLUMN inventory.auto_purchase_suggestions.ai_enriched_at
    IS 'Timestamp when the AI microservice last enriched this suggestion';
