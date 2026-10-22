-- AutoForge / NexusOps - Human-in-the-loop Approvals
-- Idempotent: safe to run multiple times.

-- ============================================================================
-- Approvals Table
-- ============================================================================

CREATE TABLE IF NOT EXISTS ops.approvals (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    workflow_id         TEXT NOT NULL,
    workflow_name       TEXT NOT NULL,
    execution_id        TEXT NOT NULL,
    action_type         TEXT NOT NULL,
    summary             TEXT NOT NULL,
    details             JSONB NOT NULL DEFAULT '{}',
    risk_level          TEXT NOT NULL DEFAULT 'medium'
        CHECK (risk_level IN ('low', 'medium', 'high')),
    requested_by        TEXT NOT NULL,
    approver_primary    TEXT NOT NULL,
    approver_secondary  TEXT,
    status              TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'rejected', 'expired', 'escalated')),
    decided_by          TEXT,
    decided_at          TIMESTAMPTZ,
    decision_reason     TEXT,
    expires_at          TIMESTAMPTZ NOT NULL,
    escalated_at        TIMESTAMPTZ,
    resume_url          TEXT,
    callback_token      TEXT NOT NULL,
    callback_expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_approvals_status_created
    ON ops.approvals (status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_approvals_workflow_execution
    ON ops.approvals (workflow_id, execution_id);

CREATE INDEX IF NOT EXISTS idx_approvals_approver_status
    ON ops.approvals (approver_primary, status);

CREATE INDEX IF NOT EXISTS idx_approvals_callback_token
    ON ops.approvals (callback_token) WHERE callback_token IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_approvals_expires_at
    ON ops.approvals (expires_at) WHERE status = 'pending';

-- ============================================================================
-- Approval Events (Audit Trail)
-- ============================================================================

CREATE TABLE IF NOT EXISTS ops.approval_events (
    id              BIGSERIAL PRIMARY KEY,
    approval_id     UUID NOT NULL REFERENCES ops.approvals(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    actor           TEXT NOT NULL,
    from_status     TEXT,
    to_status       TEXT NOT NULL,
    reason          TEXT,
    metadata        JSONB NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_approval_events_approval
    ON ops.approval_events (approval_id, created_at);

GRANT SELECT, INSERT, UPDATE ON ops.approvals TO ops_writer;
GRANT USAGE, SELECT ON SEQUENCE ops.approval_events_id_seq TO ops_writer;
GRANT SELECT, INSERT ON ops.approval_events TO ops_writer;

-- ============================================================================
-- View: Pending Approvals
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_pending_approvals AS
SELECT
    id,
    created_at,
    workflow_id,
    workflow_name,
    execution_id,
    action_type,
    summary,
    risk_level,
    requested_by,
    approver_primary,
    approver_secondary,
    expires_at,
    EXTRACT(EPOCH FROM (expires_at - NOW()))::BIGINT AS seconds_remaining
FROM ops.approvals
WHERE status IN ('pending', 'escalated')
ORDER BY created_at ASC;

GRANT SELECT ON ops.v_pending_approvals TO ops_writer;

-- ============================================================================
-- Trigger Function for Audit Events
-- ============================================================================

CREATE OR REPLACE FUNCTION ops.trg_approval_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO ops.approval_events (approval_id, actor, from_status, to_status, reason, metadata)
        VALUES (NEW.id, NEW.requested_by, NULL, NEW.status, 'Approval requested', jsonb_build_object('action_type', NEW.action_type));
    ELSIF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO ops.approval_events (approval_id, actor, from_status, to_status, reason, metadata)
        VALUES (NEW.id, COALESCE(NEW.decided_by, 'system'), OLD.status, NEW.status, COALESCE(NEW.decision_reason, ''), jsonb_build_object('escalated', NEW.escalated_at IS NOT NULL));
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_approval_audit ON ops.approvals;
CREATE TRIGGER trg_approval_audit
    AFTER INSERT OR UPDATE ON ops.approvals
    FOR EACH ROW
    EXECUTE FUNCTION ops.trg_approval_audit();

-- ============================================================================
-- Policy Configuration Table
-- ============================================================================

CREATE TABLE IF NOT EXISTS ops.approval_policies (
    id                  BIGSERIAL PRIMARY KEY,
    action_type         TEXT NOT NULL,
    risk_level          TEXT NOT NULL DEFAULT 'medium'
        CHECK (risk_level IN ('low', 'medium', 'high')),
    condition_json      JSONB NOT NULL DEFAULT '{}',
    requires_approval   BOOLEAN NOT NULL DEFAULT TRUE,
    default_timeout_min INT NOT NULL DEFAULT 30,
    escalation_timeout_min INT NOT NULL DEFAULT 15,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (action_type, risk_level)
);

INSERT INTO ops.approval_policies (action_type, risk_level, condition_json, requires_approval, default_timeout_min, escalation_timeout_min) VALUES
('send_bulk_email', 'low',    '{"recipients_gt": 100}',  true,  30, 15),
('send_bulk_email', 'medium', '{"recipients_gt": 1000}', true,  60, 30),
('send_bulk_email', 'high',   '{"recipients_gt": 10000}', true, 120, 60),
('delete_data',     'low',    '{"rows_gt": 10}',         true,  30, 15),
('delete_data',     'medium', '{"rows_gt": 100}',        true,  60, 30),
('delete_data',     'high',   '{"rows_gt": 1000}',       true, 120, 60),
('spend_money',     'low',    '{"amount_usd_gt": 10}',   true,  30, 15),
('spend_money',     'medium', '{"amount_usd_gt": 100}',  true,  60, 30),
('spend_money',     'high',   '{"amount_usd_gt": 1000}', true, 120, 60),
('external_api',    'low',    '{}',                      false, 30, 15),
('external_api',    'medium', '{"writes": true}',        true,  30, 15),
('external_api',    'high',   '{"writes": true, "critical": true}', true, 60, 30),
('deploy',          'high',   '{}',                      true, 120, 60)
ON CONFLICT (action_type, risk_level) DO NOTHING;

GRANT SELECT ON ops.approval_policies TO ops_writer;