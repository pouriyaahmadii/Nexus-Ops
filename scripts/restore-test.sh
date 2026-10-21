#!/usr/bin/env bash
# restore-test.sh - Host-side wrapper for make restore-test
# Runs the automated restore drill in an isolated environment.

set -euo pipefail

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-nexusops}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

log "Starting restore drill..."
# The restore-test script creates its own isolated compose project
# We just need to run it with access to the backup volume and Docker socket
docker run --rm \
    --name "${COMPOSE_PROJECT_NAME}-restore-test" \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v nexusops_backups:/backup/data:ro \
    -v nexusops_n8n_data:/n8n/data:ro \
    -v nexusops_letsencrypt:/traefik:ro \
    -e BACKUP_DIR=/backup/data \
    -e BACKUP_AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT}" \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    -e REDIS_PASSWORD="${REDIS_PASSWORD}" \
    -e QDRANT_API_KEY="${QDRANT_API_KEY}" \
    -e N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY}" \
    -e BACKUP_S3_ENABLED="${BACKUP_S3_ENABLED:-false}" \
    -e BACKUP_S3_ENDPOINT="${BACKUP_S3_ENDPOINT}" \
    -e BACKUP_S3_BUCKET="${BACKUP_S3_BUCKET}" \
    -e BACKUP_S3_PREFIX="${BACKUP_S3_PREFIX}" \
    -e BACKUP_S3_ACCESS_KEY="${BACKUP_S3_ACCESS_KEY}" \
    -e BACKUP_S3_SECRET_KEY="${BACKUP_S3_SECRET_KEY}" \
    nexusops-backup:latest /scripts/restore-test.sh

log "Restore drill completed."