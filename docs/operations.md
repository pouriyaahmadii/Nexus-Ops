# NexusOps Day-2 Operations Guide

## Overview

This guide covers routine operations, maintenance procedures, and troubleshooting for a running NexusOps deployment.

## Table of Contents

1. [Routine Operations](#routine-operations)
2. [Upgrades](#upgrades)
3. [Secret Rotation](#secret-rotation)
4. [Scaling](#scaling)
5. [Disk Growth Management](#disk-growth-management)
6. [Log Access](#log-access)
7. [Common Failure Modes](#common-failure-modes)
8. [Disaster Recovery](#disaster-recovery)

---

## Routine Operations

### Daily Checks
```bash
# Health overview
make doctor

# Check backup status
make backup-list

# Check pending approvals
docker exec nexusops_postgres psql -U nexusops -d nexusops -c "SELECT * FROM ops.v_pending_approvals;"

# Check DLQ
docker exec nexusops_postgres psql -U nexusops -d nexusops -c "SELECT * FROM ops.dead_letters WHERE status='pending' LIMIT 10;"

# Check LLM budget
docker exec nexusops_postgres psql -U nexusops -d nexusops -c "SELECT * FROM ops.v_llm_cost_month_to_date;"
```

### Weekly Checks
```bash
# Run restore drill (validates backups work)
make restore-test

# Review error trends
docker exec nexusops_postgres psql -U nexusops -d nexusops -c "SELECT * FROM ops.v_error_summary WHERE error_date >= CURRENT_DATE - INTERVAL '7 days';"

# Check disk space
df -h /var/lib/docker
```

### Monthly Checks
```bash
# Rotate secrets (see Secret Rotation)
# Review and update model pricing
docker exec nexusops_postgres psql -U nexusops -d nexusops -c "SELECT * FROM ops.model_pricing;"
# Update any outdated prices from provider pages
```

---

## Upgrades

### Automated Upgrade (Recommended)
```bash
# Single command: backup → pull → recreate → verify
make upgrade
```

**What `make upgrade` does:**
1. Creates a pre-upgrade backup
2. Pulls latest Docker images
3. Recreates containers with new images
4. Runs `make doctor` to verify health

**If backup fails:** Upgrade aborts automatically. Fix backup first.

### Manual Upgrade
```bash
# 1. Backup
make backup

# 2. Pull images
docker compose -p nexusops -f compose.yaml pull

# 3. Recreate
docker compose -p nexusops -f compose.yaml up -d --force-recreate

# 4. Verify
make doctor
```

### Production Upgrade (with compose.prod.yaml)
```bash
COMPOSE_FILE=compose.yaml:compose.prod.yaml make upgrade
```

### Rollback Procedure
```bash
# 1. Stop stack
make down

# 2. List available backups
make backup-list

# 3. Restore from known good backup
make restore SNAPSHOT=nexusops-20261022T030000Z

# 4. Start stack
make up
```

---

## Secret Rotation

### PostgreSQL Passwords
```bash
# 1. Generate new passwords
NEW_POSTGRES_PASSWORD=$(openssl rand -base64 32)
NEW_OPS_WRITER_PASSWORD=$(openssl rand -base64 32)

# 2. Update in database
docker exec -i nexusops_postgres psql -U nexusops -d nexusops -c "
    ALTER USER nexusops WITH PASSWORD '$NEW_POSTGRES_PASSWORD';
    ALTER USER ops_writer WITH PASSWORD '$NEW_OPS_WRITER_PASSWORD';
"

# 3. Update .env
sed -i "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$NEW_POSTGRES_PASSWORD/" .env
sed -i "s/OPS_WRITER_PASSWORD=.*/OPS_WRITER_PASSWORD=$NEW_OPS_WRITER_PASSWORD/" .env

# 4. Restart affected services
docker compose -p nexusops restart postgres n8n-main n8n-webhook n8n-worker backup

# 5. Verify
make doctor
```

### Redis Password
```bash
NEW_REDIS_PASSWORD=$(openssl rand -base64 32)
docker exec nexusops_redis redis-cli -a "$REDIS_PASSWORD" CONFIG SET requirepass "$NEW_REDIS_PASSWORD"
sed -i "s/REDIS_PASSWORD=.*/REDIS_PASSWORD=$NEW_REDIS_PASSWORD/" .env
docker compose -p nexusops restart redis n8n-main n8n-webhook n8n-worker backup
make doctor
```

### Qdrant API Key
```bash
NEW_QDRANT_KEY=$(openssl rand -base64 32)
# Update Qdrant config (requires restart with new env)
sed -i "s/QDRANT_API_KEY=.*/QDRANT_API_KEY=$NEW_QDRANT_KEY/" .env
docker compose -p nexusops restart qdrant n8n-main n8n-webhook n8n-worker
make doctor
```

### n8n Encryption Key (⚠️ CRITICAL)
**Only rotate if you have a recent backup and understand the implications.**

```bash
# 1. Backup current key
cp .env .env.backup.$(date +%Y%m%d)

# 2. Generate new key
NEW_ENCRYPTION_KEY=$(openssl rand -base64 32)

# 2. Update .env
sed -i "s/N8N_ENCRYPTION_KEY=.*/N8N_ENCRYPTION_KEY=$NEW_ENCRYPTION_KEY/" .env

# 3. Restart n8n services
docker compose -p nexusops restart n8n-main n8n-webhook n8n-worker

# 4. Re-enter ALL credentials in n8n UI (they're encrypted with old key)
# 5. Test workflows
```

### Age Backup Key
```bash
# 1. Generate new key pair OFFLINE
age-keygen -o age-key-new.txt

# 2. Update .env with NEW PUBLIC KEY only
sed -i "s/BACKUP_AGE_RECIPIENT=.*/BACKUP_AGE_RECIPIENT=age1.../" .env

# 3. Future backups use new key; old backups still decrypt with old private key
# 4. Store old private key securely for disaster recovery
```

### Traefik Dashboard Password
```bash
NEW_PASSWORD=$(openssl rand -base64 16)
HTPASSWD=$(htpasswd -nbB admin "$NEW_PASSWORD" | sed 's/\$/\$\$/g')
sed -i "s/TRAEFIK_DASHBOARD_PASSWORD=.*/TRAEFIK_DASHBOARD_PASSWORD=$HTPASSWD/" .env
docker compose -p nexusops restart traefik
```

---

## Scaling

### n8n Workers (Horizontal)
```bash
# Scale to 4 workers
make scale WORKERS=4

# Scale back to 2
make scale WORKERS=2

# Check worker status
make workers
```

**Notes:**
- Workers are stateless; scaling is instant
- Each worker consumes ~512MB RAM, 0.5 CPU
- Queue depth determines optimal worker count

### n8n Main (Vertical - not recommended)
```bash
# Only for CPU-bound UI operations
# Edit compose.yaml: increase n8n-main deploy.resources.limits.cpus/memory
docker compose -p nexusops -f compose.yaml up -d --force-recreate n8n-main
```

### PostgreSQL (Vertical)
```bash
# Increase shared_buffers, max_connections in compose.yaml command section
# Restart postgres
docker compose -p nexusops restart postgres
```

---

## Disk Growth Management

### Monitor Disk Usage
```bash
# Host disk
df -h /

# Docker volumes
docker system df -v

# Individual volumes
docker run --rm -v nexusops_postgres_data:/data alpine du -sh /data
docker run --rm -v nexusops_redis_data:/data alpine du -sh /data
docker run --rm -v nexusops_n8n_data:/data alpine du -sh /data
docker run --rm -v nexusops_backups:/data alpine du -sh /data
```

### Cleanup Strategies

#### PostgreSQL
```bash
# Vacuum and analyze
docker exec nexusops_postgres psql -U nexusops -d nexusops -c "VACUUM ANALYZE;"

# Drop old partitions (if partitioned)
# Truncate old execution logs (keep 14 days per config)
```

#### n8n Execution Data (Auto-pruned)
```bash
# Configured via EXECUTIONS_DATA_PRUNE_MAX_AGE=336h (14 days)
# Manual cleanup if needed:
docker exec nexusops_postgres psql -U nexusops -d nexusops -c "
    DELETE FROM execution_entity WHERE started_at < NOW() - INTERVAL '30 days';
"
```

#### Redis
```bash
# Check memory
docker exec nexusops_redis redis-cli -a "$REDIS_PASSWORD" INFO memory

# Flush if needed (CAREFUL - clears queue!)
# docker exec nexusops_redis redis-cli -a "$REDIS_PASSWORD" FLUSHDB
```

#### Backups (Auto-pruned)
```bash
# Retention: daily 7, weekly 4, monthly 6
# Manual cleanup if needed:
docker run --rm -v nexusops_backups:/backup/data alpine \
    find /backup/data -maxdepth 1 -type d -name "nexusops-*" -mtime +30 -exec rm -rf {} \;
```

#### Qdrant
```bash
# Delete old collections/snapshots
curl -X DELETE -H "api-key: $QDRANT_API_KEY" \
    http://localhost:6333/collections/old_collection_name
```

---

## Log Access

### Service Logs
```bash
# All services
make logs

# Specific service
make logs SERVICE=traefik
make logs SERVICE=n8n-main
make logs SERVICE=postgres
make logs SERVICE=redis
make logs SERVICE=qdrant
make logs SERVICE=backup
make logs SERVICE=n8n-worker

# With timestamps
docker compose -p nexusops logs -f -t n8n-main

# Last N lines
docker compose -p nexusops logs --tail=100 n8n-main
```

### Structured Logs (JSON)
All services use JSON-file driver with rotation (10MB × 3 files base, 10MB × 5 compressed prod).

```bash
# Pretty-print JSON logs
docker compose -p nexusops logs n8n-main | jq .

# Filter by level
docker compose -p nexusops logs n8n-main | jq 'select(.level=="error")'
```

### Log Locations (Inside Containers)
| Service | Log Path |
|---------|----------|
| n8n | stdout/stderr (captured by Docker) |
| PostgreSQL | `/var/log/postgresql/` (if configured) |
| Redis | stdout/stderr |
| Qdrant | stdout/stderr |
| Traefik | `/var/log/traefik/` (access logs) |
| Backup | `/backup/logs/backup.log` |

### Centralized Logging (Optional)
Add Loki + Promtail to monitoring profile for log aggregation.

---

## Common Failure Modes

### 1. n8n Main Not Starting
**Symptoms:** `make doctor` shows n8n-main unhealthy
**Causes:**
- Database not ready → check `postgres` health
- Encryption key mismatch → verify `N8N_ENCRYPTION_KEY` in `.env`
- Port conflict → check port 5678 not used

**Fix:**
```bash
docker compose -p nexusops logs n8n-main
# Check for specific error, then:
docker compose -p nexusops restart n8n-main
```

### 2. Webhook Not Receiving Requests
**Symptoms:** External webhooks return 502/timeout
**Causes:**
- Traefik routing misconfigured → check labels on n8n-webhook
- n8n-webhook not healthy → check `make doctor`
- DNS/hosts file → verify `n8n.localhost` resolves

**Fix:**
```bash
# Test internal connectivity
docker exec nexusops_traefik wget -qO- http://n8n-webhook:5678/healthz

# Check Traefik dashboard for router status
```

### 3. PostgreSQL Connection Exhausted
**Symptoms:** `pg_isready` fails, n8n errors "too many connections"
**Causes:**
- `max_connections` too low (default 100)
- Connection leak in n8n

**Fix:**
```bash
# Increase in compose.yaml postgres command:
# -c max_connections=200
docker compose -p nexusops up -d --force-recreate postgres
```

### 4. Redis Memory / Queue Backup
**Symptoms:** Workers not picking up jobs, queue depth growing
**Causes:**
- `maxmemory-policy` not `noeviction` (required for Bull)
- Workers down

**Fix:**
```bash
# Verify config
docker exec nexusops_redis redis-cli -a "$REDIS_PASSWORD" CONFIG GET maxmemory-policy

# Scale workers
make scale WORKERS=4

# Check worker logs
make logs SERVICE=n8n-worker
```

### 5. Qdrant Out of Disk
**Symptoms:** Snapshots fail, collections unavailable
**Causes:**
- Vectors growing without cleanup
- Snapshots accumulating

**Fix:**
```bash
# Check disk usage
curl -H "api-key: $QDRANT_API_KEY" http://localhost:6333/collections

# Delete old snapshots
curl -X DELETE -H "api-key: $QDRANT_API_KEY" \
    http://localhost:6333/collections/<name>/snapshots/<snapshot_name>

# Optimize storage
curl -X POST -H "api-key: $QDRANT_API_KEY" \
    http://localhost:6333/collections/<name>/optimize
```

### 6. Backup Fails
**Symptoms:** `make backup` exits non-zero
**Causes:**
- `BACKUP_AGE_RECIPIENT` not set
- S3 credentials invalid
- Disk full

**Fix:**
```bash
# Run backup manually for debug
docker compose -p nexusops run --rm backup /scripts/backup.sh

# Check backup logs
docker run --rm -v nexusops_backups:/backup/data alpine cat /backup/logs/backup.log
```

### 6. Approval Webhook Not Working
**Symptoms:** Telegram buttons don't respond
**Causes:**
- `N8N_PUBLIC_URL` not set correctly
- Webhook path not routed by Traefik
- `DLQ_REPLAY_TOKEN` mismatch

**Fix:**
```bash
# Verify callback URL accessible
curl -X POST http://localhost/webhook/approval/callback/test-id/test-token \
  -H "Content-Type: application/json" \
  -d '{"callback_query":{"data":"approve:test-id:test-token","from":{"id":"123"}}}'
```

### 7. LLM Cost Budget Exceeded
**Symptoms:** `make doctor` shows FAIL on llm-budget
**Causes:**
- High usage workflows
- Missing pricing data (costs = 0, not tracked)

**Fix:**
```bash
# Check which workflows consume most
docker exec nexusops_postgres psql -U nexusops -d nexusops -c "SELECT * FROM ops.v_llm_cost_by_workflow LIMIT 10;"

# Update pricing for missing models
docker exec nexusops_postgres psql -U nexusops -d nexusops -c "
    INSERT INTO ops.model_pricing (provider, model, input_usd_per_1m, output_usd_per_1m, valid_from, source_url)
    VALUES ('openai', 'gpt-4o', 5.00, 15.00, '2024-05-01', 'https://openai.com/pricing');
"

# Deactivate high-cost workflows
# Tag with "llm-guarded" and enable BUDGET_ENFORCE=true
```

### 8. Certificate Expiry (Production)
**Symptoms:** Browser warns about expired cert
**Causes:** Let's Encrypt renewal failed

**Fix:**
```bash
# Check Traefik logs for ACME errors
docker compose -p nexusops logs traefik | grep -i acme

# Force renewal (delete acme.json and restart)
docker compose -p nexusops stop traefik
docker run --rm -v nexusops_letsencrypt:/letsencrypt alpine rm /letsencrypt/acme.json
docker compose -p nexusops up -d traefik
```

---

## Disaster Recovery

### Scenario: Complete Server Loss

1. **Provision new server** with Docker + Compose
2. **Clone repo** and configure `.env` from password manager
3. **Restore from offsite backup** (S3):
   ```bash
   # Install restic
   # Restore latest snapshot
   restic -r s3:.../nexusops restore latest --target /tmp/restore
   ```
4. **Decrypt artifacts** (requires private age key):
   ```bash
   age --decrypt -i /path/to/private-key.txt -o postgres.dump postgres.dump.age
   ```
4. **Start core services**:
   ```bash
   docker compose -p nexusops up -d postgres redis qdrant
   ```
5. **Restore PostgreSQL**:
   ```bash
   pg_restore -h localhost -p 5433 -U nexusops -d nexusops --clean --if-exists postgres.dump
   ```
6. **Restore n8n data**:
   ```bash
   tar -xzf n8n-data.tar.gz -C /var/lib/docker/volumes/nexusops_n8n_data/_data
   ```
7. **Restore Traefik certs**:
   ```bash
   cp acme.json /var/lib/docker/volumes/nexusops_letsencrypt/_data/
   ```
8. **Restore Qdrant** (upload snapshots via API)
9. **Start full stack**:
   ```bash
   docker compose -p nexusops up -d
   ```

### Scenario: Corrupted Database
```bash
# 1. Stop n8n services
docker compose -p nexusops stop n8n-main n8n-webhook n8n-worker

# 2. Restore from latest backup
make restore SNAPSHOT=nexusops-...

# 3. Start n8n services
docker compose -p nexusops start n8n-main n8n-webhook n8n-worker
```

### Scenario: Lost n8n Encryption Key
**If you have a backup:**
1. Restore backup (includes n8n data volume with encryption key in config)
2. The restored n8n will have the same key

**If NO backup:**
- All credentials in n8n are permanently unrecoverable
- Must re-enter all API keys, passwords, tokens manually
- Update any workflows referencing credentials

---

## Quick Reference

| Task | Command |
|------|---------|
| Full health check | `make doctor` |
| View logs | `make logs [SERVICE=name]` |
| List containers | `make ps` |
| Scale workers | `make scale WORKERS=4` |
| Backup now | `make backup` |
| List backups | `make backup-list` |
| Restore | `make restore SNAPSHOT=...` |
| Restore drill | `make restore-test` |
| Run demo | `make demo` |
| Upgrade | `make upgrade` |
| Validate env | `make env-check` |
| Clean everything | `make clean` |

---

## Monitoring Endpoints

| Service | Health Endpoint | Metrics |
|---------|-----------------|---------|
| n8n-main | `http://localhost:5678/healthz` | `:5678/metrics` (if `N8N_METRICS=true`) |
| n8n-webhook | `http://localhost:5678/healthz` | `:5678/metrics` |
| Traefik | `http://localhost:8080/health` | `:8080/metrics` (if enabled) |
| Qdrant | `http://localhost:6333/healthz` | `:6333/metrics` |
| PostgreSQL | `pg_isready` | `postgres_exporter` |
| Redis | `redis-cli ping` | `redis_exporter` |
| Backup | `/scripts/healthcheck.sh` | — |

---

## Support Contacts

- **Platform issues:** Internal team Slack #nexusops
- **Security incidents:** security@nexusops.example.com
- **Documentation:** This file + `docs/` directory