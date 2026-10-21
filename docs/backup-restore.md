# NexusOps Backup & Restore Runbook

## Overview

This runbook covers the automated encrypted backup system for NexusOps, including:
- What is backed up and how
- Encryption and key management
- Retention policies
- Disaster recovery procedures
- Restore drill automation

## What Gets Backed Up

| Component | Method | Frequency |
|-----------|--------|-----------|
| PostgreSQL (all databases) | `pg_dump --format=custom` | Per backup run |
| Qdrant collections | Qdrant API snapshot per collection | Per backup run |
| n8n data volume (`/home/node/.n8n`) | `tar.gz` archive | Per backup run |
| Traefik `acme.json` (Let's Encrypt certs) | Direct copy | Per backup run |
| Manifest (`manifest.json`) | Generated JSON with checksums, versions, sizes | Per backup run |

All artifacts are encrypted with **age** using the `BACKUP_AGE_RECIPIENT` public key.

## Encryption & Key Management

### Key Generation

```bash
# Generate age key pair (run OFFLINE on secure machine)
age-keygen -o age-key.txt

# age-key.txt contains:
# AGE-SECRET-KEY-... (PRIVATE - NEVER PUT ON SERVER)
# age1... (PUBLIC - PUT IN BACKUP_AGE_RECIPIENT)
```

### Key Storage

| Key | Location | Access |
|-----|----------|--------|
| Private (AGE-SECRET-KEY) | **Offline only** (password manager, hardware token, printed QR) | Human operator only |
| Public (age1...) | `.env` as `BACKUP_AGE_RECIPIENT` | Backup service (read-only) |

**Critical**: The private key MUST NEVER be stored on the server. If the server is compromised, the attacker cannot decrypt existing backups.

### Decryption (Recovery)

```bash
# With private key file
age --decrypt -i age-key.txt -o manifest.json manifest.json.age

# Or via stdin
cat age-key.txt | age --decrypt -i - -o manifest.json manifest.json.age
```

## Retention Policy

| Tier | Count | Criteria |
|------|-------|----------|
| Daily | 7 | Last 7 daily snapshots |
| Weekly | 4 | Last 4 Sunday snapshots |
| Monthly | 6 | Last 6 1st-of-month snapshots |

Configured via:
- `BACKUP_RETENTION_DAILY=7`
- `BACKUP_RETENTION_WEEKLY=4`
- `BACKUP_RETENTION_MONTHLY=6`

Restic handles retention on S3. Local retention uses simplified directory aging (production should use restic local repo).

## Offsite Storage (S3)

Enable with `BACKUP_S3_ENABLED=true` and configure:
- `BACKUP_S3_ENDPOINT` (e.g., `https://s3.amazonaws.com` or MinIO)
- `BACKUP_S3_BUCKET`
- `BACKUP_S3_PREFIX` (default: `nexusops`)
- `BACKUP_S3_ACCESS_KEY` / `BACKUP_S3_SECRET_KEY`
- `BACKUP_S3_REGION`

Restic creates a repository at `s3:<endpoint>/<bucket>/<prefix>` and pushes encrypted artifacts.

## Notifications

| Event | Telegram | Healthchecks.io |
|-------|----------|-----------------|
| Success | ✅ | ✅ (ping) |
| Failure | ✅ | ❌ |

Configure:
- `ALERT_TELEGRAM_BOT_TOKEN` + `ALERT_TELEGRAM_CHAT_ID`
- `BACKUP_HEARTBEAT_URL` (e.g., `https://hc-ping.com/your-uuid`)

## Operational Commands

### Trigger Manual Backup

```bash
make backup
```

### List Available Backups

```bash
make backup-list
```

### Restore from Backup

```bash
# Interactive (asks for confirmation)
make restore SNAPSHOT=nexusops-20261022T030000Z

# Non-interactive (CI/CD)
make restore SNAPSHOT=nexusops-20261022T030000Z AUTO_YES=true
```

**After restore**: Restart n8n services to pick up restored data:
```bash
docker compose -p nexusops restart n8n-main n8n-webhook n8n-worker
```

### Run Restore Drill (Automated Verification)

```bash
make restore-test
```

This spins up an isolated throwaway Compose project (`nexusops-restore-test-<timestamp>`), restores the latest backup, verifies:
1. PostgreSQL row counts for key tables
2. Qdrant collections and point counts match manifest
3. n8n starts and lists workflows via CLI

Exits non-zero on any mismatch. Cleans up automatically.

## Disaster Recovery: Brand New Server

### Prerequisites
- Fresh server with Docker + Docker Compose installed
- `.env` file with all secrets (including `BACKUP_AGE_RECIPIENT` public key)
- Access to offsite backup storage (if using S3)
- **Private age key** (offline)

### Recovery Steps

1. **Clone repository and configure**:
   ```bash
   git clone <repo> nexusops
   cd nexusops
   cp .env.example .env
   # Fill in ALL secrets from your password manager
   ```

2. **Restore latest backup**:
   - If using S3: Backup service will fetch from restic repo on S3
   - If local only: Copy backup directory to `./backups/` on new server
   ```bash
   # Example: restore from S3 (requires restic + credentials)
   docker run --rm \
       -e RESTIC_PASSWORD=... \
       -e AWS_ACCESS_KEY_ID=... \
       -e AWS_SECRET_ACCESS_KEY=... \
       restic:0.18.0 -r s3:.../nexusops restore latest --target /tmp/restore
   ```

3. **Decrypt artifacts** (requires private age key):
   ```bash
   age --decrypt -i /path/to/private-key.txt -o postgres.dump postgres.dump.age
   age --decrypt -i /path/to/private-key.txt -o n8n-data.tar.gz n8n-data.tar.gz.age
   age --decrypt -i /path/to/private-key.txt -o acme.json acme.json.age
   ```

4. **Start core services (Postgres, Redis, Qdrant)**:
   ```bash
   docker compose -p nexusops up -d postgres redis qdrant
   # Wait for healthy
   ```

5. **Restore PostgreSQL**:
   ```bash
   PGPASSWORD=$POSTGRES_PASSWORD pg_restore \
       --host=localhost --port=5433 \
       --username=$POSTGRES_USER --dbname=$POSTGRES_DB \
       --clean --if-exists --no-owner --no-privileges \
       postgres.dump
   ```

6. **Restore n8n data**:
   ```bash
   tar -xzf n8n-data.tar.gz -C /path/to/n8n_data_volume
   ```

7. **Restore Traefik acme.json**:
   ```bash
   cp acme.json /path/to/letsencrypt/acme.json
   ```

8. **Restore Qdrant** (upload snapshots via API):
   ```bash
   for snap in qdrant-snapshots/*.snapshot; do
       curl -X POST -H "api-key: $QDRANT_API_KEY" \
           http://localhost:6333/collections/$(basename $snap .snapshot)/snapshots/upload \
           -F "snapshot=@$snap"
   done
   ```

9. **Start full stack**:
   ```bash
   docker compose -p nexusops up -d
   ```

10. **Verify**:
    - https://n8n.yourdomain.com loads
    - Workflows visible
    - Webhooks respond

## What If You Lost the n8n Encryption Key?

**This is a catastrophic scenario.** The `N8N_ENCRYPTION_KEY` encrypts:
- Credentials (API keys, tokens, passwords) stored in n8n
- Workflow execution data (if binary data mode = filesystem)

### If You Have a Backup

1. The backup includes the n8n data volume which contains the encryption key in the n8n config database.
2. Restore the backup **including the n8n data volume**.
3. The restored n8n instance will have the same encryption key and can decrypt existing credentials.

### If You Lost Both the Key AND All Backups

**Credentials are permanently unrecoverable.** You must:
1. Re-create all credentials in n8n manually
2. Re-enter all API keys, passwords, tokens
3. Update any workflows that reference credentials

### Prevention

- Store `N8N_ENCRYPTION_KEY` in **multiple** offline locations
- Include it in your backup's `.env` restoration procedure
- Test restore drill regularly (`make restore-test`)

## RPO / RTO

| Metric | Target | Notes |
|--------|--------|-------|
| RPO (Recovery Point Objective) | ≤ 24 hours | Daily backups at 03:00 UTC |
| RTO (Recovery Time Objective) | ≤ 1 hour | Automated restore drill validates this |

## Testing the Failure Case

To verify the restore drill catches corruption:

```bash
# Corrupt a backup artifact
echo "corrupted" > /backup/data/nexusops-20261022T030000Z/postgres.dump.age

# Run restore test - should fail
make restore-test
# Expected: non-zero exit code with checksum mismatch error
```

## Troubleshooting

| Issue | Resolution |
|-------|------------|
| `age: no identity found` | Private key not provided; ensure `BACKUP_AGE_RECIPIENT` is public key only |
| `restic: repository does not exist` | Run `restic init` on S3 repo first |
| `pg_restore: connection refused` | Ensure Postgres is healthy before restore |
| `Qdrant snapshot upload fails` | Check Qdrant API key and network connectivity |
| `restore-test: n8n not healthy` | Increase `start_period` or check n8n logs |

## File Locations

| File | Purpose |
|------|---------|
| `infra/backup/Dockerfile` | Backup service image |
| `infra/backup/scripts/backup.sh` | Main backup logic |
| `infra/backup/scripts/restore.sh` | Restore logic |
| `infra/backup/scripts/restore-test.sh` | Automated restore drill |
| `infra/backup/scripts/healthcheck.sh` | Service healthcheck |
| `infra/backup/scripts/entrypoint.sh` | Cron schedule renderer |
| `scripts/backup.sh` | Host-side `make backup` wrapper |
| `scripts/restore.sh` | Host-side `make restore` wrapper |
| `scripts/restore-test.sh` | Host-side `make restore-test` wrapper |
| `docs/adr/0003-backup-tool-choice.md` | ADR: restic vs rclone |