#!/usr/bin/env bash
# entrypoint.sh - Backup service entrypoint
# Renders crontab from BACKUP_CRON env var and starts supercronic.

set -euo pipefail

# Render crontab
CRON_SCHEDULE="${BACKUP_CRON:-0 3 * * *}"
cat > /scripts/crontab <<EOF
# Auto-generated crontab for backup service
# Schedule: ${CRON_SCHEDULE}

${CRON_SCHEDULE} /scripts/backup.sh >> /backup/logs/backup.log 2>&1
EOF

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

log "Backup service starting..."
log "Cron schedule: ${CRON_SCHEDULE}"

# Create log directory
mkdir -p /backup/logs

# Start supercronic
exec supercronic /scripts/crontab