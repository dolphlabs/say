-- say: seasons, wallets and the ledger (Prompt 02, docs/ledger/DESIGN.md).
-- Rebuilds prompt 01's ledger tables; dev databases were reset for this
-- (no production data exists), so nothing is converted.

-- 1. The runtime role. Production creates it (and a login role that is a
-- member) before migrating; this only covers fresh databases.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'say_app') THEN
        CREATE ROLE say_app NOLOGIN;
    END IF;
END
$$;

-- 2. Out with prompt 01's ledger.
DROP TRIGGER IF EXISTS trg_check_ledger_sum_zero ON ledger_entries;
DROP FUNCTION IF EXISTS check_ledger_transaction_sum_zero();
ALTER TABLE fills DROP COLUMN journal_id;
ALTER TABLE settlement_claims DROP COLUMN journal_id;
DROP TABLE issuance_grants;
DROP TABLE ledger_entries;
DROP TABLE ledger_transactions;
DROP TABLE wallets;
DELETE FROM accounts WHERE id = '00000000-0000-4000-8000-000000000001';

ALTER TABLE accounts DROP CONSTRAINT IF EXISTS accounts_kind_check;
ALTER TABLE accounts ADD CONSTRAINT accounts_kind_check CHECK (kind IN ('USER', 'BOT'));
CREATE INDEX idx_accounts_grantable ON accounts(id)
    WHERE kind = 'USER' AND status = 'ACTIVE' AND email_verified_at IS NOT NULL AND deleted_at IS NULL;

-- 3. Seasons: the schedule is derived from SEASON_ANCHOR, so seasons
-- inserted by hand before it existed are dropped.
DELETE FROM seasons;
DROP INDEX IF EXISTS idx_seasons_active;
ALTER TABLE seasons
    ADD COLUMN activated_at timestamptz,
    ADD COLUMN closed_at timestamptz,
    ADD COLUMN finalized_at timestamptz,
    ADD CONSTRAINT seasons_ordinal_positive CHECK (ordinal >= 1),
    ADD CONSTRAINT seasons_starts_at_key UNIQUE (starts_at);
CREATE UNIQUE INDEX seasons_one_active ON seasons ((true)) WHERE status = 'ACTIVE';

-- 4. Roles (the full role system is prompt 10).
CREATE TABLE account_roles (
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    role text NOT NULL CHECK (role IN ('admin', 'super_admin')),
    granted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, role)
);

-- 5. Wallets: one per owner, season and asset. System wallets keep no
-- cached balance; their balance is the sum of their entries.
CREATE TABLE wallets (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    season_id uuid NOT NULL REFERENCES seasons(id),
    owner_kind text NOT NULL CHECK (owner_kind IN ('user', 'bot', 'system')),
    owner_id text NOT NULL,
    account_id uuid REFERENCES accounts(id),
    asset_key text NOT NULL CHECK (asset_key = 'SEDI' OR asset_key ~ '^(YES|NO):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    free_units bigint NOT NULL DEFAULT 0,
    held_units bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (season_id, owner_id, asset_key),
    UNIQUE (id, season_id),
    CHECK ((owner_kind = 'system') = (account_id IS NULL)),
    CHECK (owner_kind = 'system' OR owner_id = account_id::text),
    CHECK (owner_kind <> 'system' OR owner_id LIKE 'system:%'),
    CONSTRAINT wallets_nonnegative CHECK (owner_kind = 'system' OR (free_units >= 0 AND held_units >= 0)),
    CHECK (owner_kind <> 'system' OR (free_units = 0 AND held_units = 0))
);
CREATE INDEX idx_wallets_account ON wallets(account_id, season_id) WHERE account_id IS NOT NULL;

-- 6. The journal. Append-only for the runtime role (grants below).
CREATE TABLE ledger_transactions (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    business_key text NOT NULL UNIQUE CHECK (length(business_key) BETWEEN 1 AND 200),
    kind text NOT NULL CHECK (kind IN ('SEASON_GRANT', 'ORDER_HOLD', 'ORDER_RELEASE', 'FILL', 'FEE',
                                       'MINT', 'MERGE', 'PAYOUT', 'BOT_FUNDING', 'ADJUSTMENT')),
    season_id uuid NOT NULL REFERENCES seasons(id),
    market_id uuid REFERENCES markets(id),
    ref_type text,
    ref_id text,
    payload_hash bytea NOT NULL,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, season_id)
);
CREATE INDEX idx_ledger_tx_xid ON ledger_transactions(xid);
CREATE INDEX idx_ledger_tx_market ON ledger_transactions(market_id) WHERE market_id IS NOT NULL;

