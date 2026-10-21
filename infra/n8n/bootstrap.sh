#!/usr/bin/env bash
# bootstrap.sh - Import and activate n8n workflows from /workflows
# Idempotent: uses stable workflow IDs to update rather than duplicate.

set -euo pipefail

WORKFLOWS_DIR="${WORKFLOWS_DIR:-/workflows}"
N8N_USER="${N8N_USER:-admin}"
N8N_PASSWORD="${N8N_PASSWORD:-}"
N8N_HOST="${N8N_HOST:-localhost}"
N8N_PORT="${N8N_PORT:-5678}"
N8N_PROTOCOL="${N8N_PROTOCOL:-http}"

# Required env vars for credentials
OPS_WRITER_PASSWORD="${OPS_WRITER_PASSWORD:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
DLQ_REPLAY_TOKEN="${DLQ_REPLAY_TOKEN:-}"

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

wait_for_n8n() {
    local max_wait=120
    local waited=0
    log "Waiting for n8n to be ready at ${N8N_PROTOCOL}://${N8N_HOST}:${N8N_PORT}..."
    while [[ ${waited} -lt ${max_wait} ]]; do
        if curl -fsS "${N8N_PROTOCOL}://${N8N_HOST}:${N8N_PORT}/healthz" >/dev/null 2>&1; then
            log "n8n is ready"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    log "ERROR: n8n did not become ready in time"
    return 1
}

create_credentials() {
    log "Creating credential placeholders..."
    
    # Postgres credentials for ops_writer
    if [[ -n "${OPS_WRITER_PASSWORD}" ]]; then
        n8n credentials:create --type=postgres --name="ops_writer_credentials" --data="{
            \"host\": \"postgres\",
            \"port\": 5432,
            \"database\": \"${POSTGRES_DB:-nexusops}\",
            \"user\": \"ops_writer\",
            \"password\": \"${OPS_WRITER_PASSWORD}\",
            \"ssl\": false
        }" 2>/dev/null || n8n credentials:update --id=ops_writer_credentials --data="{
            \"host\": \"postgres\",
            \"port\": 5432,
            \"database\": \"${POSTGRES_DB:-nexusops}\",
            \"user\": \"ops_writer\",
            \"password\": \"${OPS_WRITER_PASSWORD}\",
            \"ssl\": false
        }"
        log "Created/updated ops_writer_credentials"
    else
        log "WARNING: OPS_WRITER_PASSWORD not set, skipping ops_writer_credentials"
    fi

    # Telegram credentials
    if [[ -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
        n8n credentials:create --type=telegramApi --name="telegram_credentials" --data="{
            \"token\": \"${TELEGRAM_BOT_TOKEN}\",
            \"chatId\": \"${TELEGRAM_CHAT_ID}\"
        }" 2>/dev/null || n8n credentials:update --id=telegram_credentials --data="{
            \"token\": \"${TELEGRAM_BOT_TOKEN}\",
            \"chatId\": \"${TELEGRAM_CHAT_ID}\"
        }"
        log "Created/updated telegram_credentials"
    else
        log "WARNING: TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID not set, skipping telegram_credentials"
    fi

    # DLQ replay token (stored as a simple credential or env)
    if [[ -n "${DLQ_REPLAY_TOKEN}" ]]; then
        log "DLQ_REPLAY_TOKEN is set (used directly in workflows)"
    else
        log "WARNING: DLQ_REPLAY_TOKEN not set"
    fi
}

import_workflows() {
    log "Importing workflows from ${WORKFLOWS_DIR}..."
    
    local imported=0
    local skipped=0
    
    for workflow_file in "${WORKFLOWS_DIR}"/**/*.json; do
        [[ -f "${workflow_file}" ]] || continue
        
        log "Processing: ${workflow_file}"
        
        # Import workflow - n8n CLI will update if ID exists
        if n8n import:workflow --input="${workflow_file}" 2>/dev/null; then
            log "Imported: $(basename "${workflow_file}")"
            ((imported++))
        else
            log "Skipped (already exists or error): $(basename "${workflow_file}")"
            ((skipped++))
        fi
    done
    
    log "Imported: ${imported}, Skipped: ${skipped}"
}

activate_core_workflows() {
    log "Activating core workflows..."
    
    # List of core workflow IDs that should be active
    local core_workflows=(
        "global-error-handler"
        "dlq-replay"
    )
    
    for wf_id in "${core_workflows[@]}"; do
        if n8n workflow:activate --id="${wf_id}" 2>/dev/null; then
            log "Activated: ${wf_id}"
        else
            log "Could not activate ${wf_id} (may not exist yet or already active)"
        fi
    done
}

set_global_error_workflow() {
    log "Setting global error workflow..."
    
    # This requires n8n API call to set the error workflow
    # n8n CLI doesn't have a direct command for this, so we use the API
    local api_url="${N8N_PROTOCOL}://${N8N_HOST}:${N8N_PORT}/api/v1/settings"
    
    if curl -fsS -X PUT "${api_url}" \
        -H "Content-Type: application/json" \
        -u "${N8N_USER}:${N8N_PASSWORD}" \
        -d '{"errorWorkflow": "global-error-handler"}' >/dev/null 2>&1; then
        log "Global error workflow set to 'global-error-handler'"
    else
        log "WARNING: Could not set global error workflow via API (may need manual setup)"
    fi
}

main() {
    log "Starting n8n bootstrap..."
    
    wait_for_n8n || exit 1
    create_credentials
    import_workflows
    activate_core_workflows
    set_global_error_workflow
    
    log "Bootstrap completed successfully"
}

main "$@"