#!/usr/bin/env bash
# healthcheck.sh - Backup service healthcheck
# Verifies the backup service can reach dependencies and has required tools.

set -euo pipefail

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

# Check required tools
for tool in pg_dump pg_restore restic age curl jq supercronic bash; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        log "Missing tool: ${tool}"
        exit 1
    fi
done

# Check environment variables
if [[ -z "${BACKUP_AGE_RECIPIENT}" ]]; then
    log "WARNING: BACKUP_AGE_RECIPIENT not set"
fi

# Check connectivity to PostgreSQL
if ! pg_isready -h "${POSTGRES_HOST:-postgres}" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USER:-nexusops}" -d "${POSTGRES_DB:-nexusops}" >/dev/null 2>&1; then
    log "Cannot reach PostgreSQL"
    exit 1
fi

# Check connectivity to Redis
if ! redis-cli -h "${REDIS_HOST:-redis}" -p "${REDIS_PORT:-6379}" -a "${REDIS_PASSWORD:-}" ping >/dev/null 2>&1; then
    log "Cannot reach Redis"
    exit 1
fi

# Check connectivity to Qdrant
if ! curl -fsS "http://${QDRANT_HOST:-qdrant}:${QDRANT_PORT:-6333}/healthz" >/dev/null 2>&1; then
    log "Cannot reach Qdrant"
    exit 1
fi

log "Healthcheck OK"
exit 0