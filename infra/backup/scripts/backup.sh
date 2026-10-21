#!/usr/bin/env bash
# backup.sh - Automated encrypted backup for NexusOps
# Reads configuration from environment variables.

set -euo pipefail

# ============================================================================
# Configuration (from environment)
# ============================================================================

BACKUP_DIR="${BACKUP_DIR:-/backup/data}"
TMP_DIR="${TMP_DIR:-/backup/tmp}"
BACKUP_AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT:-}"
BACKUP_S3_ENABLED="${BACKUP_S3_ENABLED:-false}"
BACKUP_S3_ENDPOINT="${BACKUP_S3_ENDPOINT:-}"
BACKUP_S3_BUCKET="${BACKUP_S3_BUCKET:-}"
BACKUP_S3_PREFIX="${BACKUP_S3_PREFIX:-nexusops}"
BACKUP_S3_ACCESS_KEY="${BACKUP_S3_ACCESS_KEY:-}"
BACKUP_S3_SECRET_KEY="${BACKUP_S3_SECRET_KEY:-}"
BACKUP_S3_REGION="${BACKUP_S3_REGION:-us-east-1}"
BACKUP_RETENTION_DAILY="${BACKUP_RETENTION_DAILY:-7}"
BACKUP_RETENTION_WEEKLY="${BACKUP_RETENTION_WEEKLY:-4}"
BACKUP_RETENTION_MONTHLY="${BACKUP_RETENTION_MONTHLY:-6}"
ALERT_TELEGRAM_BOT_TOKEN="${ALERT_TELEGRAM_BOT_TOKEN:-}"
ALERT_TELEGRAM_CHAT_ID="${ALERT_TELEGRAM_CHAT_ID:-}"
BACKUP_HEARTBEAT_URL="${BACKUP_HEARTBEAT_URL:-}"

# Service connection details
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

# Derived
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
HOSTNAME="$(hostname)"
BACKUP_NAME="nexusops-${TIMESTAMP}"
WORK_DIR="${TMP_DIR}/${BACKUP_NAME}"
MANIFEST_FILE="${WORK_DIR}/manifest.json"

# ============================================================================
# Helpers
# ============================================================================

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >&2
}

