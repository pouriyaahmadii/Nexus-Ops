-- AutoForge / NexusOps - Demo Outbox Table
-- Idempotent: safe to run multiple times.

CREATE TABLE IF NOT EXISTS ops.demo_outbox (
    id              BIGSERIAL PRIMARY KEY,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    correlation_id  TEXT NOT NULL,
    workflow_id     TEXT NOT NULL,
    execution_id    TEXT NOT NULL,
    action_type     TEXT NOT NULL,
    recipient       TEXT,
    subject         TEXT,
    body            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'sent', 'failed', 'manual_review')),
    metadata        JSONB NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_demo_outbox_correlation
    ON ops.demo_outbox (correlation_id);

CREATE INDEX IF NOT EXISTS idx_demo_outbox_status
    ON ops.demo_outbox (status, created_at DESC);

GRANT SELECT, INSERT, UPDATE ON ops.demo_outbox TO ops_writer;
GRANT USAGE, SELECT ON SEQUENCE ops.demo_outbox_id_seq TO ops_writer;