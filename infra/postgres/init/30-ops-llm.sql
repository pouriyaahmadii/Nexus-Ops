-- AutoForge / NexusOps - LLM Usage & Cost Tracking
-- Idempotent: safe to run multiple times.

-- ============================================================================
-- Model Pricing Table
-- ============================================================================

CREATE TABLE IF NOT EXISTS ops.model_pricing (
    id              BIGSERIAL PRIMARY KEY,
    provider        TEXT NOT NULL,
    model           TEXT NOT NULL,
    input_usd_per_1m      NUMERIC(12,6) NOT NULL,
    output_usd_per_1m     NUMERIC(12,6) NOT NULL,
    cached_input_usd_per_1m NUMERIC(12,6),
    valid_from      DATE NOT NULL DEFAULT CURRENT_DATE,
    valid_to        DATE,
    source_url      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (provider, model, valid_from)
);

CREATE INDEX IF NOT EXISTS idx_model_pricing_lookup
    ON ops.model_pricing (provider, model, valid_from, valid_to);

-- Seed with EXAMPLE placeholder prices - OPERATOR MUST VERIFY AND UPDATE FROM PROVIDER PRICING PAGES
-- These are NOT current prices. Check: https://openai.com/pricing, https://www.anthropic.com/pricing, https://ai.google.dev/pricing
INSERT INTO ops.model_pricing (provider, model, input_usd_per_1m, output_usd_per_1m, cached_input_usd_per_1m, valid_from, source_url, created_at) VALUES
-- OpenAI (EXAMPLE - verify at https://openai.com/pricing)
('openai', 'gpt-4o', 5.00, 15.00, 2.50, '2024-05-01', 'https://openai.com/pricing', NOW()),
('openai', 'gpt-4o-mini', 0.15, 0.60, 0.075, '2024-07-01', 'https://openai.com/pricing', NOW()),
('openai', 'gpt-4-turbo', 10.00, 30.00, NULL, '2024-01-01', 'https://openai.com/pricing', NOW()),
('openai', 'gpt-3.5-turbo', 0.50, 1.50, NULL, '2024-01-01', 'https://openai.com/pricing', NOW()),
('openai', 'text-embedding-3-small', 0.02, 0.02, NULL, '2024-01-01', 'https://openai.com/pricing', NOW()),
('openai', 'text-embedding-3-large', 0.13, 0.13, NULL, '2024-01-01', 'https://openai.com/pricing', NOW()),

-- Anthropic (EXAMPLE - verify at https://www.anthropic.com/pricing)
('anthropic', 'claude-3-5-sonnet-20241022', 3.00, 15.00, NULL, '2024-10-01', 'https://www.anthropic.com/pricing', NOW()),
('anthropic', 'claude-3-5-haiku-20241022', 0.25, 1.25, NULL, '2024-10-01', 'https://www.anthropic.com/pricing', NOW()),
('anthropic', 'claude-3-opus-20240229', 15.00, 75.00, NULL, '2024-02-01', 'https://www.anthropic.com/pricing', NOW()),
('anthropic', 'claude-3-sonnet-20240229', 3.00, 15.00, NULL, '2024-02-01', 'https://www.anthropic.com/pricing', NOW()),
('anthropic', 'claude-3-haiku-20240307', 0.25, 1.25, NULL, '2024-03-01', 'https://www.anthropic.com/pricing', NOW()),

-- Google Gemini (EXAMPLE - verify at https://ai.google.dev/pricing)
('google', 'gemini-1.5-pro', 3.50, 10.50, NULL, '2024-05-01', 'https://ai.google.dev/pricing', NOW()),
('google', 'gemini-1.5-flash', 0.075, 0.30, NULL, '2024-05-01', 'https://ai.google.dev/pricing', NOW()),
('google', 'gemini-1.0-pro', 0.50, 1.50, NULL, '2024-02-01', 'https://ai.google.dev/pricing', NOW()),

-- Local/Other (EXAMPLE - verify actual costs)
('ollama', 'llama3.1:8b', 0.00, 0.00, NULL, '2024-01-01', 'local', NOW()),
('ollama', 'llama3.1:70b', 0.00, 0.00, NULL, '2024-01-01', 'local', NOW())
ON CONFLICT (provider, model, valid_from) DO NOTHING;

-- ============================================================================
-- LLM Usage Ledger
-- ============================================================================

CREATE TABLE IF NOT EXISTS ops.llm_usage (
    id                  BIGSERIAL PRIMARY KEY,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    workflow_id         TEXT NOT NULL,
    workflow_name       TEXT NOT NULL,
    execution_id        TEXT NOT NULL,
    node_name           TEXT NOT NULL,
    provider            TEXT NOT NULL,
    model               TEXT NOT NULL,
    input_tokens        BIGINT NOT NULL DEFAULT 0,
    output_tokens       BIGINT NOT NULL DEFAULT 0,
    cached_tokens       BIGINT NOT NULL DEFAULT 0,
    latency_ms          BIGINT,
    status              TEXT NOT NULL DEFAULT 'success'
        CHECK (status IN ('success', 'error', 'partial')),
    input_cost_usd      NUMERIC(18,6),
    output_cost_usd     NUMERIC(18,6),
    total_cost_usd      NUMERIC(18,6),
    correlation_id      TEXT,
    metadata            JSONB NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_llm_usage_created_at
    ON ops.llm_usage (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_llm_usage_workflow_execution
    ON ops.llm_usage (workflow_id, execution_id);

CREATE INDEX IF NOT EXISTS idx_llm_usage_provider_model
    ON ops.llm_usage (provider, model);

CREATE INDEX IF NOT EXISTS idx_llm_usage_correlation
    ON ops.llm_usage (correlation_id);

-- ============================================================================
-- Cost Computation Function
-- ============================================================================

CREATE OR REPLACE FUNCTION ops.fn_compute_llm_cost(
    p_provider TEXT,
    p_model TEXT,
    p_input_tokens BIGINT,
    p_output_tokens BIGINT,
    p_cached_tokens BIGINT DEFAULT 0,
    p_created_at TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
    input_cost_usd NUMERIC(18,6),
    output_cost_usd NUMERIC(18,6),
    total_cost_usd NUMERIC(18,6),
    pricing_found BOOLEAN,
    pricing_valid_from DATE,
    pricing_source_url TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pricing RECORD;
    v_input_cost NUMERIC(18,6) := 0;
    v_output_cost NUMERIC(18,6) := 0;
    v_cached_cost NUMERIC(18,6) := 0;
BEGIN
    -- Find pricing row valid at the usage timestamp
    SELECT * INTO v_pricing
    FROM ops.model_pricing
    WHERE provider = p_provider
      AND model = p_model
      AND valid_from <= p_created_at::date
      AND (valid_to IS NULL OR valid_to >= p_created_at::date)
    ORDER BY valid_from DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            0::NUMERIC(18,6) AS input_cost_usd,
            0::NUMERIC(18,6) AS output_cost_usd,
            0::NUMERIC(18,6) AS total_cost_usd,
            FALSE AS pricing_found,
            NULL::DATE AS pricing_valid_from,
            NULL::TEXT AS pricing_source_url;
        RETURN;
    END IF;

    -- Compute costs: (tokens / 1_000_000) * price_per_1m
    v_input_cost := (p_input_tokens::NUMERIC / 1000000.0) * v_pricing.input_usd_per_1m;
    
    -- Cached input tokens are billed at cached rate if available, else regular input rate
    IF p_cached_tokens > 0 AND v_pricing.cached_input_usd_per_1m IS NOT NULL THEN
        v_cached_cost := (p_cached_tokens::NUMERIC / 1000000.0) * v_pricing.cached_input_usd_per_1m;
        v_input_cost := v_input_cost + v_cached_cost;
    ELSIF p_cached_tokens > 0 THEN
        -- No cached rate, bill at regular rate
        v_input_cost := v_input_cost + (p_cached_tokens::NUMERIC / 1000000.0) * v_pricing.input_usd_per_1m;
    END IF;

    v_output_cost := (p_output_tokens::NUMERIC / 1000000.0) * v_pricing.output_usd_per_1m;

    RETURN QUERY SELECT
        v_input_cost,
        v_output_cost,
        (v_input_cost + v_output_cost) AS total_cost_usd,
        TRUE AS pricing_found,
        v_pricing.valid_from,
        v_pricing.source_url;
END;
$$;

-- ============================================================================
-- Trigger Function to Auto-Compute Costs on Insert
-- ============================================================================

CREATE OR REPLACE FUNCTION ops.trg_compute_llm_cost()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_result RECORD;
BEGIN
    -- Only compute if costs are NULL (allow manual override)
    IF NEW.input_cost_usd IS NULL OR NEW.output_cost_usd IS NULL OR NEW.total_cost_usd IS NULL THEN
        SELECT * INTO v_result
        FROM ops.fn_compute_llm_cost(
            NEW.provider,
            NEW.model,
            NEW.input_tokens,
            NEW.output_tokens,
            NEW.cached_tokens,
            NEW.created_at
        );
        
        NEW.input_cost_usd := v_result.input_cost_usd;
        NEW.output_cost_usd := v_result.output_cost_usd;
        NEW.total_cost_usd := v_result.total_cost_usd;
        
        -- Flag if pricing not found
        IF NOT v_result.pricing_found THEN
            NEW.metadata := NEW.metadata || jsonb_build_object('pricing_missing', TRUE);
        ELSE
            NEW.metadata := NEW.metadata || jsonb_build_object(
                'pricing_valid_from', v_result.pricing_valid_from::TEXT,
                'pricing_source_url', v_result.pricing_source_url
            );
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_llm_usage_compute_cost ON ops.llm_usage;
CREATE TRIGGER trg_llm_usage_compute_cost
    BEFORE INSERT ON ops.llm_usage
    FOR EACH ROW
    EXECUTE FUNCTION ops.trg_compute_llm_cost();

-- ============================================================================
-- Grants for ops_writer
-- ============================================================================

GRANT SELECT, INSERT, UPDATE ON ops.llm_usage TO ops_writer;
GRANT USAGE, SELECT ON SEQUENCE ops.llm_usage_id_seq TO ops_writer;
GRANT SELECT ON ops.model_pricing TO ops_writer;
GRANT EXECUTE ON FUNCTION ops.fn_compute_llm_cost TO ops_writer;

-- ============================================================================
-- Views
-- ============================================================================

-- Daily cost summary
CREATE OR REPLACE VIEW ops.v_llm_cost_daily AS
SELECT
    DATE(created_at) AS cost_date,
    provider,
    model,
    COUNT(*) AS call_count,
    SUM(input_tokens) AS total_input_tokens,
    SUM(output_tokens) AS total_output_tokens,
    SUM(cached_tokens) AS total_cached_tokens,
    SUM(input_cost_usd) AS total_input_cost_usd,
    SUM(output_cost_usd) AS total_output_cost_usd,
    SUM(total_cost_usd) AS total_cost_usd,
    AVG(latency_ms) AS avg_latency_ms
FROM ops.llm_usage
WHERE status = 'success'
GROUP BY DATE(created_at), provider, model
ORDER BY cost_date DESC, total_cost_usd DESC;

-- Cost by workflow
CREATE OR REPLACE VIEW ops.v_llm_cost_by_workflow AS
SELECT
    workflow_id,
    workflow_name,
    provider,
    model,
    COUNT(*) AS call_count,
    SUM(input_tokens) AS total_input_tokens,
    SUM(output_tokens) AS total_output_tokens,
    SUM(cached_tokens) AS total_cached_tokens,
    SUM(input_cost_usd) AS total_input_cost_usd,
    SUM(output_cost_usd) AS total_output_cost_usd,
    SUM(total_cost_usd) AS total_cost_usd,
    MIN(created_at) AS first_call,
    MAX(created_at) AS last_call
FROM ops.llm_usage
WHERE status = 'success'
GROUP BY workflow_id, workflow_name, provider, model
ORDER BY total_cost_usd DESC;

-- Month-to-date cost
CREATE OR REPLACE VIEW ops.v_llm_cost_month_to_date AS
SELECT
    DATE_TRUNC('month', created_at)::DATE AS month_start,
    provider,
    model,
    COUNT(*) AS call_count,
    SUM(input_tokens) AS total_input_tokens,
    SUM(output_tokens) AS total_output_tokens,
    SUM(cached_tokens) AS total_cached_tokens,
    SUM(input_cost_usd) AS total_input_cost_usd,
    SUM(output_cost_usd) AS total_output_cost_usd,
    SUM(total_cost_usd) AS total_cost_usd
FROM ops.llm_usage
WHERE status = 'success'
  AND created_at >= DATE_TRUNC('month', NOW())
GROUP BY DATE_TRUNC('month', created_at), provider, model
ORDER BY month_start DESC, total_cost_usd DESC;

GRANT SELECT ON ops.v_llm_cost_daily TO ops_writer;
GRANT SELECT ON ops.v_llm_cost_by_workflow TO ops_writer;
GRANT SELECT ON ops.v_llm_cost_month_to_date TO ops_writer;