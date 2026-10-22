# NexusOps Troubleshooting Guide

Format: **Symptom → Cause → Fix**

## Platform Startup

### `make doctor` shows FAIL for multiple services
**Cause:** Stack not fully started, or dependencies not healthy
**Fix:**
```bash
make up
# Wait 60-120s for all healthchecks
make doctor
# If still failing, check logs:
make logs SERVICE=<failing-service>
```

### `make up` hangs or times out
**Cause:** Port conflict, image pull failure, or resource exhaustion
**Fix:**
```bash
# Check port conflicts
sudo lsof -i :80 -i :443 -i :5678 -i :6333 -i :8080

# Check image pulls
docker compose -p nexusops -f compose.yaml pull

# Check resources
df -h /var/lib/docker
free -h
```

### n8n Main not starting / stuck at "Starting..."
**Cause:** Database not ready, encryption key mismatch, or port conflict
**Fix:**
```bash
# Check Postgres health
docker exec nexusops_postgres pg_isready -U nexusops -d nexusops

# Check n8n logs
make logs SERVICE=n8n-main | head -50

# Verify N8N_ENCRYPTION_KEY in .env matches previous deploy
grep N8N_ENCRYPTION_KEY .env
```

### n8n Webhook not starting
**Cause:** n8n Main not healthy (dependency), or Redis not ready
**Fix:**
```bash
# Check dependencies
docker compose -p nexusops ps n8n-main redis

# Check webhook logs
make logs SERVICE=n8n-webhook
```

## Webhooks & Routing

### Webhooks return 502 Bad Gateway
**Cause:** Traefik can't reach n8n-webhook, or n8n-webhook unhealthy
**Fix:**
```bash
# Test internal connectivity
docker exec nexusops_traefik wget -qO- http://n8n-webhook:5678/healthz

# Check Traefik router labels
docker inspect nexusops_traefik | grep -A 20 "traefik.http.routers.n8n-webhook"

# Verify n8n-webhook healthy
make doctor
```

### Webhooks return 404 Not Found
**Cause:** Wrong path, or Traefik not routing to webhook service
**Fix:**
```bash
# Check webhook path
curl -v http://localhost/webhook/triage

# Verify Traefik dynamic config
cat infra/traefik/dynamic/middlewares.yml
```

### Traefik dashboard not accessible
**Cause:** Base mode: dashboard on :8080 (not published). Prod: auth required.
**Fix:**
```bash
# Base mode: dashboard not published by design
# Prod mode: access https://traefik.yourdomain.com with basic auth
# Credentials from TRAEFIK_DASHBOARD_PASSWORD in .env
```

## Database & Queue

### PostgreSQL connection refused / too many connections
**Cause:** `max_connections` too low (default 100), or connection leak
**Fix:**
```bash
# Check current connections
docker exec nexusops_postgres psql -U nexusops -d nexusops -c "SELECT count(*) FROM pg_stat_activity;"

# Increase max_connections in compose.yaml (postgres command section):
# -c max_connections=200

docker compose -p nexusops up -d --force-recreate postgres
```

### Redis memory growing / OOM
**Cause:** `maxmemory-policy` not set, or workers not consuming queue
**Fix:**
```bash
# Verify policy
docker exec nexusops_redis redis-cli -a $REDIS_PASSWORD CONFIG GET maxmemory-policy
# Should be: noeviction

# Check queue depth
docker exec nexusops_redis redis-cli -a $REDIS_PASSWORD KEYS "bull:*" | wc -l

# Scale workers
make scale WORKERS=4
```

### Qdrant healthcheck fails
**Cause:** API key mismatch, or Qdrant not ready
**Fix:**
```bash
# Check API key matches
grep QDRANT_API_KEY .env
docker exec nexusops_qdrant env | grep QDRANT

# Test directly
curl -H "api-key: $QDRANT_API_KEY" http://localhost:6333/healthz
```

## Backups & Restore

### `make backup` fails
**Cause:** `BACKUP_AGE_RECIPIENT` not set, S3 creds invalid, disk full
**Fix:**
```bash
# Run manually for detailed error
docker compose -p nexusops -f compose.yaml run --rm backup /scripts/backup.sh

# Check disk space
df -h /var/lib/docker/volumes/nexusops_backups/_data

# Verify Age public key
grep BACKUP_AGE_RECIPIENT .env
```

