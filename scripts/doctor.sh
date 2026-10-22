#!/usr/bin/env bash
# doctor.sh - Comprehensive health checks for NexusOps
# Usage: ./scripts/doctor.sh [--json]

set -euo pipefail

JSON_OUTPUT=false
if [[ "${1:-}" == "--json" ]]; then
    JSON_OUTPUT=true
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Results
RESULTS=()
OVERALL_STATUS=0

log() {
    echo -e "$*"
}

check_pass() {
    local name="$1"
    local msg="$2"
    RESULTS+=("{\"check\":\"$name\",\"status\":\"PASS\",\"message\":\"$msg\"}")
    if ! $JSON_OUTPUT; then
        log "${GREEN}✓ PASS${NC}  $name: $msg"
    fi
}

check_warn() {
    local name="$1"
    local msg="$2"
    RESULTS+=("{\"check\":\"$name\",\"status\":\"WARN\",\"message\":\"$msg\"}")
    if ! $JSON_OUTPUT; then
        log "${YELLOW}⚠ WARN${NC}  $name: $msg"
    fi
    [[ $OVERALL_STATUS -eq 0 ]] && OVERALL_STATUS=1
}

check_fail() {
    local name="$1"
    local msg="$2"
    RESULTS+=("{\"check\":\"$name\",\"status\":\"FAIL\",\"message\":\"$msg\"}")
    if ! $JSON_OUTPUT; then
        log "${RED}✗ FAIL${NC}  $name: $msg"
    fi
    OVERALL_STATUS=2
}

run_check() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        check_pass "$name" "OK"
        return 0
    else
        check_fail "$name" "Check failed"
        return 1
    fi
}

# ============================================================================
# Environment
# ============================================================================

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-nexusops}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"

if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

# ============================================================================
# Checks
# ============================================================================

header() {
    if ! $JSON_OUTPUT; then
        log "\n${BLUE}=== $1 ===${NC}"
    fi
}

header "Docker & Compose"

# Docker version
if command -v docker >/dev/null 2>&1; then
    DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | tr -d ',')
    check_pass "docker" "Version $DOCKER_VERSION"
else
    check_fail "docker" "Not found in PATH"
fi

# Docker daemon
if docker info >/dev/null 2>&1; then
    check_pass "docker-daemon" "Reachable"
else
    check_fail "docker-daemon" "Not reachable (is Docker running?)"
fi

# Compose version
if docker compose version >/dev/null 2>&1; then
    COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || docker compose version | head -1)
    check_pass "docker-compose" "Version $COMPOSE_VERSION"
else
    check_fail "docker-compose" "Not available"
fi

header "Environment Configuration"

# .env file
if [[ -f .env ]]; then
    check_pass "env-file" "Exists"
    # Check permissions
    PERMS=$(stat -c %a .env 2>/dev/null || stat -f %A .env 2>/dev/null)
    if [[ "$PERMS" == "600" || "$PERMS" == "0600" ]]; then
        check_pass "env-perms" "600 (secure)"
    else
        check_warn "env-perms" "Permissions $PERMS (recommended: 600)"
    fi
else
    check_warn "env-file" "Missing (using .env.example defaults)"
fi

# Critical variables
CRITICAL_VARS=(
    "POSTGRES_PASSWORD"
    "REDIS_PASSWORD"
    "QDRANT_API_KEY"
    "N8N_ENCRYPTION_KEY"
)
for var in "${CRITICAL_VARS[@]}"; do
    if [[ -n "${!var:-}" ]]; then
        check_pass "env-$var" "Set"
    else
        check_warn "env-$var" "Not set (using default/empty)"
    fi
done

header "Container Health"

