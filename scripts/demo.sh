#!/usr/bin/env bash
# demo.sh - Run the end-to-end showcase demo in mock mode
# Usage: ./scripts/demo.sh

set -euo pipefail

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-nexusops}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

run_demo() {
    log "=== NexusOps Showcase Demo ==="
    log "Starting stack in mock mode..."
    
    # Start with demo profile (includes mock-llm)
    DEMO_MODE=mock docker compose -p "${COMPOSE_PROJECT_NAME}" -f "${COMPOSE_FILE}" --profile demo up -d
    
    # Wait for services
    log "Waiting for services to be healthy..."
    local max_wait=180
    local waited=0
    while [[ ${waited} -lt ${max_wait} ]]; do
        if docker compose -p "${COMPOSE_PROJECT_NAME}" -f "${COMPOSE_FILE}" ps --format json 2>/dev/null | jq -e 'all(.Health == "healthy" or .Health == "")' >/dev/null 2>&1; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done
    
    # Run bootstrap to import workflows
    log "Running n8n bootstrap..."
    docker compose -p "${COMPOSE_PROJECT_NAME}" -f "${COMPOSE_FILE}" run --rm n8n-bootstrap || true
    
    # Seed Qdrant demo collection
    log "Seeding Qdrant demo collection..."
    docker compose -p "${COMPOSE_PROJECT_NAME}" -f "${COMPOSE_FILE}" run --rm \
        -e QDRANT_HOST=qdrant \
        -e QDRANT_PORT=6333 \
        -e QDRANT_API_KEY="${QDRANT_API_KEY}" \
        alpine:3.21 sh -c "
            apk add --no-cache curl jq bc >/dev/null 2>&1
            $(cat scripts/seed-qdrant-demo.sh | sed 's/^wait_for_qdrant.*$//' | sed 's/^main.*$//')
        " || log "Qdrant seeding completed (or skipped)"
    
    # Send 5 sample requests
    log "Sending sample requests..."
    local base_url="http://localhost/webhook/triage"
    
    # Request 1: Low risk - general inquiry
    log "Request 1: Low risk (general inquiry)..."
    curl -fsS -X POST "${base_url}" \
        -H "Content-Type: application/json" \
        -d '{"text": "Hello, I have a general question about your API rate limits.", "email": "user1@example.com"}' \
        | jq -c '{correlation_id, intent: .intent, risk: .risk_level, approval: .approval_status, cost: .cost_usd}'
    
    # Request 2: Medium risk - billing inquiry
    log "Request 2: Medium risk (billing inquiry)..."
    curl -fsS -X POST "${base_url}" \
        -H "Content-Type: application/json" \
        -d '{"text": "I see an unexpected charge on my invoice this month.", "email": "user2@example.com", "amount_usd": 50}' \
        | jq -c '{correlation_id, intent: .intent, risk: .risk_level, approval: .approval_status, cost: .cost_usd}'
    
    # Request 3: High risk - refund over threshold
    log "Request 3: High risk (refund request > $100)..."
    curl -fsS -X POST "${base_url}" \
        -H "Content-Type: application/json" \
        -d '{"text": "I want a refund for my annual subscription, that is $200.", "email": "user3@example.com", "amount_usd": 200}' \
        | jq -c '{correlation_id, intent: .intent, risk: .risk_level, approval: .approval_status, cost: .cost_usd}'
    
    # Request 4: Triggers retry (mock failure injection)
    log "Request 4: Retry trigger (injected failure)..."
    curl -fsS -X POST "${base_url}" \
        -H "Content-Type: application/json" \
        -d '{"text": "This request will trigger a mock failure for demo.", "email": "user4@example.com"}' \
        | jq -c '{correlation_id, intent: .intent, risk: .risk_level, approval: .approval_status, cost: .cost_usd}'
    
    # Request 5: Permanent failure (account deletion - high risk)
    log "Request 5: High risk (account deletion)..."
    curl -fsS -X POST "${base_url}" \
        -H "Content-Type: application/json" \
        -d '{"text": "Please delete my account and all my data permanently.", "email": "user5@example.com"}' \
        | jq -c '{correlation_id, intent: .intent, risk: .risk_level, approval: .approval_status, cost: .cost_usd}'
    
    log "Sample requests sent. Waiting for async processing..."
    sleep 10
    
    # Print summary
    print_summary
}

print_summary() {
    log "=== Demo Summary ==="
    
    # Costs from llm_usage
    log "--- LLM Usage & Costs ---"
    docker exec -i nexusops_postgres psql -U nexusops -d nexusops -c "
        SELECT 
            workflow_name,
            COUNT(*) as calls,
            SUM(input_tokens) as input_tokens,
            SUM(output_tokens) as output_tokens,
            SUM(total_cost_usd) as total_cost_usd
        FROM ops.llm_usage
        WHERE created_at > NOW() - INTERVAL '5 minutes'
        GROUP BY workflow_name
        ORDER BY total_cost_usd DESC;
    " 2>/dev/null || log "No LLM usage data yet"
    
    # Approvals
    log "--- Approvals ---"
    docker exec -i nexusops_postgres psql -U nexusops -d nexusops -c "
        SELECT 
            id, action_type, risk_level, status, 
            decided_by, decision_reason
        FROM ops.approvals
        WHERE created_at > NOW() - INTERVAL '5 minutes'
        ORDER BY created_at DESC;
    " 2>/dev/null || log "No approval data yet"
    
    # DLQ items
    log "--- Dead Letter Queue ---"
    docker exec -i nexusops_postgres psql -U nexusops -d nexusops -c "
        SELECT 
            id, workflow_name, node_name, error_message, status, attempts
        FROM ops.dead_letters
        WHERE created_at > NOW() - INTERVAL '5 minutes'
        ORDER BY created_at DESC;
    " 2>/dev/null || log "No DLQ data yet"
    
    # Outbox
    log "--- Demo Outbox ---"
    docker exec -i nexusops_postgres psql -U nexusops -d nexusops -c "
        SELECT 
            id, correlation_id, action_type, status, 
            LEFT(body, 60) as body_preview
        FROM ops.demo_outbox
        WHERE created_at > NOW() - INTERVAL '5 minutes'
        ORDER BY created_at DESC;
    " 2>/dev/null || log "No outbox data yet"
    
    log "=== Demo Complete ==="
    log "Check n8n UI at http://localhost/webhook/triage for execution details"
    log "Check Telegram for approval requests (if configured)"
}

cleanup() {
    log "Cleaning up demo..."
    docker compose -p "${COMPOSE_PROJECT_NAME}" -f "${COMPOSE_FILE}" --profile demo down -v 2>/dev/null || true
}

# Trap cleanup on exit if requested
if [[ "${DEMO_CLEANUP:-true}" == "true" ]]; then
    trap cleanup EXIT
fi

case "${1:-run}" in
    run)
        run_demo
        ;;
    cleanup)
        cleanup
        ;;
    summary)
        print_summary
        ;;
    *)
        echo "Usage: $0 {run|cleanup|summary}"
        exit 1
        ;;
esac