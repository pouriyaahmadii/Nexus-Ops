#!/usr/bin/env bash
# restore.sh - Host-side wrapper for make restore
# Runs the restore script in a container with access to volumes.

set -euo pipefail

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-nexusops}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 [--yes] <backup_name>" >&2
    exit 1
fi

log "Starting restore..."
docker compose -p "${COMPOSE_PROJECT_NAME}" -f "${COMPOSE_FILE}" run --rm \
    -e AUTO_YES="${AUTO_YES:-false}" \
    backup /scripts/restore.sh "$@"

log "Restore completed. Restart n8n services to pick up restored data."