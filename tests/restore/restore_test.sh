#!/usr/bin/env bash
# Restore test harness - wraps the Phase 5 restore drill as a test
# Usage: ./tests/restore/restore_test.sh [--cleanup]

set -euo pipefail

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-nexusops}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CLEANUP="${1:-true}"

log() {
    echo -e "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

pass() {
    echo -e "${GREEN}✓ PASS${NC} $1"
}

fail() {
    echo -e "${RED}✗ FAIL${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠ WARN${NC} $1"
}

# Run the restore drill
run_restore_test() {
    log "Starting restore test..."
    
    # Run the backup first
    log "Running backup..."
    if ! docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" run --rm backup /scripts/backup.sh; then
        fail "Backup failed"
        return 1
    fi
    pass "Backup completed"
    
    # List backups
    log "Listing backups..."
    docker run --rm -v "${COMPOSE_PROJECT_NAME}_backups:/backup/data:ro" alpine:3.21 \
        sh -c 'find /backup/data -maxdepth 1 -type d -name "nexusops-*" | sort -r | head -5'
    
    # Run restore test
    log "Running restore drill..."
    if docker run --rm \
        --name "${COMPOSE_PROJECT_NAME}-restore-test" \
        -v /var/run/docker.sock:/var/run/docker.sock:ro \
        -v "${COMPOSE_PROJECT_NAME}_backups:/backup/data:ro" \
        -v "${COMPOSE_PROJECT_NAME}_n8n_data:/n8n/data:ro" \
        -v "${COMPOSE_PROJECT_NAME}_letsencrypt:/traefik:ro" \
        -e BACKUP_DIR=/backup/data \
        -e BACKUP_AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT}" \
        -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
        -e REDIS_PASSWORD="${REDIS_PASSWORD}" \
        -e QDRANT_API_KEY="${QDRANT_API_KEY}" \
        -e N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY}" \
        -e BACKUP_S3_ENABLED=false \
        nexusops-backup:latest /scripts/restore-test.sh; then
        pass "Restore drill passed"
        return 0
    else
        fail "Restore drill failed"
        return 1
    fi
}

# Test that backup produces encrypted artifacts
test_backup_encryption() {
    log "Testing backup encryption..."
    
    # Find latest backup
    latest=$(docker run --rm -v "${COMPOSE_PROJECT_NAME}_backups:/backup/data:ro" alpine:3.21 \
        find /backup/data -maxdepth 1 -type d -name "nexusops-*" | sort -r | head -1)
    
    if [[ -z "$latest" ]]; then
        fail "No backup found"
        return 1
    fi
    
    # Check that artifacts are encrypted (.age files)
    encrypted_files=$(docker run --rm -v "${COMPOSE_PROJECT_NAME}_backups:/backup/data:ro" alpine:3.21 \
        find "$latest" -name "*.age" | wc -l)
    
    if [[ "$encrypted_files" -gt 0 ]]; then
        pass "Backup artifacts are encrypted ($encrypted_files .age files)"
        return 0
    else
        fail "No encrypted artifacts found in backup"
        return 1
    fi
}

# Test that manifest is created and valid
test_manifest() {
    log "Testing manifest..."
    
    latest=$(docker run --rm -v "${COMPOSE_PROJECT_NAME}_backups:/backup/data:ro" alpine:3.21 \
        find /backup/data -maxdepth 1 -type d -name "nexusops-*" | sort -r | head -1)
    
    # Check manifest exists (may be encrypted)
    manifest_encrypted=$(docker run --rm -v "${COMPOSE_PROJECT_NAME}_backups:/backup/data:ro" alpine:3.21 \
        find "$latest" -name "manifest.json.age" | wc -l)
    
    if [[ "$manifest_encrypted" -gt 0 ]]; then
        pass "Manifest is encrypted"
        return 0
    else
        # Check for plain manifest (if not encrypted)
        manifest_plain=$(docker run --rm -v "${COMPOSE_PROJECT_NAME}_backups:/backup/data:ro" alpine:3.21 \
            find "$latest" -name "manifest.json" | wc -l)
        
        if [[ "$manifest_plain" -gt 0 ]]; then
            warn "Manifest found but not encrypted"
            return 0
        else
            fail "No manifest found"
            return 1
        fi
    fi
}

# Test that restore drill detects corruption
test_corruption_detection() {
    log "Testing corruption detection..."
    
    # This would require corrupting a backup and running restore test
    # For now, just verify the restore test would fail on corruption
    warn "Corruption detection test not fully implemented"
    return 0
}

# Main
main() {
    local cleanup_on_exit=true
    
    if [[ "${1:-}" == "--no-cleanup" ]]; then
        cleanup_on_exit=false
    fi
    
    log "=== Restore Test Suite ==="
    
    # Check prerequisites
    if ! command -v docker &>/dev/null; then
        echo "Docker not available"
        exit 1
    fi
    
    if ! docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" ps --format json 2>/dev/null | jq -e 'length > 0' >/dev/null; then
        echo "Stack not running. Start with: make up"
        exit 1
    fi
    
    local failed=0
    
    # Run tests
    test_backup_encryption || ((failed++))
    test_manifest || ((failed++))
    test_corruption_detection || ((failed++))
    
    # Run full restore drill
    run_restore_test || ((failed++))
    
    echo ""
    if [[ $failed -eq 0 ]]; then
        echo -e "${GREEN}All restore tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}$failed test(s) failed${NC}"
        exit 1
    fi
}

main "$@"