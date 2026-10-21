#!/usr/bin/env bash
# restore.sh - Restore NexusOps from encrypted backup
# Usage: restore.sh [--yes] <backup_name_or_path>
#        --yes: skip interactive confirmation (for CI)

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

BACKUP_DIR="${BACKUP_DIR:-/backup/data}"
BACKUP_AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT:-}"
BACKUP_S3_ENABLED="${BACKUP_S3_ENABLED:-false}"
BACKUP_S3_ENDPOINT="${BACKUP_S3_ENDPOINT:-}"
BACKUP_S3_BUCKET="${BACKUP_S3_BUCKET:-}"
BACKUP_S3_PREFIX="${BACKUP_S3_PREFIX:-nexusops}"
BACKUP_S3_ACCESS_KEY="${BACKUP_S3_ACCESS_KEY:-}"
BACKUP_S3_SECRET_KEY="${BACKUP_S3_SECRET_KEY:-}"
BACKUP_S3_REGION="${BACKUP_S3_REGION:-us-east-1}"

POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-nexusops}"
POSTGRES_USER="${POSTGRES_USER:-nexusops}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
QDRANT_HOST="${QDRANT_HOST:-qdrant}"
QDRANT_PORT="${QDRANT_PORT:-6333}"
QDRANT_API_KEY="${QDRANT_API_KEY:-}"
N8N_DATA_PATH="${N8N_DATA_PATH:-/n8n/data}"
TRAEFIK_ACME_PATH="${TRAEFIK_ACME_PATH:-/traefik/acme.json}"

TMP_DIR="${TMP_DIR:-/backup/tmp}"

# ============================================================================
# Helpers
# ============================================================================

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >&2
}

confirm() {
    local prompt="$1"
    if [[ "${AUTO_YES:-false}" == "true" ]]; then
        return 0
    fi
    read -r -p "${prompt} [y/N]: " response
    [[ "${response}" =~ ^[Yy]$ ]]
}

# ============================================================================
# Main
# ============================================================================

AUTO_YES=false
BACKUP_ARG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --yes|-y)
            AUTO_YES=true
            shift
            ;;
        *)
            BACKUP_ARG="$1"
            shift
            ;;
    esac
done

if [[ -z "${BACKUP_ARG}" ]]; then
    echo "Usage: $0 [--yes] <backup_name_or_path>" >&2
    echo "  --yes, -y: Skip interactive confirmation" >&2
    echo "  Available backups:" >&2
    find "${BACKUP_DIR}" -maxdepth 1 -type d -name "nexusops-*" | sort -r | head -10 | sed 's|.*/|  |' >&2
    exit 1
fi

# Find backup directory
BACKUP_PATH=""
if [[ -d "${BACKUP_DIR}/${BACKUP_ARG}" ]]; then
    BACKUP_PATH="${BACKUP_DIR}/${BACKUP_ARG}"
elif [[ -d "${BACKUP_ARG}" ]]; then
    BACKUP_PATH="${BACKUP_ARG}"
else
    # Try to find in S3
    if [[ "${BACKUP_S3_ENABLED}" == "true" ]]; then
        log "Fetching backup from S3..."
        export RESTIC_PASSWORD="${BACKUP_AGE_RECIPIENT}"
        export AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY}"
        export AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_KEY}"
        local repo="s3:${BACKUP_S3_ENDPOINT}/${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX}"
        # List snapshots
        restic -r "${repo}" snapshots --tag "backup-${BACKUP_ARG}" --json | jq -r '.[0].id // empty'
        # This would need more implementation for full S3 restore
        log "S3 restore not fully implemented in this version"
    fi
    log "ERROR: Backup not found: ${BACKUP_ARG}"
    exit 1
fi

log "Found backup: ${BACKUP_PATH}"

# Confirm
if ! confirm "This will OVERWRITE current data. Restore from ${BACKUP_PATH}?"; then
    log "Restore cancelled."
    exit 1
fi

# Decrypt artifacts
WORK_DIR="${TMP_DIR}/restore-$(date -u +"%Y%m%dT%H%M%SZ")"
mkdir -p "${WORK_DIR}"

