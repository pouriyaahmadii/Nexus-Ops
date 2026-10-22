#!/usr/bin/env bash
# check-workflows.sh - Validate n8n workflow JSON files
# Ensures no credentials/secrets embedded, stable IDs, unique names.

set -euo pipefail

WORKFLOWS_DIR="${1:-workflows}"
EXIT_CODE=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "$*"
}

check_file() {
    local file="$1"
    local errors=0
    
    log "${BLUE}Checking: $file${NC}"
    
    # Check valid JSON
    if ! jq empty "$file" 2>/dev/null; then
        log "  ${RED}✗${NC} Invalid JSON"
        return 1
    fi
    
    # Check required fields
    local name id active nodes connections
    name=$(jq -r '.name // empty' "$file")
    id=$(jq -r '.id // empty' "$file")
    active=$(jq -r '.active // empty' "$file")
    nodes=$(jq -c '.nodes // []' "$file")
    connections=$(jq -c '.connections // {}' "$file")
    
    if [[ -z "$name" ]]; then
        log "  ${RED}✗${NC} Missing 'name' field"
        ((errors++))
    fi
    
    if [[ -z "$id" ]]; then
        log "  ${RED}✗${NC} Missing 'id' field (required for idempotent imports)"
        ((errors++))
    elif [[ ! "$id" =~ ^[a-z0-9_-]+$ ]]; then
        log "  ${YELLOW}⚠${NC} ID '$id' should be lowercase with hyphens/underscores only"
    fi
    
    if [[ -z "$active" ]]; then
        log "  ${YELLOW}⚠${NC} Missing 'active' field (default: false)"
    fi
    
    # Check for embedded credentials/secrets
    local content
    content=$(cat "$file")
    
    # Patterns that indicate secrets
    if echo "$content" | grep -qiE '(api[_-]?key|secret|password|token|credential).*[:=]\s*["'\''][a-zA-Z0-9_\-]{20,}'; then
        log "  ${RED}✗${NC} Possible embedded secret/credential detected"
        ((errors++))
    fi
    
    # Check for hardcoded URLs with credentials
    if echo "$content" | grep -qE 'https?://[^:]+:[^@]+@'; then
        log "  ${RED}✗${NC} URL with embedded credentials found"
        ((errors++))
    fi
    
    # Check nodes for credential references (should use credential names, not values)
    if echo "$nodes" | jq -e '.[].credentials // empty' >/dev/null 2>&1; then
        # This is OK - credentials are referenced by name
        :
    fi
    
    # Check for unique node names within workflow
    local node_names
    node_names=$(echo "$nodes" | jq -r '.[].name' | sort | uniq -d)
    if [[ -n "$node_names" ]]; then
        log "  ${RED}✗${NC} Duplicate node names: $node_names"
        ((errors++))
    fi
    
    # Validate connections reference existing nodes
    local node_ids
    node_ids=$(echo "$nodes" | jq -r '.[].id' | sort -u)
    local conn_refs
    conn_refs=$(echo "$connections" | jq -r 'to_entries[] | .key' | sort -u)
    
    for ref in $conn_refs; do
        if ! echo "$node_ids" | grep -q "^$ref$"; then
            log "  ${RED}✗${NC} Connection references non-existent node: $ref"
            ((errors++))
        fi
    done
    
    if [[ $errors -eq 0 ]]; then
        log "  ${GREEN}✓${NC} Valid"
        return 0
    else
        return 1
    fi
}

main() {
    log "=== n8n Workflow Validation ==="
    log "Directory: $WORKFLOWS_DIR"
    log ""
    
    shopt -s globstar
    for file in "$WORKFLOWS_DIR"/**/*.json; do
        [[ -f "$file" ]] || continue
        if ! check_file "$file"; then
            EXIT_CODE=1
        fi
        log ""
    done
    
    log "=== Summary ==="
    if [[ $EXIT_CODE -eq 0 ]]; then
        log "${GREEN}All workflows valid!${NC}"
    else
        log "${RED}Validation failed!${NC}"
    fi
    exit $EXIT_CODE
}

main "$@"