notify_telegram() {
    local status="$1"
    local message="$2"
    if [[ -n "${ALERT_TELEGRAM_BOT_TOKEN}" && -n "${ALERT_TELEGRAM_CHAT_ID}" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${ALERT_TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${ALERT_TELEGRAM_CHAT_ID}" \
            -d text="🔔 NexusOps Backup ${status}: ${message}" \
            -d parse_mode="Markdown" >/dev/null || true
    fi
}

notify_heartbeat() {
    if [[ -n "${BACKUP_HEARTBEAT_URL}" ]]; then
        curl -fsS --max-time 10 "${BACKUP_HEARTBEAT_URL}" >/dev/null || true
    fi
}

cleanup() {
    log "Cleaning up temporary files..."
    rm -rf "${WORK_DIR}"
}

# Trap cleanup on exit
trap cleanup EXIT

# ============================================================================
# Backup functions
# ============================================================================

backup_postgres() {
    log "Backing up PostgreSQL..."
    local dump_file="${WORK_DIR}/postgres.dump"
    PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump \
        --host="${POSTGRES_HOST}" \
        --port="${POSTGRES_PORT}" \
        --username="${POSTGRES_USER}" \
        --dbname="${POSTGRES_DB}" \
        --format=custom \
        --no-owner \
        --no-privileges \
        --file="${dump_file}"
    echo "${dump_file}"
}

backup_qdrant() {
    log "Backing up Qdrant collections..."
    local snapshots_dir="${WORK_DIR}/qdrant-snapshots"
    mkdir -p "${snapshots_dir}"

    # Get all collections
    local collections
    collections=$(curl -fsS -H "api-key: ${QDRANT_API_KEY}" \
        "http://${QDRANT_HOST}:${QDRANT_PORT}/collections" | jq -r '.result.collections[].name')

    local snapshot_files=()
    for coll in ${collections}; do
        log "Creating snapshot for collection: ${coll}"
        local snapshot_name="${coll}-${TIMESTAMP}"
        curl -fsS -X POST -H "api-key: ${QDRANT_API_KEY}" \
            "http://${QDRANT_HOST}:${QDRANT_PORT}/collections/${coll}/snapshots" \
            -d "{\"name\": \"${snapshot_name}\"}" >/dev/null

        # Wait for snapshot to be ready (poll)
        local max_wait=60
        local waited=0
        while [[ ${waited} -lt ${max_wait} ]]; do
            local status
            status=$(curl -fsS -H "api-key: ${QDRANT_API_KEY}" \
                "http://${QDRANT_HOST}:${QDRANT_PORT}/collections/${coll}/snapshots/${snapshot_name}" | jq -r '.result.status // "unknown"')
            if [[ "${status}" == "completed" ]]; then
                break
            fi
            sleep 2
            waited=$((waited + 2))
        done

        if [[ "${status}" != "completed" ]]; then
            log "WARNING: Snapshot for ${coll} did not complete in time (status: ${status})"
            continue
        fi

        # Download snapshot
        local snapshot_file="${snapshots_dir}/${coll}.snapshot"
        curl -fsS -H "api-key: ${QDRANT_API_KEY}" \
            "http://${QDRANT_HOST}:${QDRANT_PORT}/collections/${coll}/snapshots/${snapshot_name}" \
            --output "${snapshot_file}"
        snapshot_files+=("${snapshot_file}")

        # Delete remote snapshot to save space
        curl -fsS -X DELETE -H "api-key: ${QDRANT_API_KEY}" \
            "http://${QDRANT_HOST}:${QDRANT_PORT}/collections/${coll}/snapshots/${snapshot_name}" >/dev/null || true
    done

    echo "${snapshots_dir}"
}

backup_n8n_data() {
    log "Backing up n8n data volume..."
    local n8n_backup="${WORK_DIR}/n8n-data.tar.gz"
    if [[ -d "${N8N_DATA_PATH}" ]]; then
        tar -czf "${n8n_backup}" -C "$(dirname "${N8N_DATA_PATH}")" "$(basename "${N8N_DATA_PATH}")"
    else
        log "WARNING: n8n data path ${N8N_DATA_PATH} not found"
        touch "${n8n_backup}"
    fi
    echo "${n8n_backup}"
}

backup_traefik_acme() {
    log "Backing up Traefik acme.json..."
    local acme_backup="${WORK_DIR}/acme.json"
    if [[ -f "${TRAEFIK_ACME_PATH}" ]]; then
        cp "${TRAEFIK_ACME_PATH}" "${acme_backup}"
    else
        log "WARNING: Traefik acme.json not found at ${TRAEFIK_ACME_PATH}"
        touch "${acme_backup}"
    fi
    echo "${acme_backup}"
}

create_manifest() {
    log "Creating manifest..."
    local postgres_dump="${1}"
    local qdrant_dir="${2}"
    local n8n_backup="${3}"
    local acme_backup="${4}"

    # Get versions
    local postgres_version qdrant_version n8n_version
    postgres_version=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql --host="${POSTGRES_HOST}" --port="${POSTGRES_PORT}" --username="${POSTGRES_USER}" --dbname="${POSTGRES_DB}" --tuples-only --command "SELECT version();" | head -1 | xargs)
    qdrant_version=$(curl -fsS "http://${QDRANT_HOST}:${QDRANT_PORT}/" | jq -r '.version // "unknown"')
    n8n_version="$(cat ${N8N_DATA_PATH}/.n8n/config 2>/dev/null | jq -r '.version // "unknown"' || echo "unknown")"

    # Calculate checksums and sizes
    local postgres_checksum postgres_size
    postgres_checksum=$(sha256sum "${postgres_dump}" | awk '{print $1}')
    postgres_size=$(stat -c%s "${postgres_dump}")

    local n8n_checksum n8n_size
    n8n_checksum=$(sha256sum "${n8n_backup}" | awk '{print $1}')
    n8n_size=$(stat -c%s "${n8n_backup}")

    local acme_checksum acme_size
    acme_checksum=$(sha256sum "${acme_backup}" | awk '{print $1}')
    acme_size=$(stat -c%s "${acme_backup}")

    local qdrant_snapshots=()
    for snap in "${qdrant_dir}"/*.snapshot; do
        [[ -f "${snap}" ]] || continue
        local cs sz name
        cs=$(sha256sum "${snap}" | awk '{print $1}')
        sz=$(stat -c%s "${snap}")
        name=$(basename "${snap}")
        qdrant_snapshots+=("{\"name\": \"${name}\", \"checksum\": \"${cs}\", \"size\": ${sz}}")
    done
    local qdrant_json=$(IFS=,; echo "[${qdrant_snapshots[*]}]")

    cat > "${MANIFEST_FILE}" <<EOF
{
  "backup_name": "${BACKUP_NAME}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "hostname": "${HOSTNAME}",
  "versions": {
    "postgres": "${postgres_version}",
    "qdrant": "${qdrant_version}",
    "n8n": "${n8n_version}"
  },
  "artifacts": {
    "postgres": {
      "file": "postgres.dump",
      "checksum": "${postgres_checksum}",
      "size": ${postgres_size}
    },
    "qdrant": {
      "snapshots": ${qdrant_json}
    },
    "n8n_data": {
      "file": "n8n-data.tar.gz",
      "checksum": "${n8n_checksum}",
      "size": ${n8n_size}
    },
    "traefik_acme": {
      "file": "acme.json",
      "checksum": "${acme_checksum}",
      "size": ${acme_size}
    }
  }
}
EOF
    echo "${MANIFEST_FILE}"
}

encrypt_artifacts() {
    log "Encrypting artifacts with age..."
    if [[ -z "${BACKUP_AGE_RECIPIENT}" ]]; then
        log "ERROR: BACKUP_AGE_RECIPIENT not set. Cannot encrypt."
        return 1
    fi

    # Encrypt each artifact
    for artifact in "${WORK_DIR}"/postgres.dump "${WORK_DIR}"/n8n-data.tar.gz "${WORK_DIR}"/acme.json "${WORK_DIR}"/qdrant-snapshots/*.snapshot "${WORK_DIR}"/manifest.json; do
        [[ -f "${artifact}" ]] || continue
        age -r "${BACKUP_AGE_RECIPIENT}" -o "${artifact}.age" "${artifact}"
        rm "${artifact}"
    done

    # Move encrypted artifacts to backup directory
    local dest_dir="${BACKUP_DIR}/${BACKUP_NAME}"
    mkdir -p "${dest_dir}"
    mv "${WORK_DIR}"/*.age "${dest_dir}/" 2>/dev/null || true
    mv "${WORK_DIR}"/qdrant-snapshots/*.age "${dest_dir}/" 2>/dev/null || true

    echo "${dest_dir}"
}

sync_to_s3() {
    local src_dir="$1"
    if [[ "${BACKUP_S3_ENABLED}" != "true" ]]; then
        return 0
    fi
    log "Syncing to S3-compatible storage..."

    if [[ -z "${BACKUP_S3_ENDPOINT}" || -z "${BACKUP_S3_BUCKET}" || -z "${BACKUP_S3_ACCESS_KEY}" || -z "${BACKUP_S3_SECRET_KEY}" ]]; then
        log "WARNING: S3 sync enabled but required variables not set"
        return 0
    fi

    # Use restic for S3 sync (restic supports S3 natively)
    export RESTIC_PASSWORD="${BACKUP_AGE_RECIPIENT}"  # Not used for encryption here, just repo init
    export AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY}"
    export AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_KEY}"

    local repo="s3:${BACKUP_S3_ENDPOINT}/${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX}"
    restic -r "${repo}" init 2>/dev/null || true
    restic -r "${repo}" backup "${src_dir}" --tag "backup-${TIMESTAMP}"
}

apply_retention() {
    log "Applying retention policy..."
    if [[ "${BACKUP_S3_ENABLED}" == "true" ]]; then
        # Restic retention on S3 repo
        export RESTIC_PASSWORD="${BACKUP_AGE_RECIPIENT}"
        export AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY}"
        export AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_KEY}"
        local repo="s3:${BACKUP_S3_ENDPOINT}/${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX}"
        restic -r "${repo}" forget \
            --keep-daily "${BACKUP_RETENTION_DAILY}" \
            --keep-weekly "${BACKUP_RETENTION_WEEKLY}" \
            --keep-monthly "${BACKUP_RETENTION_MONTHLY}" \
            --prune
    else
        # Local retention: find and delete old backup directories
        local now daily_cutoff weekly_cutoff monthly_cutoff
        now=$(date -u +%s)
        daily_cutoff=$((now - BACKUP_RETENTION_DAILY * 86400))
        weekly_cutoff=$((now - BACKUP_RETENTION_WEEKLY * 7 * 86400))
        monthly_cutoff=$((now - BACKUP_RETENTION_MONTHLY * 30 * 86400))

        # This is a simplified local retention - for production use restic locally too
        find "${BACKUP_DIR}" -maxdepth 1 -type d -name "nexusops-*" | while read -r dir; do
            local dir_name dir_ts dir_epoch
            dir_name=$(basename "${dir}")
            dir_ts=$(echo "${dir_name}" | sed 's/nexusops-//' | sed 's/T/ /' | sed 's/Z//')
            dir_epoch=$(date -u -d "${dir_ts}" +%s 2>/dev/null || echo 0)

            # Determine if this is a daily/weekly/monthly snapshot
            local day_of_month day_of_week
            day_of_month=$(date -u -d "@${dir_epoch}" +%d 2>/dev/null || echo 0)
            day_of_week=$(date -u -d "@${dir_epoch}" +%u 2>/dev/null || echo 0)

            local keep=false
            if [[ ${dir_epoch} -gt ${daily_cutoff} ]]; then
                keep=true
            elif [[ ${dir_epoch} -gt ${weekly_cutoff} && ${day_of_week} -eq 7 ]]; then
                keep=true
            elif [[ ${dir_epoch} -gt ${monthly_cutoff} && ${day_of_month} -eq 01 ]]; then
                keep=true
            fi

            if [[ "${keep}" != "true" ]]; then
                log "Removing old backup: ${dir_name}"
                rm -rf "${dir}"
            fi
        done
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    log "Starting backup: ${BACKUP_NAME}"
    mkdir -p "${WORK_DIR}" "${BACKUP_DIR}"

    local postgres_dump qdrant_dir n8n_backup acme_backup manifest

    postgres_dump=$(backup_postgres)
    qdrant_dir=$(backup_qdrant)
    n8n_backup=$(backup_n8n_data)
    acme_backup=$(backup_traefik_acme)
    manifest=$(create_manifest "${postgres_dump}" "${qdrant_dir}" "${n8n_backup}" "${acme_backup}")

    local encrypted_dir
    encrypted_dir=$(encrypt_artifacts)

    sync_to_s3 "${encrypted_dir}"
    apply_retention

    log "Backup completed successfully: ${encrypted_dir}"
    notify_telegram "SUCCESS" "Backup ${BACKUP_NAME} completed"
    notify_heartbeat
}

main "$@"