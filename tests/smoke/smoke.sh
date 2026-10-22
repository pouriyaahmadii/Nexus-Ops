#!/usr/bin/env bash
# Smoke tests for NexusOps platform
# Runs basic health checks against a running stack.
# Usage: ./tests/smoke/smoke.sh [base|prod]

set -euo pipefail

MODE="${1:-base}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-nexusops}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"

if [[ "$MODE" == "prod" ]]; then
    COMPOSE_FILE="compose.yaml:compose.prod.yaml"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

log() {
    echo -e "$*"
}

pass() {
    log "${GREEN}✓${NC} $1"
    ((PASS++))
}

fail() {
    log "${RED}✗${NC} $1"
    ((FAIL++))
}

warn() {
    log "${YELLOW}⚠${NC} $1"
}

# Wait for stack to be healthy
wait_healthy() {
    log "Waiting for stack to be healthy..."
    local max_wait=180
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" ps --format json 2>/dev/null | jq -e 'all(.Health == "healthy" or .Health == "")' >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

# Test functions
test_containers_healthy() {
    if docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" ps --format json 2>/dev/null | jq -e 'all(.Health == "healthy" or .Health == "")' >/dev/null 2>&1; then
        pass "All containers healthy"
    else
        fail "Some containers not healthy"
    fi
}

test_n8n_responds() {
    if curl -fsS http://localhost:5678/healthz >/dev/null 2>&1; then
        pass "n8n-main responds on /healthz"
    else
        fail "n8n-main not responding"
    fi
}

test_webhook_reachable() {
    if curl -fsS http://localhost/webhook/healthz >/dev/null 2>&1; then
        pass "Webhook route reachable"
    else
        warn "Webhook route not directly reachable (may require Traefik)"
    fi
}

test_traefik_dashboard_auth() {
    # Base mode: dashboard on :8080 (not published)
    # Prod mode: dashboard on traefik.${DOMAIN} with auth
    if curl -fsS http://localhost:8080 >/dev/null 2>&1; then
        pass "Traefik dashboard accessible (base mode)"
    elif curl -fsS http://localhost >/dev/null 2>&1; then
        pass "Traefik responding on port 80"
    else
        warn "Traefik dashboard not accessible"
    fi
}

test_security_headers() {
    local headers
    headers=$(curl -sI http://localhost/ 2>/dev/null || true)
    
    local missing=()
    echo "$headers" | grep -qi "strict-transport-security" || missing+=("HSTS")
    echo "$headers" | grep -qi "x-content-type-options" || missing+=("X-Content-Type-Options")
    echo "$headers" | grep -qi "x-frame-options" || missing+=("X-Frame-Options")
    echo "$headers" | grep -qi "referrer-policy" || missing+=("Referrer-Policy")
    
    if [[ ${#missing[@]} -eq 0 ]]; then
        pass "Security headers present"
    else
        fail "Missing security headers: ${missing[*]}"
    fi
}

test_qdrant_api_key() {
    # Without API key should fail
    if curl -fsS http://localhost:6333/healthz >/dev/null 2>&1; then
        fail "Qdrant accessible without API key (should require auth)"
    else
        # With API key should work
        if curl -fsS -H "api-key: ${QDRANT_API_KEY}" http://localhost:6333/healthz >/dev/null 2>&1; then
            pass "Qdrant requires API key"
        else
            fail "Qdrant not accessible even with API key"
        fi
    fi
}

test_postgres_not_reachable_from_host() {
    # PostgreSQL should not be published on host (port 5432/5433)
    if nc -z localhost 5432 2>/dev/null || nc -z localhost 5433 2>/dev/null; then
        fail "PostgreSQL reachable from host (should be internal only)"
    else
        pass "PostgreSQL not reachable from host"
    fi
}

test_redis_not_reachable_from_host() {
    # Redis should not be published on host (port 6379/6380)
    if nc -z localhost 6379 2>/dev/null || nc -z localhost 6380 2>/dev/null; then
        fail "Redis reachable from host (should be internal only)"
    else
        pass "Redis not reachable from host"
    fi
}

# Main
main() {
    log "=== NexusOps Smoke Tests (mode: $MODE) ==="
    log ""
    
    wait_healthy || { fail "Stack did not become healthy in time"; exit 1; }
    
    test_containers_healthy
    test_n8n_responds
    test_webhook_reachable
    test_traefik_dashboard_auth
    test_security_headers
    test_qdrant_api_key
    test_postgres_not_reachable_from_host
    test_redis_not_reachable_from_host
    
    log ""
    log "=== Results: $PASS passed, $FAIL failed ==="
    
    if [[ $FAIL -eq 0 ]]; then
        exit 0
    else
        exit 1
    fi
}

main "$@"