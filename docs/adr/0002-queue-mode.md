# ADR 0002: Adopt n8n queue mode with separate main, webhook and workers

## Status
Accepted

## Date
2026-10-22

## Context
The core stack (Phase 2) ran n8n as a single container handling the UI, REST API,
webhooks and workflow executions together. As automation load grows, a burst of
webhooks saturates the main process, making the editor unusable and delaying
long-running executions. n8n offers a queue mode that splits concerns across
instances sharing PostgreSQL and a Redis-backed Bull queue.

## Decision
Run n8n in queue mode (`EXECUTIONS_MODE=queue`) with three roles:
- `n8n-main`: UI, REST API, schedules; handles all routes except webhooks.
- `n8n-webhook`: dedicated processor for `/webhook`, `/webhook-test`, `/response`,
  `/form`, `/form-waiting`.
- `n8n-worker`: picks up queued executions from Redis; scaled via `WORKER_REPLICAS`
  (default 2).

All roles share the same Postgres database, Redis (Bull queue via
`QUEUE_BULL_REDIS_*`), and `N8N_ENCRYPTION_KEY`. `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true`
so manual executions also run on workers. Binary data mode is set to `database`
because n8n queue mode does not support filesystem binary storage.

Traefik routes:
- `Host(n8n.localhost)` (priority 10) → n8n-main (UI/API)
- `Host(n8n.localhost) && PathPrefix(/webhook|/webhook-test|/response|/form|/form-waiting)`
  (priority 20) → n8n-webhook

Verified against official n8n docs (docs.n8n.io "Enable queue mode" and "Queue mode"
environment variables): main runs `n8nio/n8n`, workers run `n8nio/n8n worker`,
webhook processors run `n8nio/n8n webhook`; all need `EXECUTIONS_MODE=queue`,
Redis + Postgres access and the same encryption key. Routing of `/webhook/*` to a
dedicated webhook processor follows the community reference compose pattern.

## Consequences
- Positive: webhooks keep answering while main restarts; workers scale horizontally
  with `make scale WORKERS=N` (no UI downtime); failed executions are isolated per worker.
- Negative / trade-offs: more containers to operate; shared `n8n_data` volume must be
  accessible to all roles (same volume); binary data stored in Postgres increases DB
  size; queue mode adds Redis dependency for all execution flow.
- Neutral: healthchecks added per role (`/healthz`); graceful shutdown timeout
  (`N8N_GRACEFUL_SHUTDOWN_TIMEOUT`) lets workers finish jobs before stopping.