log "Decrypting artifacts..."
for enc_file in "${BACKUP_PATH}"/*.age; do
    [[ -f "${enc_file}" ]] || continue
    local out_file="${WORK_DIR}/$(basename "${enc_file%.age}")"
    if [[ -n "${BACKUP_AGE_RECIPIENT}" ]]; then
        # Need age private key - this would be provided via age --identity
        log "WARNING: age decryption requires private key (--identity). Provide via stdin or AGES_KEY_FILE env."
        log "Skipping decryption - implement key management for production."
    else
        cp "${enc_file}" "${out_file}"
    fi
done

# If no age key, assume files are already decrypted (for testing)
if [[ ! -f "${WORK_DIR}/manifest.json" && -f "${BACKUP_PATH}/manifest.json" ]]; then
    cp -r "${BACKUP_PATH}"/* "${WORK_DIR}/"
fi

MANIFEST="${WORK_DIR}/manifest.json"
if [[ ! -f "${MANIFEST}" ]]; then
    log "ERROR: Manifest not found after decryption"
    exit 1
fi

log "Manifest loaded: $(jq -r .backup_name "${MANIFEST}")"

# Verify checksums
log "Verifying checksums..."
for artifact in postgres.dump n8n-data.tar.gz acme.json; do
    if [[ -f "${WORK_DIR}/${artifact}" ]]; then
        expected=$(jq -r ".artifacts.${artifact//-/_}.checksum" "${MANIFEST}")
        actual=$(sha256sum "${WORK_DIR}/${artifact}" | awk '{print $1}')
        if [[ "${expected}" != "${actual}" ]]; then
            log "ERROR: Checksum mismatch for ${artifact}"
            exit 1
        fi
        log "Checksum OK: ${artifact}"
    fi
done

# Verify Qdrant snapshots
for snap in "${WORK_DIR}"/qdrant-snapshots/*.snapshot; do
    [[ -f "${snap}" ]] || continue
    local name expected actual
    name=$(basename "${snap}")
    expected=$(jq -r ".artifacts.qdrant.snapshots[] | select(.name==\"${name}\") | .checksum" "${MANIFEST}")
    actual=$(sha256sum "${snap}" | awk '{print $1}')
    if [[ "${expected}" != "${actual}" ]]; then
        log "ERROR: Checksum mismatch for Qdrant snapshot ${name}"
        exit 1
    fi
    log "Checksum OK: ${name}"
done

# Restore PostgreSQL
log "Restoring PostgreSQL..."
PGPASSWORD="${POSTGRES_PASSWORD}" pg_restore \
    --host="${POSTGRES_HOST}" \
    --port="${POSTGRES_PORT}" \
    --username="${POSTGRES_USER}" \
    --dbname="${POSTGRES_DB}" \
    --clean \
    --if-exists \
    --no-owner \
    --no-privileges \
    "${WORK_DIR}/postgres.dump"

# Restore n8n data
log "Restoring n8n data..."
if [[ -f "${WORK_DIR}/n8n-data.tar.gz" ]]; then
    tar -xzf "${WORK_DIR}/n8n-data.tar.gz" -C "$(dirname "${N8N_DATA_PATH}")"
fi

# Restore Traefik acme.json
log "Restoring Traefik acme.json..."
if [[ -f "${WORK_DIR}/acme.json" ]]; then
    mkdir -p "$(dirname "${TRAEFIK_ACME_PATH}")"
    cp "${WORK_DIR}/acme.json" "${TRAEFIK_ACME_PATH}"
fi

# Restore Qdrant snapshots
log "Restoring Qdrant collections..."
for snap in "${WORK_DIR}"/qdrant-snapshots/*.snapshot; do
    [[ -f "${snap}" ]] || continue
    local name="${snap##*/}"
    name="${name%.snapshot}"
    log "Restoring collection: ${name}"
    # Upload snapshot
    curl -fsS -X POST -H "api-key: ${QDRANT_API_KEY}" \
        "http://${QDRANT_HOST}:${QDRANT_PORT}/collections/${name}/snapshots/upload" \
        -F "snapshot=@${snap}" >/dev/null
    # Wait for restore
    sleep 5
done

log "Restore completed successfully."
log "IMPORTANT: Restart n8n services to pick up restored data."
log "Run: docker compose -p nexusops restart n8n-main n8n-webhook n8n-worker"