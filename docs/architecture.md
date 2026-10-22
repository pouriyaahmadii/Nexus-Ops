# NexusOps Architecture

## System Context

```mermaid
C4Context
    title System Context Diagram

    Person(user, "Operator / User", "Manages workflows, monitors costs, approves actions")
    System(nexusops, "NexusOps", "Self-hosted automation platform (n8n + Traefik + Postgres + Redis + Qdrant)")
    System_Ext(telegram, "Telegram", "Approval notifications & alerts")
    System_Ext(llm, "LLM Providers", "OpenAI / Anthropic / Google / Local")
    System_Ext(s3, "S3 Storage", "Offsite backup destination (optional)")
    System_Ext(dns, "DNS / Hosts", "Routes *.localhost to local stack")

    Rel(user, nexusops, "Manages via n8n UI / Webhooks")
    Rel(nexusops, telegram, "Sends approval requests & cost alerts")
    Rel(nexusops, llm, "Calls LLM APIs for AI workflows")
    Rel(nexusops, s3, "Pushes encrypted backups")
    Rel(dns, nexusops, "Resolves n8n.localhost, traefik.localhost")
```

## Container Diagram

```mermaid
C4Container
    title Container Diagram

    Container_Boundary(c0, "NexusOps Stack") {
        Container(traefik, "Traefik v3", "Reverse Proxy", "Entry point, TLS termination, routing, security headers, rate limiting")
        Container(n8n_main, "n8n Main", "Workflow Engine", "UI, REST API, schedules, webhook receiver (non-webhook routes)")
        Container(n8n_webhook, "n8n Webhook", "Webhook Processor", "Dedicated /webhook*, /webhook-test*, /response*, /form* handler")
        Container(n8n_worker, "n8n Worker", "Execution Workers", "Scalable pool (default 2), picks up queued executions from Redis")
        Container(redis, "Redis 7", "Queue Broker", "Bull queue for n8n executions, maxmemory-policy noeviction")
        Container(postgres, "PostgreSQL 16", "Primary DB", "n8n data + ops schema (dead letters, LLM ledger, approvals, audit)")
        Container(qdrant, "Qdrant", "Vector DB", "RAG knowledge base for AI workflows, API key protected")
        Container(backup, "Backup Service", "Encrypted Backup", "pg_dump, Qdrant snapshots, age encryption, restic/S3 sync, cron")
        Container(mock_llm, "Mock LLM", "Test Double", "Deterministic OpenAI-compatible API, injects failures (demo profile)")
        Container(socket_proxy, "Socket Proxy", "Docker Socket Proxy", "Least-privilege Docker API for Traefik (read-only containers/events)")
    }

    Container_Ext(telegram, "Telegram Bot API", "Notifications & approval callbacks")
    Container_Ext(llm, "LLM Providers", "OpenAI / Anthropic / Google / Local")
    Container_Ext(s3, "S3-Compatible", "Offsite Backup Storage")

    Rel(traefik, n8n_main, "Routes UI/API (Host: n8n.${DOMAIN})")
    Rel(traefik, n8n_webhook, "Routes /webhook*, /webhook-test*, /response*, /form*")
    Rel(traefik, qdrant, "Routes qdrant.${DOMAIN} (prod, opt-in)")
    Rel(n8n_main, redis, "Enqueues executions (Bull)")
    Rel(n8n_webhook, redis, "Enqueues executions (Bull)")
    Rel(n8n_worker, redis, "Dequeues executions (Bull)")
    Rel(n8n_main, postgres, "n8n data + ops schema (ops_writer)")
    Rel(n8n_webhook, postgres, "n8n data + ops schema (ops_writer)")
    Rel(n8n_worker, postgres, "n8n data + ops schema (ops_writer)")
    Rel(backup, postgres, "pg_dump (custom format)")
    Rel(backup, qdrant, "API snapshots per collection")
    Rel(backup, redis, "n8n data volume + acme.json")
    Rel(mock_llm, n8n_worker, "OpenAI-compatible /v1/chat/completions (demo profile)")
    Rel(socket_proxy, traefik, "Read-only Docker API (containers, events, images)")
    Rel(n8n_worker, llm, "Calls LLM APIs (with retry/backoff)")
    Rel(n8n_main, telegram, "Sends approval requests & alerts")
    Rel(n8n_main, qdrant, "RAG queries (kb_demo collection)")
    Rel(backup, s3, "restic push (encrypted artifacts)")
```

## Network Segmentation

| Network | Purpose | Services | External Access |
|---------|---------|----------|-----------------|
| `edge` | Public ingress | Traefik | Port 80 (HTTP), 443 (HTTPS) |
| `app` | Application layer | Traefik, n8n-main, n8n-webhook, n8n-worker, Mock LLM, Socket Proxy | Internal only |
| `data` | Data layer (internal) | PostgreSQL, Redis, Qdrant, Backup | **Internal only** (`internal: true`) |

**Network Rules:**
- Only `edge` publishes ports to host (80, 443)
- `data` network is `internal: true` — no host access to Postgres, Redis, Qdrant
- Traefik spans `edge` + `app` to route ingress to app services
- n8n services span `app` + `data` to reach queue and database
- Backup only on `data` network (accesses Postgres, Redis, Qdrant volumes)

## Data Flows

