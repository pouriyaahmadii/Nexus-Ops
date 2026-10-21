-- AutoForge / NexusOps - Error handling schema
-- Idempotent: safe to run multiple times.
-- Creates ops.dead_letters table, indexes, view, and grants for ops_writer.

-- ============================================================================
-- Dead Letters Table
-- ============================================================================

CREATE TABLE IF NOT EXISTS ops.dead_letters (
    id              BIGSERIAL PRIMARY KEY,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    workflow_id     TEXT NOT NULL,
    workflow_name   TEXT NOT NULL,
    execution_id    TEXT NOT NULL,
    node_name       TEXT NOT NULL,
    error_message   TEXT NOT NULL,
    error_stack     TEXT,
    payload         JSONB NOT NULL DEFAULT '{}',
    attempts        INT NOT NULL DEFAULT 0,
    status          TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'replayed', 'discarded')),
    replayed_at     TIMESTAMPTZ,
    notes           TEXT
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_dead_letters_status_created
    ON ops.dead_letters (status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_dead_letters_workflow_execution
    ON ops.dead_letters (workflow_id, execution_id);

CREATE INDEX IF NOT EXISTS idx_dead_letters_created_at
    ON ops.dead_letters (created_at DESC);

-- ============================================================================
-- View: Error Summary (errors per workflow per day)
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_error_summary AS
SELECT
    workflow_id,
    workflow_name,
    DATE(created_at) AS error_date,
    COUNT(*) AS error_count,
    COUNT(*) FILTER (WHERE status = 'pending') AS pending_count,
    COUNT(*) FILTER (WHERE status = 'replayed') AS replayed_count,
    COUNT(*) FILTER (WHERE status = 'discarded') AS discarded_count,
    MAX(created_at) AS last_error_at
FROM ops.dead_letters
GROUP BY workflow_id, workflow_name, DATE(created_at)
ORDER BY error_date DESC, error_count DESC;

-- ============================================================================
-- Grants for ops_writer
-- ============================================================================

GRANT SELECT, INSERT, UPDATE ON ops.dead_letters TO ops_writer;
GRANT USAGE, SELECT ON SEQUENCE ops.dead_letters_id_seq TO ops_writer;
GRANT SELECT ON ops.v_error_summary TO ops_writer;

-- ============================================================================
-- Optional: Alert dedupe helper table (stores last alert timestamp per workflow)
-- ============================================================================

CREATE TABLE IF NOT EXISTS ops.alert_dedupe (
    workflow_id     TEXT PRIMARY KEY,
    last_alert_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    alert_count     INT NOT NULL DEFAULT 1
);

GRANT SELECT, INSERT, UPDATE ON ops.alert_dedupe TO ops_writer;