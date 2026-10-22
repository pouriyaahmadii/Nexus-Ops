# ADR 0007: Workflows as Code — Version-Controlled n8n Workflows

## Status
Accepted

## Date
2026-10-22

## Context
n8n workflows are typically created and edited in the UI, then exported as JSON. This creates a gap between the running configuration and version control. We want workflows to be:
- Version-controlled (Git)
- Reviewable in PRs
- Deployable via CI/CD
- Idempotently imported on bootstrap

## Decision
Store all workflows as JSON files in `workflows/` directory, organized by purpose:
- `workflows/core/` — Platform infrastructure (error handler, retry, DLQ, approval, healthcheck)
- `workflows/ops/` — Operational (LLM logging, budget guard, cost report)
- `workflows/approvals/` — Human-in-the-loop (request, policy check)
- `workflows/demo/` — Showcase and benchmark workflows

A one-shot `n8n-bootstrap` service imports all workflows on first deploy (idempotent by stable workflow `id`).

## Consequences

### Positive
- **Git history**: Every workflow change tracked, reviewable, revertible
- **CI/CD integration**: Linting (`check-workflows.sh`), validation in PR checks
- **Disaster recovery**: Fresh deploy restores all workflows from repo
- **Team collaboration**: Changes reviewed like code, no "who changed what in UI"
- **Environment promotion**: Same JSON files work in dev/staging/prod (environment-specific config via `.env`)

### Negative / Trade-offs
- **UI edits lost**: Changes made in n8n UI are not persisted back to repo automatically
- **Bootstrap dependency**: `n8n-bootstrap` must run after n8n is healthy
- **Credential handling**: Credentials NOT in JSON; created at bootstrap from `.env` via n8n API
- **Workflow IDs**: Must be stable (UUID v4 generated once, never changed) for idempotency

### Neutral
- `active: false` by default in JSON; bootstrap activates core workflows
- Webhook paths derived from `N8N_HOST`/`WEBHOOK_URL` env vars, not hardcoded
- `settings.executionOrder: v1` for consistent behavior

## Implementation
- `infra/n8n/bootstrap.sh`: Waits for n8n, creates credentials, imports workflows, activates core, sets global error handler
- `scripts/check-workflows.sh`: Validates JSON structure, no embedded secrets, stable IDs, unique names, valid connections
- CI job `n8n-workflows` runs validation on every PR

## Workflow JSON Requirements
```json
{
  "id": "stable-uuid-v4",           // Generated once, never change
  "name": "Descriptive Name",
  "active": false,                  // Bootstrap activates as needed
  "nodes": [...],
  "connections": {...},
  "settings": {"executionOrder": "v1"},
  "tags": ["core", "error-handling"]
}
```

## Credential Management
Credentials are **not** stored in workflow JSON. The bootstrap:
1. Creates `ops_writer_credentials` (Postgres) from `OPS_WRITER_PASSWORD`
2. Creates `telegram_credentials` from `ALERT_TELEGRAM_BOT_TOKEN` + `ALERT_TELEGRAM_CHAT_ID`
3. Workflows reference credentials by **name** (e.g., `postgres: "ops_writer_credentials"`)