CREATE TABLE holds (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    wallet_id uuid NOT NULL,
    season_id uuid NOT NULL,
    asset_key text NOT NULL,
    amount_held bigint NOT NULL CHECK (amount_held > 0),
    amount_consumed bigint NOT NULL DEFAULT 0 CHECK (amount_consumed >= 0),
    amount_released bigint NOT NULL DEFAULT 0 CHECK (amount_released >= 0),
    ref_type text NOT NULL,
    ref_id text NOT NULL,
    status text NOT NULL CHECK (status IN ('open', 'closed')),
    opened_tx bigint NOT NULL REFERENCES ledger_transactions(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    closed_at timestamptz,
    FOREIGN KEY (wallet_id, season_id) REFERENCES wallets(id, season_id),
    CHECK (amount_consumed + amount_released <= amount_held),
    CHECK ((status = 'closed') = (amount_consumed + amount_released = amount_held))
);
CREATE INDEX idx_holds_open_season ON holds(season_id) WHERE status = 'open';
CREATE INDEX idx_holds_wallet ON holds(wallet_id) WHERE status = 'open';
CREATE INDEX idx_holds_ref ON holds(ref_type, ref_id);

CREATE TABLE ledger_entries (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id bigint NOT NULL,
    season_id uuid NOT NULL,
    wallet_id uuid NOT NULL,
    asset_key text NOT NULL,
    bucket text NOT NULL CHECK (bucket IN ('free', 'held')),
    delta bigint NOT NULL CHECK (delta <> 0),
    free_after bigint,
    held_after bigint,
    hold_id uuid REFERENCES holds(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (transaction_id, season_id) REFERENCES ledger_transactions(id, season_id),
    FOREIGN KEY (wallet_id, season_id) REFERENCES wallets(id, season_id),
    CHECK ((free_after IS NULL) = (held_after IS NULL))
);
CREATE INDEX idx_ledger_entries_tx ON ledger_entries(transaction_id);
CREATE INDEX idx_ledger_entries_wallet ON ledger_entries(wallet_id, created_at DESC, transaction_id DESC);
CREATE INDEX idx_ledger_entries_hold ON ledger_entries(hold_id) WHERE hold_id IS NOT NULL;

ALTER TABLE fills ADD COLUMN journal_id bigint NOT NULL REFERENCES ledger_transactions(id);
ALTER TABLE settlement_claims ADD COLUMN journal_id bigint NOT NULL UNIQUE REFERENCES ledger_transactions(id);

-- Defence in depth: post() already refuses all of this. If one of these
-- fires, it is a bug in post(), and the commit fails.
CREATE FUNCTION ledger_check_entries() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    bad record;
BEGIN
    SELECT e.asset_key, sum(e.delta) AS total INTO bad
      FROM ledger_entries e
     WHERE e.transaction_id = NEW.transaction_id
     GROUP BY e.asset_key
    HAVING sum(e.delta) <> 0
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'LEDGER_INVARIANT unbalanced: transaction % asset % sums to %',
            NEW.transaction_id, bad.asset_key, bad.total USING ERRCODE = '23514';
    END IF;
    PERFORM 1
       FROM ledger_entries e
       JOIN wallets w ON w.id = e.wallet_id
       JOIN ledger_transactions t ON t.id = e.transaction_id
      WHERE e.transaction_id = NEW.transaction_id
        AND (w.season_id <> t.season_id OR e.season_id <> t.season_id OR w.asset_key <> e.asset_key);
    IF FOUND THEN
        RAISE EXCEPTION 'LEDGER_INVARIANT season or asset mismatch in transaction %',
            NEW.transaction_id USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER ledger_entries_balanced
AFTER INSERT ON ledger_entries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION ledger_check_entries();

CREATE FUNCTION ledger_check_transaction() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT count(*) FROM ledger_entries WHERE transaction_id = NEW.id) < 2 THEN
        RAISE EXCEPTION 'LEDGER_INVARIANT transaction % has fewer than two entries', NEW.id
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER ledger_transactions_have_entries
AFTER INSERT ON ledger_transactions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION ledger_check_transaction();

-- 7. Issuance: a two-operator policy, a sharded per-season budget so the
-- cap is exact without one hot row, and one grant per account and season.
CREATE TABLE issuance_policies (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    amount bigint NOT NULL CHECK (amount > 0),
    season_cap bigint NOT NULL,
    status text NOT NULL CHECK (status IN ('PROPOSED', 'APPROVED', 'REVOKED')),
    proposed_by uuid NOT NULL REFERENCES accounts(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    approved_at timestamptz,
    revoked_at timestamptz,
    CHECK (season_cap >= amount)
);
CREATE UNIQUE INDEX issuance_policies_one_approved ON issuance_policies ((true)) WHERE status = 'APPROVED';

CREATE TABLE issuance_policy_approvals (
    policy_id uuid NOT NULL REFERENCES issuance_policies(id),
    operator_id uuid NOT NULL REFERENCES accounts(id),
    approved_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (policy_id, operator_id)
);

CREATE TABLE issuance_budget (
    season_id uuid NOT NULL REFERENCES seasons(id),
    shard smallint NOT NULL CHECK (shard BETWEEN 0 AND 15),
    policy_id uuid NOT NULL REFERENCES issuance_policies(id),
    remaining bigint NOT NULL CHECK (remaining >= 0),
    PRIMARY KEY (season_id, shard)
);

CREATE TABLE issuance_grants (
    account_id uuid NOT NULL REFERENCES accounts(id),
    season_id uuid NOT NULL REFERENCES seasons(id),
    amount bigint NOT NULL CHECK (amount > 0),
    policy_id uuid NOT NULL REFERENCES issuance_policies(id),
    business_key text NOT NULL UNIQUE
        REFERENCES ledger_transactions(business_key) DEFERRABLE INITIALLY DEFERRED,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, season_id)
);
CREATE INDEX idx_issuance_grants_season ON issuance_grants(season_id);

CREATE TABLE grant_runs (
    season_id uuid PRIMARY KEY REFERENCES seasons(id),
    last_account_id uuid,
    granted bigint NOT NULL DEFAULT 0,
    skipped bigint NOT NULL DEFAULT 0,
    started_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    halted_reason text
);

-- 8. Checks, the system-balance read model, and the trading halt.
CREATE TABLE reconciliation_runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    scope text NOT NULL CHECK (scope IN ('incremental', 'full')),
    status text NOT NULL CHECK (status IN ('pending', 'running', 'done')),
    requested_by uuid REFERENCES accounts(id),
    from_xid xid8,
    to_xid xid8,
    started_at timestamptz,
    finished_at timestamptz,
    results jsonb,
    ok boolean,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_recon_runs_pending ON reconciliation_runs(created_at) WHERE status = 'pending';
CREATE INDEX idx_recon_runs_finished ON reconciliation_runs(finished_at DESC) WHERE status = 'done';

CREATE TABLE ledger_watermarks (
    name text PRIMARY KEY CHECK (name IN ('aggregate', 'recon')),
    xid xid8 NOT NULL
);
INSERT INTO ledger_watermarks (name, xid) VALUES ('aggregate', '0'), ('recon', '0');

CREATE TABLE system_balances (
    wallet_id uuid PRIMARY KEY REFERENCES wallets(id),
    season_id uuid NOT NULL REFERENCES seasons(id),
    owner_id text NOT NULL,
    asset_key text NOT NULL,
    balance bigint NOT NULL,
    as_of timestamptz NOT NULL
);

CREATE TABLE trading_halt (
    id smallint PRIMARY KEY CHECK (id = 1),
    halted boolean NOT NULL,
    reason text,
    changed_at timestamptz NOT NULL DEFAULT now(),
    changed_by uuid REFERENCES accounts(id)
);
INSERT INTO trading_halt (id, halted) VALUES (1, false);

CREATE INDEX idx_outbox_type ON outbox_events(type, created_at);

-- 9. Grants. The runtime role may append to the journal, never rewrite it;
-- money rows are never deleted.
GRANT USAGE ON SCHEMA public TO say_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO say_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO say_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO say_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO say_app;
REVOKE UPDATE, DELETE, TRUNCATE ON ledger_transactions, ledger_entries FROM say_app;
REVOKE DELETE, TRUNCATE ON wallets, holds, issuance_grants, issuance_budget, issuance_policies,
    issuance_policy_approvals, seasons FROM say_app;
