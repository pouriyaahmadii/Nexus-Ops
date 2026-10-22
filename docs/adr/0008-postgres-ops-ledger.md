# ADR 0008: PostgreSQL as Operational Ledger

## Status
Accepted

## Date
2026-10-22

## Context
The platform needs persistent storage for operational data: dead letters, LLM usage/costs, approval requests, audit events, and demo outbox. Options:
1. **PostgreSQL** — Already running for n8n, ACID, JSONB, mature tooling
2. **SQLite** — Embedded, but not suitable for concurrent access from multiple services
3. **Separate DB** — Adds operational complexity

## Decision
Use the **existing PostgreSQL instance** (already required by n8n) as the operational ledger under the `ops` schema, accessed via a least-privilege role `ops_writer`.

## Consequences

### Positive
- **Zero additional infrastructure**: Reuses n8n's PostgreSQL
- **ACID transactions**: Critical for DLQ, approvals, audit events
- **JSONB support**: Flexible payloads for error details, approval details, metadata
- **Mature tooling**: `psql`, `pg_dump`, `pg_restore`, `pg_isready` for healthchecks
- **Single backup**: `pg_dump` captures n8n + ops data together
- **Least privilege**: `ops_writer` role has only `INSERT/UPDATE/SELECT` on `ops.*` tables

### Negative / Trade-offs
- **Schema coupling**: Ops tables share DB with n8n (mitigated by schema isolation)
- **Resource contention**: Ops workload adds minimal load (mitigated by indexing, partitioning later if needed)
- **Single point of failure**: If Postgres down, all ops data unavailable (mitigated by backup/restore)

### Neutral
- `ops` schema created by `infra/postgres/init/20-ops-errors.sql` (idempotent)
- Tables: `dead_letters`, `alert_dedupe`, `llm_usage`, `model_pricing`, `approvals`, `approval_events`, `approval_policies`, `demo_outbox`
- Views: `v_error_summary`, `v_llm_cost_daily`, `v_llm_cost_by_workflow`, `v_llm_cost_month_to_date`, `v_pending_approvals`
- Grants: `ops_writer` has `SELECT/INSERT/UPDATE` on tables, `SELECT` on views, `USAGE` on sequences

## Implementation
- `infra/postgres/init/20-ops-errors.sql`: Schema, tables, indexes, view, grants
- `infra/postgres/init/30-ops-llm.sql`: LLM pricing, usage ledger, cost function, trigger, views
- `infra/postgres/init/40-ops-approvals.sql`: Approvals, events, policies, trigger
- `infra/postgres/init/50-ops-demo.sql`: Demo outbox table
- All init scripts run automatically on first Postgres startup (idempotent)

## Access Pattern
```python
# Services connect via ops_writer credentials
# Created by bootstrap from OPS_WRITER_PASSWORD
# Connection: postgresql://ops_writer:password@postgres:5432/nexusops
```

## Backup & Restore
- `pg_dump --format=custom` captures all schemas including `ops`
- Restore with `pg_restore --clean --if-exists`
- Point-in-time recovery via WAL archiving (future enhancement)