### `make restore-test` fails
**Cause:** No backups exist, or restore environment issue
**Fix:**
```bash
# List backups
make backup-list

# Run restore test manually for logs
docker run --rm \
  --name nexusops-restore-test \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v nexusops_backups:/backup/data:ro \
  -v nexusops_n8n_data:/n8n/data:ro \
  -v nexusops_letsencrypt:/traefik:ro \
  -e BACKUP_DIR=/backup/data \
  -e BACKUP_AGE_RECIPIENT="$BACKUP_AGE_RECIPIENT" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -e REDIS_PASSWORD="$REDIS_PASSWORD" \
  -e QDRANT_API_KEY="$QDRANT_API_KEY" \
  -e N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY" \
  nexusops-backup:latest /scripts/restore-test.sh
```

### `make restore SNAPSHOT=...` fails
**Cause:** Snapshot name wrong, or age private key missing for decryption
**Fix:**
```bash
# List available snapshots
make backup-list

# Verify snapshot exists
docker run --rm -v nexusops_backups:/backup/data:ro alpine ls /backup/data/

# For decryption, need age private key (offline)
# Restore manually if needed:
age --decrypt -i /path/to/private-key.txt -o postgres.dump postgres.dump.age
```

## Approvals & Telegram

### Approval buttons don't work / callback fails
**Cause:** `N8N_PUBLIC_URL` not set, callback URL not routed, `DLQ_REPLAY_TOKEN` mismatch
**Fix:**
```bash
# Verify N8N_PUBLIC_URL in .env (must be https://n8n.yourdomain.com)
grep N8N_PUBLIC_URL .env

# Test callback URL manually
curl -X POST http://localhost/webhook/approval/callback/test-id/test-token \
  -H "Content-Type: application/json" \
  -d '{"callback_query":{"data":"approve:test-id:test-token","from":{"id":"123456789"}}}'

# Check DLQ_REPLAY_TOKEN matches
grep DLQ_REPLAY_TOKEN .env
```

### No Telegram alerts received
**Cause:** Bot token/chat ID wrong, bot not started, or chat ID not numeric
**Fix:**
```bash
# Test bot token
curl "https://api.telegram.org/bot$ALERT_TELEGRAM_BOT_TOKEN/getMe"

# Get chat ID (message bot first, then):
curl "https://api.telegram.org/bot$ALERT_TELEGRAM_BOT_TOKEN/getUpdates"

# Verify in .env
grep ALERT_TELEGRAM .env
```

### Approval escalation not working
**Cause:** `DEFAULT_APPROVER_SECONDARY` not set, or timeout not reached
**Fix:**
```bash
# Check both approvers set
grep DEFAULT_APPROVER .env

# For testing, set short timeout:
# ALERT_DEDUPE_WINDOW_MS=60000  # 1 min
# In request_approval workflow, timeout_minutes: 1
```

## LLM & Costs

### LLM budget alert not firing
**Cause:** `LLM_MONTHLY_BUDGET_USD=0` (disabled), or `budget_guard` workflow not active
**Fix:**
```bash
# Set budget
LLM_MONTHLY_BUDGET_USD=100.00

# Activate budget_guard workflow in n8n UI
# Or via bootstrap (should auto-activate)
```

### LLM costs showing $0.00
**Cause:** `log_llm_usage` not called, or pricing missing for model
**Fix:**
```bash
# Check pricing table
docker exec nexusops_postgres psql -U nexusops -d nexusops -c "SELECT * FROM ops.model_pricing;"

# Add missing pricing
docker exec -i nexusops_postgres psql -U nexusops -d nexusops <<'EOF'
INSERT INTO ops.model_pricing (provider, model, input_usd_per_1m, output_usd_per_1m, valid_from, source_url)
VALUES ('openai', 'gpt-4o', 5.00, 15.00, '2024-05-01', 'https://openai.com/pricing');
EOF
```

