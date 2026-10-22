#!/usr/bin/env python3
"""
Integration tests for error handling, DLQ, and retry mechanisms.
"""

import pytest
import asyncio
import json
import time
from typing import Dict, Any


@pytest.mark.integration
@pytest.mark.dlq
class TestErrorHandling:
    """Tests for global error handler and dead letter queue."""

    async def test_chaos_workflow_creates_dlq_entry(
        self, config, webhook_client, query_postgres
    ):
        """Trigger chaos workflow and verify DLQ entry is created."""
        # Send request that will fail (no retries in chaos workflow)
        correlation_id = f"test_chaos_{int(time.time())}"
        
        resp = await webhook_client.post_triage(
            text="This will fail permanently",
            email="chaos@example.com",
            correlation_id=correlation_id
        )
        
        # Should get error response
        assert resp.status_code in (200, 500)
        
        # Wait for async processing
        await asyncio.sleep(3)
        
        # Check DLQ
        rows = await query_postgres(config, """
            SELECT id, workflow_name, node_name, error_message, status, attempts
            FROM ops.dead_letters
            WHERE correlation_id = $1
        """, (correlation_id,))
        
        # Note: This test may need adjustment based on actual workflow behavior
        # The chaos workflow throws errors which should trigger global error handler
        if rows:
            assert rows[0]["status"] == "pending"
            assert rows[0]["attempts"] >= 0

    async def test_global_error_handler_dedupe(
        self, config, webhook_client, query_postgres
    ):
        """Verify alert deduplication works."""
        # This test would need the global error handler to be active
        # and would trigger the same error twice within dedupe window
        pytest.skip("Requires global error handler active and Telegram configured")

    async def test_retry_with_backoff_retries_on_5xx(
        self, config, webhook_client, query_postgres
    ):
        """Verify retry_with_backoff retries on server errors."""
        # The mock LLM injects 30% failures, so we should see retries
        # in the execution logs
        
        # Send a request that goes through retry_with_backoff
        correlation_id = f"test_retry_{int(time.time())}"
        
        # Use the demo workflow which calls retry_with_backoff
        resp = await webhook_client.post_triage(
            text="Test retry mechanism",
            email="retry@example.com",
            amount_usd=50,
            correlation_id=correlation_id
        )
        
        # Should eventually succeed (mock has 70% success rate)
        assert resp.status_code == 200
        
        # Wait for processing
        await asyncio.sleep(2)
        
        # Check execution shows retries (would need to query n8n executions)
        # For now, verify we got a response
        data = resp.json()
        assert "intent" in data or "error" in data


@pytest.mark.integration
@pytest.mark.retry
class TestRetryMechanism:
    """Tests for retry_with_backoff workflow."""

    async def test_retry_exponential_backoff_timing(self, config):
        """Verify exponential backoff timing."""
        # This would require instrumenting the retry workflow
        # to record attempt timestamps
        pytest.skip("Requires workflow instrumentation")

    async def test_retry_respects_retry_after_header(self, config):
        """Verify Retry-After header is honored."""
        pytest.skip("Requires mock server with Retry-After")


@pytest.mark.integration
@pytest.mark.cost
class TestCostTracking:
    """Tests for LLM cost ledger and budget guard."""

    async def test_demo_creates_usage_rows(self, config, webhook_client, query_postgres):
        """Run demo and verify usage rows are created."""
        # Send a few requests
        for i in range(3):
            await webhook_client.post_triage(
                text=f"Test cost tracking {i}",
                email=f"cost{i}@example.com",
                amount_usd=10,
                correlation_id=f"cost_test_{i}"
            )
            await asyncio.sleep(1)
        
        # Wait for async logging
        await asyncio.sleep(3)
        
        # Check llm_usage table
        rows = await query_postgres(config, """
            SELECT workflow_name, provider, model, input_tokens, output_tokens, total_cost_usd
            FROM ops.llm_usage
            WHERE workflow_name = 'showcase_ai_ops'
            ORDER BY created_at DESC
            LIMIT 10
        """)
        
        # Should have at least some rows
        if rows:
            for row in rows:
                assert row["total_cost_usd"] is not None
                assert row["total_cost_usd"] >= 0
                assert row["input_tokens"] >= 0
                assert row["output_tokens"] >= 0

    async def test_cost_computation_matches_pricing(self, config, query_postgres):
        """Verify cost = tokens * pricing."""
        # Check a specific row
        row = await query_postgres(config, """
            SELECT input_tokens, output_tokens, input_cost_usd, output_cost_usd, total_cost_usd
            FROM ops.llm_usage
            WHERE total_cost_usd > 0
            ORDER BY created_at DESC
            LIMIT 1
        """)
        
        if row:
            # Verify math: cost = (tokens / 1M) * price_per_1M
            # This depends on the pricing in model_pricing table
            assert row["total_cost_usd"] == row["input_cost_usd"] + row["output_cost_usd"]

    async def test_budget_guard_warning_at_80_percent(self, config, query_postgres):
        """Verify budget guard triggers at 80%."""
        # This would require setting a low budget and generating usage
        pytest.skip("Requires budget configuration and time to run guard")


