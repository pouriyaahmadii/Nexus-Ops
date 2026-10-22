# NexusOps Testing Guide

## Overview

This document describes the test suite for NexusOps, including how to run tests, what each layer covers, and how to add new tests.

## Test Layers

| Layer | Location | Language | Runtime | Purpose |
|-------|----------|----------|---------|---------|
| Smoke | `tests/smoke/` | Bash | ~30s | Basic health checks against running stack |
| Integration | `tests/integration/` | Python (pytest) | ~2-5 min | End-to-end workflow tests |
| SQL | `tests/sql/` | SQL | ~10s | Cost function, views, triggers |
| Restore | `tests/restore/` | Bash | ~2-5 min | Backup/restore drill verification |

## Running Tests

### Quick Smoke Tests (fastest)
```bash
make test-fast
# or
./tests/smoke/smoke.sh
```

### Full Test Suite
```bash
make test
```

### Specific Layers
```bash
# Smoke only
make test-smoke

# Integration (requires pytest)
make test-integration

# SQL tests
make test-sql

# Restore drill
make test-restore
```

### With Docker (CI-like)
```bash
# Run all tests in isolated container
docker compose -p nexusops-test -f compose.yaml up -d --wait
make test
docker compose -p nexusops-test -f compose.yaml down -v
```

## Test Matrix

| Promise | Test | Layer |
|---------|------|-------|
| All containers healthy | `test_containers_healthy` | Smoke |
| n8n responds | `test_n8n_responds` | Smoke |
| Webhook route reachable | `test_webhook_reachable` | Smoke |
| Traefik dashboard auth | `test_traefik_dashboard_auth` | Smoke |
| Security headers present | `test_security_headers` | Smoke |
| Qdrant requires API key | `test_qdrant_api_key` | Smoke |
| Postgres internal only | `test_postgres_not_reachable_from_host` | Smoke |
| Redis internal only | `test_redis_not_reachable_from_host` | Smoke |
| Error handler creates DLQ | `test_chaos_workflow_creates_dlq_entry` | Integration |
| Alert deduplication | `test_global_error_handler_dedupe` | Integration |
| Retry on 5xx | `test_retry_with_backoff_retries_on_5xx` | Integration |
| Exponential backoff timing | `test_retry_exponential_backoff_timing` | Integration |
| Retry-After header | `test_retry_respects_retry_after_header` | Integration |
| Demo creates usage rows | `test_demo_creates_usage_rows` | Integration |
| Cost = tokens × pricing | `test_cost_computation_matches_pricing` | Integration |
| Budget guard at 80% | `test_budget_guard_warning_at_80_percent` | Integration |
| Approval creates row | `test_request_approval_creates_row` | Integration |
| Approve callback | `test_approval_callback_approve` | Integration |
| Reject callback | `test_approval_callback_reject` | Integration |
| Unauthorized blocked | `test_unauthorized_user_cannot_decide` | Integration |
| Double-click rejected | `test_double_click_rejected` | Integration |
| Timeout escalates | `test_timeout_escalates_to_secondary` | Integration |
| Parallel executions distributed | `test_parallel_executions_distributed` | Integration |
| Webhook processor separate | `test_webhook_processor_separate_from_main` | Integration |
| Backup produces encrypted artifacts | `test_backup_encryption` | Restore |
| Manifest created and valid | `test_manifest` | Restore |
| Corruption detected | `test_corruption_detection` | Restore |
| Full restore drill passes | `run_restore_test` | Restore |
| Cost function basic math | Test 1-4 | SQL |
| Cached tokens handled | Test 2-3 | SQL |
| Missing pricing flagged | Test 5 | SQL |
| Price change mid-month | Test 6 | SQL |
| Trigger auto-computes | Test 7 | SQL |
| Missing pricing flags metadata | Test 8 | SQL |
| Daily view aggregation | Test 9 | SQL |
| By-workflow view | Test 10 | SQL |
| MTD view | Test 11 | SQL |
| Decimal precision | Test 12 | SQL |

## Adding Tests

### Smoke Tests (Bash)
Add to `tests/smoke/smoke.sh`:

```bash
test_my_new_check() {
    if some_condition; then
        pass "My new check"
    else
        fail "My new check failed"
    fi
}

# Add to main():
test_my_new_check
```

