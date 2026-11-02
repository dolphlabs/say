-- 016_governance_and_standings.sql
-- Standings, profiles, username reservation, 2FA, approvals and audit log

-- 1. Accounts: leaderboard eligibility
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS leaderboard_eligible boolean NOT NULL DEFAULT true;

-- 2. Username history and reservations
CREATE TABLE IF NOT EXISTS username_history (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES accounts(id),
    old_username text NOT NULL,
    new_username text NOT NULL,
    season_id uuid,
    changed_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_username_history_account ON username_history(account_id);
CREATE INDEX IF NOT EXISTS idx_username_history_old ON username_history(lower(old_username));

CREATE TABLE IF NOT EXISTS username_reservations (
    username text PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES accounts(id),
    reserved_until timestamptz NOT NULL,
    created_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_username_reservations_until ON username_reservations(reserved_until);

-- 3. Email change pending flows
CREATE TABLE IF NOT EXISTS email_changes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES accounts(id),
    new_email citext NOT NULL,
    change_token_hash bytea NOT NULL UNIQUE,
    code_hash bytea NOT NULL,
    attempts integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL,
    resend_available_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_email_changes_account ON email_changes(account_id);

-- 4. TOTP 2FA
CREATE TABLE IF NOT EXISTS account_totp (
    account_id uuid PRIMARY KEY REFERENCES accounts(id),
    secret_encrypted text NOT NULL,
    enrolled_at timestamptz NOT NULL,
    last_verified_step bigint NOT NULL DEFAULT 0,
    last_verified_at timestamptz
);

CREATE TABLE IF NOT EXISTS pending_totp (
    account_id uuid PRIMARY KEY REFERENCES accounts(id),
    secret_encrypted text NOT NULL,
    created_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS session_totp_proofs (
    session_id text PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES accounts(id),
    verified_at timestamptz NOT NULL
);

-- 5. Season Standings & Final Standings
CREATE TABLE IF NOT EXISTS season_standings (
    season_id uuid NOT NULL REFERENCES seasons(id),
    account_id uuid NOT NULL REFERENCES accounts(id),
    profit bigint NOT NULL DEFAULT 0,
    calls integer NOT NULL DEFAULT 0,
    wins integer NOT NULL DEFAULT 0,
    losses integer NOT NULL DEFAULT 0,
    profit_reached_at timestamptz NOT NULL,
    rank_profit integer NOT NULL,
    rank_win integer,
    rank_calls integer NOT NULL,
    computed_at timestamptz NOT NULL,
    PRIMARY KEY (season_id, account_id)
);
CREATE INDEX IF NOT EXISTS idx_season_standings_profit ON season_standings(season_id, profit DESC, profit_reached_at ASC);
CREATE INDEX IF NOT EXISTS idx_season_standings_win ON season_standings(season_id, rank_win) WHERE rank_win IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_season_standings_calls ON season_standings(season_id, rank_calls);

CREATE TABLE IF NOT EXISTS season_final_standings (
    season_id uuid NOT NULL REFERENCES seasons(id),
    account_id uuid NOT NULL REFERENCES accounts(id),
    username_at_time text NOT NULL,
    profit bigint NOT NULL,
    calls integer NOT NULL,
    wins integer NOT NULL,
    losses integer NOT NULL,
    profit_reached_at timestamptz NOT NULL,
    rank_profit integer NOT NULL,
    rank_win integer,
    rank_calls integer NOT NULL,
    frozen_at timestamptz NOT NULL,
    PRIMARY KEY (season_id, account_id)
);
CREATE INDEX IF NOT EXISTS idx_season_final_standings_profit ON season_final_standings(season_id, rank_profit);

-- 6. Audit events enhancements
ALTER TABLE audit_events ADD COLUMN IF NOT EXISTS actor_kind text NOT NULL DEFAULT 'player';
ALTER TABLE audit_events ADD COLUMN IF NOT EXISTS role_at_time text;
ALTER TABLE audit_events ADD COLUMN IF NOT EXISTS area text NOT NULL DEFAULT 'Access';
ALTER TABLE audit_events ADD COLUMN IF NOT EXISTS links jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS idx_audit_created_desc ON audit_events(created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_audit_area_created_desc ON audit_events(area, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_target ON audit_events(target_type, target_id);

-- 7. Audit CSV export jobs
CREATE TABLE IF NOT EXISTS audit_exports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    requested_by uuid NOT NULL REFERENCES accounts(id),
    filters jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'READY', 'FAILED')),
    csv_content text,
    created_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL
);
