# NexusOps FAQ

## General

### What is NexusOps?
NexusOps is a production-grade, self-hosted automation platform built on n8n (queue mode), Traefik, PostgreSQL, Redis, and Qdrant. It provides encrypted backups, LLM cost tracking, human-in-the-loop approvals, and comprehensive observability — all deployable with `make up`.

### Who is this for?
- DevOps engineers wanting a self-hosted n8n with production hardening
- Teams needing LLM cost visibility and budget enforcement
- Projects requiring human approval gates for sensitive automations
- Anyone wanting a reference architecture for Docker Compose platforms

### What's the license?
MIT License — see [LICENSE](../LICENSE).

### Is this a fork of n8n?
No. NexusOps is a **deployment and operational wrapper** around upstream n8n (using the official `n8nio/n8n:stable` image). It adds infrastructure, operational tooling, and platform-level workflows.

## Architecture

### Why queue mode instead of standard n8n?
Queue mode separates concerns:
- **Main**: UI, API, schedules — stays responsive
- **Webhook**: Dedicated processor for incoming webhooks — never blocked by executions
- **Workers**: Horizontally scalable execution pool — handles load spikes

Standard mode runs everything in one process; a burst of webhooks or long executions makes the UI unusable.

### Why Traefik instead of Nginx/Caddy?
- Native Docker provider (label-based routing, `exposedByDefault=false`)
- Built-in Let's Encrypt (HTTP challenge, zero-config renewal)
- Dynamic middleware pipeline (security headers, rate limit, auth)
- Prometheus metrics + dashboard for debugging

### Why PostgreSQL for everything?
- n8n requires Postgres
- Operational data (DLQ, LLM ledger, approvals) needs ACID + JSONB
- Single backup captures n8n + ops data
- `ops_writer` role enforces least privilege

### Why Redis for queue?
- n8n's Bull queue requires Redis
- `maxmemory-policy noeviction` prevents silent job loss under pressure
- Shared by all n8n roles (main, webhook, workers)

### Why Qdrant?
Vector database for RAG (Retrieval-Augmented Generation) in AI workflows. API key protected, opt-in exposure.

## Operations

### How do I scale workers?
```bash
make scale WORKERS=4
```
This runs `docker compose up -d --scale n8n-worker=4 --no-recreate`. No downtime for UI.

### How do I trigger a backup?
```bash
make backup
```
Runs the backup service one-off. Scheduled backups run daily at 03:00 UTC via `BACKUP_CRON`.

### How do I restore from backup?
```bash
make backup-list          # Find snapshot name
make restore SNAPSHOT=nexusops-20261022T030000Z
```

### How do I run the restore drill?
```bash
make restore-test
```
Spins up isolated throwaway stack, restores latest backup, verifies Postgres row counts, Qdrant collections, n8n workflows.

### How do I add a new workflow?
1. Create JSON in `workflows/<category>/my-workflow.json` with stable UUID `id`
2. Commit and push
3. CI validates (`check-workflows.sh`)
4. On deploy, `n8n-bootstrap` imports it (idempotent by `id`)

### How do I update n8n version?
Edit `image: "n8nio/n8n:stable"` in `compose.yaml` and `compose.prod.yaml` to a specific tag (e.g., `n8nio/n8n:1.45.0`), then `make upgrade`.

### How do I enable the monitoring stack?
```bash
COMPOSE_FILE=compose.yaml:compose.monitoring.yaml make up
```
- Uptime Kuma: `http://localhost:3001`
- Grafana: `http://localhost:3000` (admin / `GRAFANA_ADMIN_PASSWORD`)
- Prometheus: `http://localhost:9090`

## Security

### Are secrets in the repo?
No. `.env` is gitignored. `.env.example` has only placeholders. CI runs `gitleaks` on full history.

### How are backups encrypted?
Each artifact (Postgres dump, Qdrant snapshots, n8n data tar, acme.json, manifest) is encrypted with `age` using `BACKUP_AGE_RECIPIENT` (public key). Private key **never on server**.

### How does the approval system work?
1. Workflow calls `request_approval` → inserts row in `ops.approvals`
2. Telegram bot sends message with inline ✅/❌ buttons (signed callback token)
3. Approver clicks → callback webhook validates token, authorization, single-decision
4. On timeout → escalates to secondary approver → then expires (safe default: reject)

### How is the Docker socket protected?
Traefik talks to `docker-socket-proxy` (read-only: CONTAINERS, IMAGES, EVENTS, VERSION only). No direct `/var/run/docker.sock` mount.

### How do I rotate secrets?
See [Operations Guide](operations.md#secret-rotation) for PostgreSQL, Redis, Qdrant, n8n encryption key, Age key, Traefik dashboard.

## LLM & Costs

### How does cost tracking work?
1. After LLM call, workflow calls `log_llm_usage` (normalizes OpenAI/Anthropic/Gemini usage)
2. Trigger auto-computes cost via `ops.fn_compute_llm_cost()` using `ops.model_pricing` valid at `created_at`
3. `budget_guard` runs hourly: compares MTD spend vs `LLM_MONTHLY_BUDGET_USD`
4. At 80% → warning, 100% → critical + optional enforcement (deactivates `llm-guarded` workflows)

### Do I need real API keys for the demo?
No. `DEMO_MODE=mock` uses `mock-llm` service (deterministic, injects 30% failures for retry demo). Set `OPENAI_API_KEY` and `DEMO_MODE=live` for real calls.

### Where do I update model pricing?
```sql
-- Connect to Postgres
INSERT INTO ops.model_pricing (provider, model, input_usd_per_1m, output_usd_per_1m, valid_from, source_url)
VALUES ('openai', 'gpt-4o', 5.00, 15.00, '2024-05-01', 'https://openai.com/pricing');
```
Pricing rows have `valid_from`/`valid_to` for mid-month price changes.

## Troubleshooting Quick Links

| Symptom | Guide |
|---------|-------|
| n8n not starting | [Troubleshooting](troubleshooting.md#n8n-not-starting) |
| Webhooks 502 | [Troubleshooting](troubleshooting.md#webhooks-return-502) |
| Backup fails | [Troubleshooting](troubleshooting.md#backup-fails) |
| Approval buttons don't work | [Troubleshooting](troubleshooting.md#approval-buttons-dont-work) |
| High LLM costs | [Troubleshooting](troubleshooting.md#llm-budget-exceeded) |

## Still Have Questions?
- Check [Operations Guide](operations.md)
- Search [GitHub Issues](https://github.com/nexusops/nexusops/issues)
- Open a new issue with `make doctor` output and relevant logs