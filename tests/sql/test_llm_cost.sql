-- Unit-style SQL tests for LLM cost computation
-- Run with: psql -U nexusops -d nexusops -f tests/sql/test_llm_cost.sql

\set ON_ERROR_STOP on

-- ============================================================================
-- Setup: Ensure test schema exists and seed test pricing
-- ============================================================================

-- Clean any existing test pricing
DELETE FROM ops.model_pricing WHERE provider = 'test_provider';

-- Seed test pricing (valid from 2024-01-01)
INSERT INTO ops.model_pricing (provider, model, input_usd_per_1m, output_usd_per_1m, cached_input_usd_per_1m, valid_from, source_url) VALUES
('test_provider', 'test-model-v1', 10.00, 20.00, 5.00, '2024-01-01', 'test'),
('test_provider', 'test-model-v2', 5.00, 15.00, NULL, '2024-01-01', 'test'),
('test_provider', 'test-model-price-change', 100.00, 200.00, NULL, '2024-01-01', 'test'),
('test_provider', 'test-model-price-change', 10.00, 20.00, NULL, '2024-07-01', 'test')  -- new price from July
ON CONFLICT (provider, model, valid_from) DO NOTHING;

-- ============================================================================
-- Test 1: Basic cost computation (1M input, 500k output)
-- Expected: input = (1_000_000/1_000_000) * 10 = $10.00
--           output = (500_000/1_000_000) * 20 = $10.00
--           total = $20.00
-- ============================================================================

SELECT 'Test 1: Basic cost' AS test_name;
SELECT * FROM ops.fn_compute_llm_cost(
    'test_provider', 'test-model-v1',
    1000000, 500000, 0, '2024-06-15 12:00:00+00'
);
-- ASSERT: input_cost_usd = 10.00, output_cost_usd = 10.00, total_cost_usd = 20.00
-- ASSERT: pricing_found = true

-- ============================================================================
-- Test 2: With cached tokens (uses cached rate when available)
-- Expected: input = 10.00, cached = (200_000/1_000_000) * 5 = $1.00
--           total input = 11.00, output = 10.00, total = 21.00
-- ============================================================================

SELECT 'Test 2: Cached tokens' AS test_name;
SELECT * FROM ops.fn_compute_llm_cost(
    'test_provider', 'test-model-v1',
    1000000, 500000, 200000, '2024-06-15 12:00:00+00'
);
-- ASSERT: input_cost_usd = 11.00, output_cost_usd = 10.00, total_cost_usd = 21.00

-- ============================================================================
-- Test 3: Cached tokens but no cached rate (falls back to input rate)
-- Expected: cached billed at regular input rate: (200_000/1_000_000) * 10 = $2.00
--           total input = 12.00
-- ============================================================================

SELECT 'Test 3: Cached no cached rate' AS test_name;
SELECT * FROM ops.fn_compute_llm_cost(
    'test_provider', 'test-model-v2',  -- no cached_input_usd_per_1m
    1000000, 500000, 200000, '2024-06-15 12:00:00+00'
);
-- ASSERT: input_cost_usd = 12.00, output_cost_usd = 7.50, total_cost_usd = 19.50

-- ============================================================================
-- Test 4: Zero tokens
-- Expected: all costs = 0, pricing_found = true
-- ============================================================================

SELECT 'Test 4: Zero tokens' AS test_name;
SELECT * FROM ops.fn_compute_llm_cost(
    'test_provider', 'test-model-v1',
    0, 0, 0, '2024-06-15 12:00:00+00'
);
-- ASSERT: input_cost_usd = 0, output_cost_usd = 0, total_cost_usd = 0
-- ASSERT: pricing_found = true

-- ============================================================================
-- Test 5: Missing pricing row (should flag, not crash)
-- Expected: all costs = 0, pricing_found = false
-- ============================================================================

SELECT 'Test 5: Missing pricing' AS test_name;
SELECT * FROM ops.fn_compute_llm_cost(
    'test_provider', 'non-existent-model',
    1000000, 500000, 0, '2024-06-15 12:00:00+00'
);
-- ASSERT: input_cost_usd = 0, output_cost_usd = 0, total_cost_usd = 0
-- ASSERT: pricing_found = false

-- ============================================================================
-- Test 6: Price change mid-month (valid_to logic)
-- Old price valid until 2024-06-30, new price from 2024-07-01
-- Query on 2024-06-15 → should use old price ($100/$200)
-- Query on 2024-07-15 → should use new price ($10/$20)
-- ============================================================================

SELECT 'Test 6a: Old price (June)' AS test_name;
SELECT * FROM ops.fn_compute_llm_cost(
    'test_provider', 'test-model-price-change',
    1000000, 1000000, 0, '2024-06-15 12:00:00+00'
);
-- ASSERT: total_cost_usd = 300.00 (100 + 200)

SELECT 'Test 6b: New price (July)' AS test_name;
SELECT * FROM ops.fn_compute_llm_cost(
    'test_provider', 'test-model-price-change',
    1000000, 1000000, 0, '2024-07-15 12:00:00+00'
);
-- ASSERT: total_cost_usd = 30.00 (10 + 20)

-- ============================================================================
-- Test 7: Trigger on insert computes costs automatically
-- ============================================================================

SELECT 'Test 7: Trigger on insert' AS test_name;

-- Insert a usage record (costs will be auto-computed by trigger)
INSERT INTO ops.llm_usage (
    workflow_id, workflow_name, execution_id, node_name,
    provider, model, input_tokens, output_tokens, cached_tokens,
    status, correlation_id
) VALUES (
    'wf-test-1', 'Test Workflow', 'exec-test-1', 'Test Node',
    'test_provider', 'test-model-v1',
    1000000, 500000, 0,
    'success', 'test-corr-1'
) RETURNING id, input_cost_usd, output_cost_usd, total_cost_usd, metadata;