### `log_llm_usage` workflow fails
**Cause:** `ops_writer_credentials` not created, or Postgres schema missing
**Fix:**
```bash
# Check bootstrap logs
make logs SERVICE=n8n-bootstrap

# Verify credentials exist in n8n UI: Credentials → ops_writer_credentials
# Verify ops schema
docker exec nexusops_postgres psql -U nexusops -d nexusops -c "\dn+ ops"
```

## Demo & Mock Mode

### `make demo` fails / no output
**Cause:** Stack not running, or mock-llm not healthy
**Fix:**
```bash
# Ensure DEMO_MODE=mock and stack running
DEMO_MODE=mock make up

# Check mock-llm health
curl http://localhost:8080/health

# Run demo manually
bash scripts/demo.sh run
```

### Mock LLM always succeeds / never fails
**Cause:** `MOCK_FAILURE_RATE=0` or not set
**Fix:**
```bash
# Set failure rate (0.3 = 30%)
MOCK_FAILURE_RATE=0.3 make up
# Or in .env: MOCK_FAILURE_RATE=0.3
```

## Certificates & HTTPS

### Let's Encrypt certificate expired / not renewing
**Cause:** ACME challenge failing, or `acme.json` corrupted
**Fix:**
```bash
# Check Traefik logs for ACME errors
make logs SERVICE=traefik | grep -i acme

# Force renewal: delete acme.json and restart Traefik
docker compose -p nexusops stop traefik
docker run --rm -v nexusops_letsencrypt:/letsencrypt alpine rm /letsencrypt/acme.json
docker compose -p nexusops up -d traefik
```

### Browser shows "Not Secure" on production
**Cause:** Traefik not using Let's Encrypt, or HTTP not redirecting
**Fix:**
```bash
# Verify prod compose file used
COMPOSE_FILE=compose.yaml:compose.prod.yaml docker compose config | grep -A 5 "certificatesresolvers"

# Check HTTP→HTTPS redirect
curl -I http://n8n.yourdomain.com
# Should return 301/302 to https
```

## Performance

### High CPU / memory usage
**Cause:** Too many workers, large workflows, or memory leak
**Fix:**
```bash
# Check resource usage
docker stats --no-stream

# Reduce workers
make scale WORKERS=2

# Check n8n execution pruning (auto-prunes after 14 days / 10k executions)
grep EXECUTIONS_DATA_PRUNE .env
```

### Slow webhook response
**Cause:** Queue backed up, LLM latency, or cold start
**Fix:**
```bash
# Check queue depth
docker exec nexusops_redis redis-cli -a $REDIS_PASSWORD LLEN "bull:execution:waiting"

# Scale workers
make scale WORKERS=4

# Check LLM latency in logs
make logs SERVICE=n8n-worker | grep -i latency
```

## Debugging Commands Quick Reference

```bash
# Full health check
make doctor

# All logs
make logs

# Service-specific logs
make logs SERVICE=n8n-main
make logs SERVICE=traefik
make logs SERVICE=backup

# Container status
make ps

# Scale workers
make scale WORKERS=4

# Database queries
docker exec nexusops_postgres psql -U nexusops -d nexusops -c "SELECT * FROM ops.dead_letters WHERE status='pending';"
docker exec nexusops_postgres psql -U nexusops -d nexusops -c "SELECT * FROM ops.v_llm_cost_month_to_date;"
docker exec nexusops_postgres psql -U nexusops -d nexusops -c "SELECT * FROM ops.approvals WHERE status='pending';"

# Redis commands
docker exec nexusops_redis redis-cli -a $REDIS_PASSWORD INFO memory
docker exec nexusops_redis redis-cli -a $REDIS_PASSWORD KEYS "bull:*"

# Restart specific service
docker compose -p nexusops restart n8n-main

# Full restart
make down && make up
```

## Getting Help

If the above doesn't resolve your issue:

1. Run `make doctor` and capture full output
2. Collect relevant logs: `make logs SERVICE=<failing> > logs.txt`
3. Check [GitHub Issues](https://github.com/nexusops/nexusops/issues) for similar problems
4. Open a new issue with:
   - `make doctor` output
   - Relevant logs
   - Steps to reproduce
   - Environment (local/prod, Docker version, OS)

## Next Steps
- [Operations Guide](operations.md) — Day-2 procedures
- [FAQ](faq.md) — Common questions
- [Architecture](architecture.md) — System design