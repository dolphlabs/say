-- 014_resolution_and_settlement.sql
-- Prompt 08: Resolution, disputes, evidence, decisions, and settlement jobs.

-- 1. Ledger transaction kind constraint expansion
ALTER TABLE ledger_transactions DROP CONSTRAINT IF EXISTS ledger_transactions_kind_check;
ALTER TABLE ledger_transactions ADD CONSTRAINT ledger_transactions_kind_check
    CHECK (kind IN ('SEASON_GRANT', 'ORDER_HOLD', 'ORDER_RELEASE', 'FILL', 'FEE',
                    'MINT', 'MERGE', 'PAYOUT', 'BOT_FUNDING', 'ADJUSTMENT',
                    'VOID_REFUND', 'FEE_REFUND', 'VOID_COLLATERAL_RELEASE'));

-- 2. Extend market_resolutions
ALTER TABLE market_resolutions DROP CONSTRAINT IF EXISTS market_resolutions_status_check;
ALTER TABLE market_resolutions ALTER COLUMN status DROP NOT NULL;
ALTER TABLE market_resolutions ADD COLUMN IF NOT EXISTS state text NOT NULL DEFAULT 'COLLECTING'
    CHECK (state IN ('COLLECTING', 'PROPOSED', 'AWAITING_FINAL', 'HELD', 'FINAL'));
ALTER TABLE market_resolutions ADD COLUMN IF NOT EXISTS version int NOT NULL DEFAULT 1;
ALTER TABLE market_resolutions ADD COLUMN IF NOT EXISTS conflict boolean NOT NULL DEFAULT false;
ALTER TABLE market_resolutions ADD COLUMN IF NOT EXISTS overdue boolean NOT NULL DEFAULT false;
ALTER TABLE market_resolutions ADD COLUMN IF NOT EXISTS hold_reason text NOT NULL DEFAULT '';
ALTER TABLE market_resolutions ADD COLUMN IF NOT EXISTS reason text NOT NULL DEFAULT '';
ALTER TABLE market_resolutions ADD COLUMN IF NOT EXISTS current_proposal_id uuid;
ALTER TABLE market_resolutions ADD COLUMN IF NOT EXISTS final_decision_id uuid;
ALTER TABLE market_resolutions ADD COLUMN IF NOT EXISTS stage_label text NOT NULL DEFAULT 'Collecting results';
ALTER TABLE market_resolutions ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- 3. resolution_evidence (append-only)
CREATE TABLE IF NOT EXISTS resolution_evidence (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    market_id uuid NOT NULL REFERENCES markets(id) ON DELETE CASCADE,
    source_id text NOT NULL DEFAULT '',
    url text NOT NULL,
    retrieved_at timestamptz NOT NULL DEFAULT now(),
    http_status int NOT NULL DEFAULT 200,
    content_type text NOT NULL DEFAULT 'text/html',
    snapshot_ref text NOT NULL DEFAULT '',
    sha256 text NOT NULL,
    snapshot_data bytea,
    finding text NOT NULL,
    verdict text NOT NULL CHECK (verdict IN ('SAYS_YES', 'SAYS_NO', 'UNCLEAR')),
    collected_by text NOT NULL DEFAULT 'system',
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_resolution_evidence_market ON resolution_evidence(market_id, retrieved_at DESC);

-- 4. resolution_proposals (append-only)
CREATE TABLE IF NOT EXISTS resolution_proposals (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    market_id uuid NOT NULL REFERENCES markets(id) ON DELETE CASCADE,
    proposer_id uuid NOT NULL REFERENCES accounts(id),
    outcome text NOT NULL CHECK (outcome IN ('YES', 'NO')),
    reason text NOT NULL,
    evidence_ids text[] NOT NULL DEFAULT '{}',
    proposed_at timestamptz NOT NULL DEFAULT now(),
    dispute_until timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_resolution_proposals_market ON resolution_proposals(market_id, proposed_at DESC);

-- 5. resolution_disputes (append-only submissions, decisions recorded by admin)
CREATE TABLE IF NOT EXISTS resolution_disputes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    market_id uuid NOT NULL REFERENCES markets(id) ON DELETE CASCADE,
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    proposal_id uuid REFERENCES resolution_proposals(id),
    holdings_proof text NOT NULL DEFAULT '',
    reason text NOT NULL,
    link_url text NOT NULL DEFAULT '',
    decision text CHECK (decision IN ('ACCEPT', 'REJECT')),
    decision_note text NOT NULL DEFAULT '',
    decided_by uuid REFERENCES accounts(id),
    decided_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_resolution_disputes_market_account UNIQUE (market_id, account_id)
);
CREATE INDEX IF NOT EXISTS idx_resolution_disputes_market ON resolution_disputes(market_id, created_at ASC);

-- 6. resolution_decisions (append-only)
CREATE TABLE IF NOT EXISTS resolution_decisions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    market_id uuid NOT NULL REFERENCES markets(id) ON DELETE CASCADE,
    season_id uuid NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
    outcome text NOT NULL CHECK (outcome IN ('YES', 'NO', 'VOID')),
    void_reason text CHECK (void_reason IS NULL OR void_reason IN ('POSTPONED', 'ABANDONED', 'AMBIGUOUS', 'SOURCE_UNAVAILABLE', 'OTHER')),
    reason text NOT NULL,
    proposer_id uuid REFERENCES accounts(id),
    finalizer_id uuid NOT NULL REFERENCES accounts(id),
    proposal_id uuid REFERENCES resolution_proposals(id),
    decided_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_resolution_decisions_market UNIQUE (market_id)
);