### Integration Tests (Python/pytest)
Add to `tests/integration/test_integration.py`:

```python
@pytest.mark.integration
@pytest.mark.myfeature
class TestMyFeature:
    
    async def test_something(self, config, webhook_client, query_postgres):
        # Arrange
        correlation_id = f"test_{int(time.time())}"
        
        # Act
        resp = await webhook_client.post_triage(
            text="Test input",
            correlation_id=correlation_id
        )
        
        # Assert
        assert resp.status_code == 200
        data = resp.json()
        assert data["success"] is True
```

### SQL Tests
Add to `tests/sql/test_llm_cost.sql`:

```sql
SELECT 'Test N: Description' AS test_name;
SELECT * FROM ops.fn_compute_llm_cost(...);
-- ASSERT: expected values
```

### Restore Tests
Add to `tests/restore/restore_test.sh`:

```bash
test_my_restore_check() {
    log "Testing my restore check..."
    # verification logic
    if condition; then
        pass "My restore check"
    else
        fail "My restore check failed"
    fi
}
```

## Fixtures and Utilities

### Python Fixtures (`tests/conftest.py`)
- `config` - TestConfig with all URLs and credentials
- `docker_client` - Docker SDK client
- `http_client` / `sync_http_client` - HTTPX clients
- `webhook_client` - WebhookClient for triage endpoint
- `n8n_client` - N8NAPIClient for n8n REST API
- `mock_telegram` - MockTelegramServer for approval/alert testing
- `query_postgres` - Async function to query test Postgres

### Bash Utilities
- `wait_healthy()` - Wait for URL to return 200
- `random_string()`, `random_email()`, `random_correlation_id()` - Test data generators

## Running in CI

The CI pipeline (`.github/workflows/ci.yml`) runs:

1. **lint** - All linting
2. **n8n-workflows** - Workflow JSON validation
3. **smoke** - Full stack up, health checks, demo webhook
4. **restore-drill** - Backup + restore-test (weekly + label)
5. **sql-tests** - SQL unit tests

## Known Gaps

| Area | Gap | Planned |
|------|-----|---------|
| n8n API access | Tests need `N8N_API_KEY` for workflow execution | Add test API key to CI |
| Worker distribution | Can't verify which worker handled execution | n8n API enhancement |
| Approval escalation | Requires shortened timeout + time | Test with `timeout_minutes=1` |
| Budget guard | Needs time to accumulate spend | Mock time or run long |
| Chaos engineering | No network partition / pod kill tests | Add `chaos-mesh` or similar |
| Load testing | No sustained load tests | Add `k6` or `locust` |
| E2E UI tests | No browser automation | Add `playwright` |

## Test Data Management

- Tests use `correlation_id` prefix `test_` for isolation
- SQL tests clean up after themselves
- Integration tests use unique correlation IDs
- Smoke tests are read-only (mostly)

## Debugging Failed Tests

```bash
# Run single smoke test
./tests/smoke/smoke.sh

# Run single pytest with output
pytest tests/integration/test_integration.py::TestErrorHandling::test_chaos_workflow_creates_dlq_entry -v -s

# Check logs
docker compose -p nexusops logs n8n-main

# Check database
docker exec nexusops_postgres psql -U nexusops -d nexusops -c "SELECT * FROM ops.dead_letters;"

# Check n8n executions via API
curl -H "X-N8N-API-KEY: $N8N_API_KEY" http://localhost:5678/api/v1/executions
```

## Test Run Times

| Command | Expected Time |
|---------|---------------|
| `make test-fast` | ~30 seconds |
| `make test-smoke` | ~30 seconds |
| `make test-integration` | 2-5 minutes |
| `make test-sql` | ~10 seconds |
| `make test-restore` | 2-5 minutes |
| `make test` (all) | 5-10 minutes |

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `pytest` not found | `pip install pytest pytest-asyncio httpx docker asyncpg` |
| Stack not running | `make up` and wait for `make doctor` to pass |
| Port conflicts | Ensure ports 80, 5678, 6333, 8080, 8443 free |
| Permission denied | Run `chmod +x tests/smoke/smoke.sh tests/restore/restore_test.sh` |
| Database connection refused | Check `POSTGRES_PASSWORD` in `.env` matches running container |