#!/usr/bin/env bash
# backup.sh - Host-side wrapper for make backup
# Runs the backup service container to perform a backup.

set -euo pipefail

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-nexusops}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

# Run backup as a one-off container
log "Starting backup..."
docker compose -p "${COMPOSE_PROJECT_NAME}" -f "${COMPOSE_FILE}" run --rm backup /scripts/backup.sh

log "Backup completed."