-- ASSERT: input_cost_usd = 10.00, output_cost_usd = 10.00, total_cost_usd = 20.00
-- ASSERT: metadata.pricing_valid_from = '2024-01-01'

-- Clean up
DELETE FROM ops.llm_usage WHERE correlation_id = 'test-corr-1';

-- ============================================================================
-- Test 8: Insert with missing pricing flags metadata
-- ============================================================================

SELECT 'Test 8: Missing pricing flags metadata' AS test_name;

INSERT INTO ops.llm_usage (
    workflow_id, workflow_name, execution_id, node_name,
    provider, model, input_tokens, output_tokens,
    status, correlation_id
) VALUES (
    'wf-test-2', 'Test Workflow', 'exec-test-2', 'Test Node',
    'test_provider', 'non-existent-model',
    1000, 500,
    'success', 'test-corr-2'
) RETURNING id, input_cost_usd, output_cost_usd, total_cost_usd, metadata;

-- ASSERT: all costs = 0
-- ASSERT: metadata.pricing_missing = true

-- Clean up
DELETE FROM ops.llm_usage WHERE correlation_id = 'test-corr-2';

-- ============================================================================
-- Test 9: View v_llm_cost_daily aggregation
-- ============================================================================

SELECT 'Test 9: Daily view aggregation' AS test_name;

-- Insert test data for a specific day
INSERT INTO ops.llm_usage (
    workflow_id, workflow_name, execution_id, node_name,
    provider, model, input_tokens, output_tokens, cached_tokens,
    input_cost_usd, output_cost_usd, total_cost_usd,
    status, created_at
) VALUES
    ('wf-a', 'Workflow A', 'exec-1', 'Node 1', 'test_provider', 'test-model-v1', 1000000, 500000, 0, 10.00, 10.00, 20.00, 'success', '2024-06-15 10:00:00+00'),
    ('wf-a', 'Workflow A', 'exec-2', 'Node 2', 'test_provider', 'test-model-v1', 2000000, 1000000, 0, 20.00, 20.00, 40.00, 'success', '2024-06-15 14:00:00+00'),
    ('wf-b', 'Workflow B', 'exec-3', 'Node 1', 'test_provider', 'test-model-v2', 500000, 250000, 0, 2.50, 3.75, 6.25, 'success', '2024-06-15 16:00:00+00')
ON CONFLICT DO NOTHING;

SELECT * FROM ops.v_llm_cost_daily WHERE cost_date = '2024-06-15';
-- ASSERT: 2 rows (one per provider/model)
-- ASSERT: test-model-v1: call_count=2, total_cost_usd=60.00
-- ASSERT: test-model-v2: call_count=1, total_cost_usd=6.25

-- Clean up
DELETE FROM ops.llm_usage WHERE workflow_id IN ('wf-a', 'wf-b');

-- ============================================================================
-- Test 10: View v_llm_cost_by_workflow
-- ============================================================================

SELECT 'Test 10: By workflow view' AS test_name;

INSERT INTO ops.llm_usage (
    workflow_id, workflow_name, execution_id, node_name,
    provider, model, input_tokens, output_tokens,
    input_cost_usd, output_cost_usd, total_cost_usd,
    status, created_at
) VALUES
    ('wf-cost-1', 'Expensive Workflow', 'exec-1', 'LLM', 'test_provider', 'test-model-v1', 1000000, 500000, 10.00, 10.00, 20.00, 'success', '2024-06-15 10:00:00+00'),
    ('wf-cost-1', 'Expensive Workflow', 'exec-2', 'LLM', 'test_provider', 'test-model-v1', 1000000, 500000, 10.00, 10.00, 20.00, 'success', '2024-06-16 10:00:00+00'),
    ('wf-cost-2', 'Cheap Workflow', 'exec-3', 'LLM', 'test_provider', 'test-model-v2', 100000, 50000, 0.50, 0.75, 1.25, 'success', '2024-06-15 10:00:00+00')
ON CONFLICT DO NOTHING;

SELECT * FROM ops.v_llm_cost_by_workflow WHERE workflow_id IN ('wf-cost-1', 'wf-cost-2');
-- ASSERT: wf-cost-1 total_cost_usd = 40.00, call_count = 2
-- ASSERT: wf-cost-2 total_cost_usd = 1.25, call_count = 1
-- ASSERT: ordered by total_cost_usd DESC (wf-cost-1 first)

-- Clean up
DELETE FROM ops.llm_usage WHERE workflow_id IN ('wf-cost-1', 'wf-cost-2');

-- ============================================================================
-- Test 11: View v_llm_cost_month_to_date
-- ============================================================================

SELECT 'Test 11: MTD view' AS test_name;

-- This view filters to current month, so we can't easily test historical
-- But we can verify it runs without error
SELECT * FROM ops.v_llm_cost_month_to_date LIMIT 5;

-- ============================================================================
-- Test 12: Decimal precision (6 decimal places)
-- ============================================================================

SELECT 'Test 12: Decimal precision' AS test_name;

SELECT * FROM ops.fn_compute_llm_cost(
    'test_provider', 'test-model-v1',
    123456, 78901, 0, '2024-06-15'
);
-- ASSERT: costs have 6 decimal places
-- input = 123456/1_000_000 * 10 = 1.234560
-- output = 78901/1_000_000 * 20 = 1.578020
-- total = 2.812580

-- ============================================================================
-- Summary
-- ============================================================================

SELECT 'All tests completed. Check assertions above.' AS summary;