### 1. Inbound Webhook → Execution → Response
```mermaid
sequenceDiagram
    participant Client
    participant Traefik
    participant n8n_Webhook
    participant Redis
    participant n8n_Worker
    participant Postgres
    participant LLM

    Client->>Traefik: POST /webhook/triage
    Traefik->>n8n_Webhook: Route (webhook path)
    n8n_Webhook->>Redis: Enqueue execution (Bull)
    n8n_Worker->>Redis: Dequeue execution
    n8n_Worker->>Postgres: Read workflow + credentials
    n8n_Worker->>LLM: Classify intent (with retry/backoff)
    LLM-->>n8n_Worker: Classification + reply
    n8n_Worker->>Postgres: Log LLM usage (cost ledger)
    alt High risk (amount > $100)
        n8n_Worker->>Postgres: Insert approval request
        n8n_Worker->>Telegram: Send approval buttons
        Telegram-->>Approver: ✅/❌
        Approver->>Traefik: Callback /webhook/approval/callback/...
        Traefik->>n8n_Main: Callback webhook
        n8n_Main->>Postgres: Update approval status
    end
    n8n_Worker->>Postgres: Write to demo_outbox (sent/manual_review)
    n8n_Webhook-->>Client: Response (intent, risk, approval_status, cost)
```

### 2. Scheduled Backup → Encrypt → Store → Retain
```mermaid
sequenceDiagram
    participant Cron
    participant Backup
    participant Postgres
    participant Qdrant
    participant Age
    participant LocalFS
    participant S3

    Cron->>Backup: Trigger (03:00 UTC daily)
    Backup->>Postgres: pg_dump --format=custom
    Backup->>Qdrant: Create snapshots per collection
    Backup->>LocalFS: Tar n8n data + acme.json
    Backup->>Backup: Generate manifest.json (checksums, versions)
    Backup->>Age: Encrypt each artifact (public key)
    Age-->>LocalFS: Write *.age files
    Backup->>LocalFS: Prune old (daily 7, weekly 4, monthly 6)
    alt S3 enabled
        Backup->>S3: restic backup (dedup, encrypted repo)
    end
    Backup->>Telegram: Success notification
    Backup->>Heartbeat: Ping healthchecks.io
```

### 3. Error Handling → DLQ → Alert
```mermaid
sequenceDiagram
    participant n8n_Worker
    participant ErrorTrigger
    participant Postgres
    participant Telegram

    n8n_Worker->>ErrorTrigger: Unhandled error
    ErrorTrigger->>Postgres: INSERT INTO ops.dead_letters
    ErrorTrigger->>Postgres: UPSERT ops.alert_dedupe
    alt First error in dedupe window (5 min)
        ErrorTrigger->>Telegram: Alert with execution URL
    else Duplicate
        ErrorTrigger-->>Telegram: Suppressed
    end
```

## Failure Modes & Recovery

| Failure | Detection | Recovery |
|---------|-----------|----------|
| n8n Main down | `make doctor` FAIL, Traefik 502 | `docker compose restart n8n-main` |
| n8n Webhook down | Webhooks return 502 | `docker compose restart n8n-webhook` |
| Worker pool exhausted | Queue depth grows, `make doctor` WARN | `make scale WORKERS=N` |
| Redis OOM | `maxmemory-policy noeviction` prevents silent drop | `make doctor` shows Redis memory; scale workers |
| Postgres connections exhausted | `pg_isready` fails, n8n errors | Increase `max_connections` in compose |
| Qdrant disk full | Healthcheck fails, snapshots fail | Delete old snapshots/collections |
| Backup fails | `make backup` exits non-zero, Telegram alert | Check logs, disk space, S3 creds |
| Certificate expired | Browser warning, `make doctor` FAIL | Delete `acme.json`, restart Traefik |
| n8n encryption key lost | Cannot decrypt credentials | **Restore from backup** (key in n8n data volume) |
| Approval callback fails | Callback returns 4xx/5xx | Check `DLQ_REPLAY_TOKEN`, `N8N_PUBLIC_URL` |

## Component Versions (Pinned)

| Component | Version | Source |
|-----------|---------|--------|
| Traefik | v3.4 | `traefik:v3.4` |
| n8n | stable | `n8nio/n8n:stable` |
| PostgreSQL | 16 | `postgres:16` |
| Redis | 7 | `redis:7` |
| Qdrant | v1.19.2 | `qdrant/qdrant:v1.19.2` |
| Backup (Alpine) | 3.21 | `alpine:3.21` |
| Mock LLM | Python 3.12 | `python:3.12-alpine` |
| Socket Proxy | latest | `tecnativa/docker-socket-proxy:latest` |
| Uptime Kuma | 1.23.16 | `louislam/uptime-kuma:1.23.16` |
| Prometheus | v2.55.1 | `prom/prometheus:v2.55.1` |
| Grafana | 11.1.4 | `grafana/grafana:11.1.4` |

## Security Boundaries

| Boundary | Controls |
|----------|----------|
| Network | `data` network internal; only Traefik publishes ports |
| Container | `no-new-privileges`, `cap_drop: [ALL]`, non-root (UID 1000), read-only rootfs where possible |
| Secrets | `.env` (600), Docker secrets for Postgres/Redis, Age public key only, n8n encryption key in `.env` |
| Traefik | `exposedByDefault=false`, basic auth on dashboard, security headers middleware, TLS 1.2+ |
| Qdrant | API key required, not exposed by default (opt-in via label) |
| Docker Socket | Socket proxy with minimal permissions (CONTAINERS, IMAGES, EVENTS, VERSION only) |

## Next Steps
- [Deployment Guide](deployment.md) — Server sizing, DNS, firewall, first deploy
- [Operations Guide](operations.md) — Day-2 operations, scaling, secret rotation
- [Backup & Restore](backup-restore.md) — RPO/RTO, disaster recovery