-- 7. settlement_jobs (resumable settlement execution)
CREATE TABLE IF NOT EXISTS settlement_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    market_id uuid NOT NULL REFERENCES markets(id) ON DELETE CASCADE,
    decision_id uuid NOT NULL REFERENCES resolution_decisions(id) ON DELETE CASCADE,
    state text NOT NULL DEFAULT 'PREPARING'
        CHECK (state IN ('PREPARING', 'WAITING_CLOSE', 'WAITING_APPROVAL', 'RUNNING', 'VERIFYING', 'DONE', 'INVARIANT_FAILED')),
    cursor int NOT NULL DEFAULT 0,
    batch_size int NOT NULL DEFAULT 500,
    done boolean NOT NULL DEFAULT false,
    winners_count int NOT NULL DEFAULT 0,
    payout_total bigint NOT NULL DEFAULT 0,
    refunds_total bigint NOT NULL DEFAULT 0,
    fee_refunds_total bigint NOT NULL DEFAULT 0,
    collateral_released bigint NOT NULL DEFAULT 0,
    treasury_delta bigint NOT NULL DEFAULT 0,
    shortfall bigint NOT NULL DEFAULT 0,
    error_message text,
    started_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_settlement_jobs_market UNIQUE (market_id)
);
CREATE INDEX IF NOT EXISTS idx_settlement_jobs_state ON settlement_jobs(state);

-- 8. Append-only triggers for evidence, proposals, and decisions
CREATE OR REPLACE FUNCTION deny_update_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'TABLE_IS_APPEND_ONLY';
END;
$$;

DROP TRIGGER IF EXISTS trg_evidence_append_only ON resolution_evidence;
CREATE TRIGGER trg_evidence_append_only BEFORE UPDATE OR DELETE ON resolution_evidence
    FOR EACH ROW EXECUTE FUNCTION deny_update_delete();

DROP TRIGGER IF EXISTS trg_proposals_append_only ON resolution_proposals;
CREATE TRIGGER trg_proposals_append_only BEFORE UPDATE OR DELETE ON resolution_proposals
    FOR EACH ROW EXECUTE FUNCTION deny_update_delete();

DROP TRIGGER IF EXISTS trg_decisions_append_only ON resolution_decisions;
CREATE TRIGGER trg_decisions_append_only BEFORE UPDATE OR DELETE ON resolution_decisions
    FOR EACH ROW EXECUTE FUNCTION deny_update_delete();

-- 9. Role permissions
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'say_app') THEN
        REVOKE UPDATE, DELETE, TRUNCATE ON resolution_evidence, resolution_proposals, resolution_decisions FROM say_app;
        GRANT SELECT, INSERT ON resolution_evidence, resolution_proposals, resolution_decisions TO say_app;
        GRANT SELECT, INSERT, UPDATE ON market_resolutions, resolution_disputes, settlement_jobs TO say_app;
    END IF;
END $$;