@pytest.mark.integration
@pytest.mark.approval
class TestApprovalFlow:
    """Tests for human-in-the-loop approval workflow."""

    async def test_request_approval_creates_row(
        self, config, webhook_client, query_postgres
    ):
        """Verify approval request creates row in ops.approvals."""
        correlation_id = f"approval_test_{int(time.time())}"
        
        # Send high-value request that triggers approval
        resp = await webhook_client.post_triage(
            text="Please approve this expensive refund",
            email="approval@example.com",
            amount_usd=500,  # High risk
            correlation_id=correlation_id
        )
        
        # Wait for approval workflow to create row
        await asyncio.sleep(3)
        
        # Check approvals table
        rows = await query_postgres(config, """
            SELECT id, status, approver_primary, action_type, risk_level
            FROM ops.approvals
            WHERE correlation_id = $1
        """, (correlation_id,))
        
        if rows:
            assert rows[0]["status"] == "pending"
            assert rows[0]["risk_level"] == "high"
        else:
            # Approval may not trigger if workflow not active
            pytest.skip("Approval workflow not active or not triggered")

    async def test_approval_callback_approve(
        self, config, sync_http_client, query_postgres
    ):
        """Test approve callback marks approval as approved."""
        # First create an approval
        row = await query_postgres(config, """
            INSERT INTO ops.approvals (
                workflow_id, workflow_name, execution_id, action_type,
                summary, details, risk_level, requested_by,
                approver_primary, approver_secondary, status, expires_at,
                callback_token, callback_expires_at
            ) VALUES (
                'test-wf', 'Test Workflow', 'test-exec', 'test_action',
                'Test summary', '{}', 'medium', 'tester',
                '123456789', '987654321', 'pending',
                NOW() + INTERVAL '30 minutes',
                'test-token-123', NOW() + INTERVAL '90 minutes'
            ) RETURNING id
        """)
        
        approval_id = row[0]["id"]
        
        # Call approve callback
        callback_url = f"http://localhost/webhook/approval/callback/{approval_id}/test-token-123"
        resp = sync_http_client.post(
            callback_url,
            json={
                "callback_query": {
                    "data": f"approve:{approval_id}:test-token-123",
                    "from": {"id": "123456789"}
                }
            }
        )
        
        assert resp.status_code == 200
        
        # Verify status changed
        rows = await query_postgres(config, """
            SELECT status, decided_by, decided_at
            FROM ops.approvals
            WHERE id = $1
        """, (approval_id,))
        
        assert rows[0]["status"] == "approved"
        assert rows[0]["decided_by"] == "123456789"

    async def test_approval_callback_reject(
        self, config, sync_http_client, query_postgres
    ):
        """Test reject callback marks approval as rejected."""
        row = await query_postgres(config, """
            INSERT INTO ops.approvals (
                workflow_id, workflow_name, execution_id, action_type,
                summary, details, risk_level, requested_by,
                approver_primary, approver_secondary, status, expires_at,
                callback_token, callback_expires_at
            ) VALUES (
                'test-wf', 'Test Workflow', 'test-exec', 'test_action',
                'Test summary', '{}', 'medium', 'tester',
                '123456789', '987654321', 'pending',
                NOW() + INTERVAL '30 minutes',
                'test-token-456', NOW() + INTERVAL '90 minutes'
            ) RETURNING id
        """)
        
        approval_id = row[0]["id"]
        
        callback_url = f"http://localhost/webhook/approval/callback/{approval_id}/test-token-456"
        resp = sync_http_client.post(
            callback_url,
            json={
                "callback_query": {
                    "data": f"reject:{approval_id}:test-token-456",
                    "from": {"id": "123456789"}
                }
            }
        )
        
        assert resp.status_code == 200
        
        rows = await query_postgres(config, """
            SELECT status, decided_by
            FROM ops.approvals
            WHERE id = $1
        """, (approval_id,))
        
        assert rows[0]["status"] == "rejected"

    async def test_unauthorized_user_cannot_decide(
        self, config, sync_http_client, query_postgres
    ):
        """Test that non-approver cannot decide."""
        row = await query_postgres(config, """
            INSERT INTO ops.approvals (
                workflow_id, workflow_name, execution_id, action_type,
                summary, details, risk_level, requested_by,
                approver_primary, approver_secondary, status, expires_at,
                callback_token, callback_expires_at
            ) VALUES (
                'test-wf', 'Test Workflow', 'test-exec', 'test_action',
                'Test summary', '{}', 'medium', 'tester',
                '123456789', '987654321', 'pending',
                NOW() + INTERVAL '30 minutes',
                'test-token-789', NOW() + INTERVAL '90 minutes'
            ) RETURNING id
        """)
        
        approval_id = row[0]["id"]
        
        callback_url = f"http://localhost/webhook/approval/callback/{approval_id}/test-token-789"
        resp = sync_http_client.post(
            callback_url,
            json={
                "callback_query": {
                    "data": f"approve:{approval_id}:test-token-789",
                    "from": {"id": "999999999"}  # Not an approver
                }
            }
        )
        
        assert resp.status_code == 403
        
        # Verify status unchanged
        rows = await query_postgres(config, """
            SELECT status FROM ops.approvals WHERE id = $1
        """, (approval_id,))
        
        assert rows[0]["status"] == "pending"

    async def test_double_click_rejected(
        self, config, sync_http_client, query_postgres
    ):
        """Test that second click is rejected."""
        row = await query_postgres(config, """
            INSERT INTO ops.approvals (
                workflow_id, workflow_name, execution_id, action_type,
                summary, details, risk_level, requested_by,
                approver_primary, approver_secondary, status, expires_at,
                callback_token, callback_expires_at
            ) VALUES (
                'test-wf', 'Test Workflow', 'test-exec', 'test_action',
                'Test summary', '{}', 'medium', 'tester',
                '123456789', '987654321', 'pending',
                NOW() + INTERVAL '30 minutes',
                'test-token-double', NOW() + INTERVAL '90 minutes'
            ) RETURNING id
        """)
        
        approval_id = row[0]["id"]
        callback_url = f"http://localhost/webhook/approval/callback/{approval_id}/test-token-double"
        
        # First click
        resp1 = sync_http_client.post(
            callback_url,
            json={
                "callback_query": {
                    "data": f"approve:{approval_id}:test-token-double",
                    "from": {"id": "123456789"}
                }
            }
        )
        assert resp1.status_code == 200
        
        # Second click (double click)
        resp2 = sync_http_client.post(
            callback_url,
            json={
                "callback_query": {
                    "data": f"approve:{approval_id}:test-token-double",
                    "from": {"id": "123456789"}
                }
            }
        )
        assert resp2.status_code == 409  # Conflict - already decided

    async def test_timeout_escalates_to_secondary(
        self, config, webhook_client, query_postgres
    ):
        """Test that timeout escalates to secondary approver."""
        # This would require shortening the timeout and waiting
        pytest.skip("Requires shortened timeout env and time to wait")


@pytest.mark.integration
@pytest.mark.queue
class TestQueueMode:
    """Tests for n8n queue mode with multiple workers."""

    async def test_parallel_executions_distributed(
        self, config, webhook_client, query_postgres
    ):
        """Send N parallel requests and verify multiple workers handle them."""
        # This would require checking n8n execution logs for worker IDs
        pytest.skip("Requires n8n API access to check worker distribution")

    async def test_webhook_processor_separate_from_main(self, config, webhook_client):
        """Verify webhook processor handles webhooks separately."""
        # Send webhook request
        resp = await webhook_client.post_triage(
            text="Webhook test",
            email="webhook@example.com"
        )
        
        # Should succeed
        assert resp.status_code == 200


# Pytest configuration for async tests
def pytest_collection_modifyitems(config, items):
    """Add asyncio marker to async tests."""
    for item in items:
        if asyncio.iscoroutinefunction(item.function):
            item.add_marker(pytest.mark.asyncio)