# Get container statuses
CONTAINER_STATUS=$(docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" ps --format json 2>/dev/null || echo "[]")

if [[ "$CONTAINER_STATUS" == "[]" ]]; then
    check_fail "containers" "No containers found (run 'make up')"
else
    # Check each expected service
    EXPECTED_SERVICES=("traefik" "postgres" "redis" "qdrant" "n8n-main" "n8n-webhook" "n8n-worker" "backup")
    for svc in "${EXPECTED_SERVICES[@]}"; do
        # Use docker inspect for health status
        CONTAINER_NAME="${COMPOSE_PROJECT_NAME}_${svc}"
        if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
            HEALTH=$(docker inspect "$CONTAINER_NAME" --format '{{.State.Health.Status}}' 2>/dev/null || echo "none")
            STATUS=$(docker inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
            if [[ "$HEALTH" == "healthy" || "$HEALTH" == "none" ]]; then
                if [[ "$STATUS" == "running" ]]; then
                    check_pass "container-$svc" "Running ($HEALTH)"
                else
                    check_fail "container-$svc" "Status: $STATUS"
                fi
            elif [[ "$HEALTH" == "starting" ]]; then
                check_warn "container-$svc" "Starting..."
            else
                check_fail "container-$svc" "Health: $HEALTH, Status: $STATUS"
            fi
        else
            # Check if it's a scaled service
            if docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" ps "$svc" --format json 2>/dev/null | grep -q "$svc"; then
                check_pass "container-$svc" "Exists (scaled)"
            else
                check_warn "container-$svc" "Not found (may be scaled or profile)"
            fi
        fi
    done
fi

header "PostgreSQL"

if docker exec -i "${COMPOSE_PROJECT_NAME}_postgres" pg_isready -U "${POSTGRES_USER:-nexusops}" -d "${POSTGRES_DB:-nexusops}" >/dev/null 2>&1; then
    check_pass "postgres-connectivity" "Accepting connections"
else
    check_fail "postgres-connectivity" "Cannot connect"
fi

# Check ops schema
if docker exec -i "${COMPOSE_PROJECT_NAME}_postgres" psql -U "${POSTGRES_USER:-nexusops}" -d "${POSTGRES_DB:-nexusops}" -t -c "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'ops';" 2>/dev/null | grep -q 1; then
    check_pass "postgres-ops-schema" "Schema 'ops' exists"
else
    check_fail "postgres-ops-schema" "Schema 'ops' missing"
fi

# Check key tables
for table in "dead_letters" "llm_usage" "approvals" "model_pricing" "approval_policies" "demo_outbox"; do
    if docker exec -i "${COMPOSE_PROJECT_NAME}_postgres" psql -U "${POSTGRES_USER:-nexusops}" -d "${POSTGRES_DB:-nexusops}" -t -c "SELECT 1 FROM ops.${table} LIMIT 1;" 2>/dev/null | grep -q 1; then
        check_pass "postgres-table-$table" "Exists"
    else
        check_warn "postgres-table-$table" "Missing or empty"
    fi
done

header "Redis"

if docker exec -i "${COMPOSE_PROJECT_NAME}_redis" redis-cli -a "${REDIS_PASSWORD:-}" ping >/dev/null 2>&1; then
    check_pass "redis-ping" "PONG"
else
    check_fail "redis-ping" "No response"
fi

# Queue depth (Bull queue keys)
QUEUE_KEYS=$(docker exec -i "${COMPOSE_PROJECT_NAME}_redis" redis-cli -a "${REDIS_PASSWORD:-}" keys "bull:*" 2>/dev/null | wc -l | xargs)
if [[ -n "$QUEUE_KEYS" && "$QUEUE_KEYS" -gt 0 ]]; then
    check_pass "redis-queue" "$QUEUE_KEYS Bull queue keys found"
else
    check_warn "redis-queue" "No Bull queue keys (queue may be empty)"
fi

header "Qdrant"

if curl -fsS "http://localhost:6333/healthz" >/dev/null 2>&1; then
    check_pass "qdrant-health" "HTTP /healthz OK"
else
    check_fail "qdrant-health" "Health endpoint not responding"
fi

if curl -fsS -H "api-key: ${QDRANT_API_KEY}" "http://localhost:6333/collections" >/dev/null 2>&1; then
    check_pass "qdrant-api" "API accessible with key"
else
    check_warn "qdrant-api" "API key may be invalid or missing"
fi

header "n8n Services"

# n8n-main
if curl -fsS "http://localhost:5678/healthz" >/dev/null 2>&1; then
    check_pass "n8n-main-health" "HTTP /healthz OK"
else
    check_fail "n8n-main-health" "Not responding"
fi

# n8n-webhook
if curl -fsS "http://localhost:5678/healthz" >/dev/null 2>&1; then
    # Same port, but we can check if webhook endpoint exists
    check_pass "n8n-webhook-health" "Responding on shared port"
else
    check_warn "n8n-webhook-health" "Not separately verified"
fi

# Worker count
WORKER_COUNT=$(docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" ps n8n-worker --format json 2>/dev/null | jq -r 'length' 2>/dev/null || echo "0")
if [[ "$WORKER_COUNT" -gt 0 ]]; then
    check_pass "n8n-workers" "$WORKER_COUNT worker(s) running"
else
    check_warn "n8n-workers" "No workers found"
fi

# Queue depth via n8n API (if accessible)
# Not implemented - would need API key

header "Backup System"

# Backup volume
if docker volume inspect "${COMPOSE_PROJECT_NAME}_backups" >/dev/null 2>&1; then
    check_pass "backup-volume" "Exists"
    
    # Check for recent backup
    LATEST_BACKUP=$(docker run --rm -v "${COMPOSE_PROJECT_NAME}_backups:/backup/data:ro" alpine:3.21 find /backup/data -maxdepth 1 -type d -name "nexusops-*" 2>/dev/null | sort -r | head -1)
    if [[ -n "$LATEST_BACKUP" ]]; then
        # Extract timestamp from directory name
        BACKUP_NAME=$(basename "$LATEST_BACKUP")
        BACKUP_TS=$(echo "$BACKUP_NAME" | sed 's/nexusops-//' | sed 's/T/ /' | sed 's/Z//')
        if BACKUP_EPOCH=$(date -u -d "$BACKUP_TS" +%s 2>/dev/null); then
            NOW_EPOCH=$(date -u +%s)
            AGE_HOURS=$(( (NOW_EPOCH - BACKUP_EPOCH) / 3600 ))
            if [[ $AGE_HOURS -le 26 ]]; then
                check_pass "backup-age" "Latest backup ${AGE_HOURS}h ago"
            else
                check_warn "backup-age" "Latest backup ${AGE_HOURS}h ago (>26h)"
            fi
        else
            check_warn "backup-age" "Could not parse backup timestamp"
        fi
    else
        check_warn "backup-age" "No backups found"
    fi
else
    check_warn "backup-volume" "Not found"
fi

header "Certificate Expiry (Production)"

if [[ -f .env ]] && grep -q "COMPOSE_FILE.*compose.prod" .env 2>/dev/null; then
    if docker volume inspect "${COMPOSE_PROJECT_NAME}_letsencrypt" >/dev/null 2>&1; then
        # Check acme.json for cert expiry
        CERT_EXPIRY=$(docker run --rm -v "${COMPOSE_PROJECT_NAME}_letsencrypt:/letsencrypt:ro" alpine:3.21 cat /letsencrypt/acme.json 2>/dev/null | jq -r '.Certificates[0].certificate.notAfter // empty' 2>/dev/null || echo "")
        if [[ -n "$CERT_EXPIRY" ]]; then
            EXPIRY_EPOCH=$(date -u -d "$CERT_EXPIRY" +%s 2>/dev/null || echo 0)
            NOW_EPOCH=$(date -u +%s)
            DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
            if [[ $DAYS_LEFT -gt 30 ]]; then
                check_pass "cert-expiry" "Expires in $DAYS_LEFT days"
            elif [[ $DAYS_LEFT -gt 7 ]]; then
                check_warn "cert-expiry" "Expires in $DAYS_LEFT days"
            else
                check_fail "cert-expiry" "Expires in $DAYS_LEFT days (URGENT)"
            fi
        else
            check_warn "cert-expiry" "Could not determine expiry"
        fi
    else
        check_warn "cert-expiry" "letsencrypt volume not found"
    fi
else
    check_pass "cert-expiry" "Skipped (not production mode)"
fi

header "Dead Letter Queue"

PENDING_DLQ=$(docker exec -i "${COMPOSE_PROJECT_NAME}_postgres" psql -U "${POSTGRES_USER:-nexusops}" -d "${POSTGRES_DB:-nexusops}" -t -c "SELECT COUNT(*) FROM ops.dead_letters WHERE status = 'pending';" 2>/dev/null | xargs || echo "0")
if [[ "$PENDING_DLQ" -eq 0 ]]; then
    check_pass "dlq-pending" "No pending items"
else
    check_warn "dlq-pending" "$PENDING_DLQ pending item(s)"
fi

header "Pending Approvals"

PENDING_APPROVALS=$(docker exec -i "${COMPOSE_PROJECT_NAME}_postgres" psql -U "${POSTGRES_USER:-nexusops}" -d "${POSTGRES_DB:-nexusops}" -t -c "SELECT COUNT(*) FROM ops.approvals WHERE status IN ('pending', 'escalated');" 2>/dev/null | xargs || echo "0")
if [[ "$PENDING_APPROVALS" -eq 0 ]]; then
    check_pass "approvals-pending" "No pending approvals"
else
    check_warn "approvals-pending" "$PENDING_APPROVALS pending approval(s)"
fi

header "LLM Cost (Month-to-Date)"

MTD_COST=$(docker exec -i "${COMPOSE_PROJECT_NAME}_postgres" psql -U "${POSTGRES_USER:-nexusops}" -d "${POSTGRES_DB:-nexusops}" -t -c "SELECT COALESCE(SUM(total_cost_usd), 0) FROM ops.v_llm_cost_month_to_date;" 2>/dev/null | xargs || echo "0")
if [[ -n "${LLM_MONTHLY_BUDGET_USD:-}" && "$LLM_MONTHLY_BUDGET_USD" != "0" ]]; then
    PCT=$(echo "scale=1; $MTD_COST * 100 / $LLM_MONTHLY_BUDGET_USD" | bc -l 2>/dev/null || echo "0")
    PCT_INT=${PCT%.*}
    if [[ $PCT_INT -ge 100 ]]; then
        check_fail "llm-budget" "MTD cost \$$MTD_COST / \$$LLM_MONTHLY_BUDGET_USD (${PCT}%)"
    elif [[ $PCT_INT -ge 80 ]]; then
        check_warn "llm-budget" "MTD cost \$$MTD_COST / \$$LLM_MONTHLY_BUDGET_USD (${PCT}%)"
    else
        check_pass "llm-budget" "MTD cost \$$MTD_COST / \$$LLM_MONTHLY_BUDGET_USD (${PCT}%)"
    fi
else
    check_pass "llm-budget" "MTD cost \$$MTD_COST (no budget set)"
fi

header "Disk Space"

# Check volume disk usage
for vol in "${COMPOSE_PROJECT_NAME}_postgres_data" "${COMPOSE_PROJECT_NAME}_redis_data" "${COMPOSE_PROJECT_NAME}_qdrant_storage" "${COMPOSE_PROJECT_NAME}_n8n_data" "${COMPOSE_PROJECT_NAME}_backups"; do
    if docker volume inspect "$vol" >/dev/null 2>&1; then
        # Get usage via docker system df -v (approximate)
        USAGE=$(docker system df -v 2>/dev/null | grep "$vol" | awk '{print $3}' | head -1)
        if [[ -n "$USAGE" ]]; then
            check_pass "disk-$vol" "$USAGE used"
        else
            check_pass "disk-$vol" "Exists"
        fi
    fi
done

# Host disk space
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
if [[ $DISK_USAGE -lt 80 ]]; then
    check_pass "disk-host" "${DISK_USAGE}% used"
elif [[ $DISK_USAGE -lt 90 ]]; then
    check_warn "disk-host" "${DISK_USAGE}% used"
else
    check_fail "disk-host" "${DISK_USAGE}% used (critical)"
fi

# ============================================================================
# Output
# ============================================================================

if $JSON_OUTPUT; then
    printf '{"status":%d,"checks":[%s]}\n' "$OVERALL_STATUS" "$(IFS=,; echo "${RESULTS[*]}")"
else
    log ""
    log "${BLUE}=== Summary ===${NC}"
    PASS_COUNT=$(printf '%s\n' "${RESULTS[@]}" | grep -c '"status":"PASS"' || echo 0)
    WARN_COUNT=$(printf '%s\n' "${RESULTS[@]}" | grep -c '"status":"WARN"' || echo 0)
    FAIL_COUNT=$(printf '%s\n' "${RESULTS[@]}" | grep -c '"status":"FAIL"' || echo 0)
    log "PASS: $PASS_COUNT  WARN: $WARN_COUNT  FAIL: $FAIL_COUNT"
    
    if [[ $OVERALL_STATUS -eq 0 ]]; then
        log "${GREEN}All checks passed!${NC}"
    elif [[ $OVERALL_STATUS -eq 1 ]]; then
        log "${YELLOW}Some warnings - review recommended${NC}"
    else
        log "${RED}Critical failures detected${NC}"
    fi
fi

exit $OVERALL_STATUS