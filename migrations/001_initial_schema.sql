-- say: initial database schema (PostgreSQL 13+)
-- Source of truth for accounts, seasons, markets, orders, fills, wallets,
-- double-entry ledger, resolutions, and outbox streaming.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1. Seasons (14-day competition cycles in Africa/Lagos UTC+01:00, stored as UTC)
CREATE TABLE seasons (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ordinal bigint UNIQUE NOT NULL,
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    status text NOT NULL CHECK (status IN ('SCHEDULED','ACTIVE','CLOSING','CLOSED','FINALIZED')),
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (ends_at = starts_at + interval '14 days')
);
CREATE INDEX idx_seasons_status ON seasons(status);

-- 2. Accounts: users and system entities (treasury, collateral custody, fee, issuance)
CREATE TABLE accounts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email text UNIQUE,
    password_hash text,
    auth_provider text NOT NULL DEFAULT 'LOCAL' CHECK (auth_provider IN ('LOCAL', 'GOOGLE', 'SYSTEM')),
    email_verified_at timestamptz,
    verified_at timestamptz,
    age_confirmed_at timestamptz,
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','LOCKED')),
    beneficial_owner_group uuid,
    kind text NOT NULL DEFAULT 'USER' CHECK (kind IN ('USER', 'TREASURY', 'COLLATERAL', 'FEE', 'ISSUANCE')),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_accounts_owner_group ON accounts(beneficial_owner_group) WHERE beneficial_owner_group IS NOT NULL;
CREATE INDEX idx_accounts_email ON accounts(email) WHERE email IS NOT NULL;
CREATE INDEX idx_accounts_kind ON accounts(kind);

-- 3. Device & Audit records for anti-sybil & dispute detection (IP, user-agent, fingerprint)
CREATE TABLE account_devices (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    ip_address inet,
    user_agent text,
    fingerprint text,
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_devices_account ON account_devices(account_id);
CREATE INDEX idx_devices_ip ON account_devices(ip_address);
CREATE INDEX idx_devices_fingerprint ON account_devices(fingerprint);

-- 4. Email verification and password reset OTPs
CREATE TABLE auth_otps (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    code_hash text NOT NULL,
    purpose text NOT NULL DEFAULT 'EMAIL_VERIFY' CHECK (purpose IN ('EMAIL_VERIFY', 'PASSWORD_RESET', 'LOGIN_OTP')),
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_auth_otps_account ON auth_otps(account_id, purpose) WHERE consumed_at IS NULL;

-- 5. Binary YES/NO prediction markets
CREATE TABLE markets (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    season_id uuid NOT NULL REFERENCES seasons(id),
    statement text NOT NULL,
    terms_hash text NOT NULL,
    redemption_units bigint NOT NULL CHECK (redemption_units >= 3),
    min_price bigint NOT NULL CHECK (min_price > 0),
    max_price bigint NOT NULL,
    tick bigint NOT NULL CHECK (tick > 0),
    fee_units bigint NOT NULL DEFAULT 1 CHECK (fee_units >= 0),
    min_order_notional bigint NOT NULL DEFAULT 2 CHECK (min_order_notional >= 1),
    status text NOT NULL CHECK (status IN ('DRAFT','REVIEW','APPROVED','FUNDING','OPEN','SUSPENDED','CLOSED','RESOLUTION_PENDING','DISPUTED','RESOLVED','SETTLING','SETTLED','VOIDED')),
    cutoff_at timestamptz NOT NULL,
    resolution_at timestamptz,
    owner_epoch bigint NOT NULL DEFAULT 0,
    committed_seq bigint NOT NULL DEFAULT 0,
    book_seq bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (max_price < redemption_units AND min_price <= max_price),
    CHECK ((max_price - min_price) >= 0)
);
CREATE INDEX idx_markets_season ON markets(season_id);
CREATE INDEX idx_markets_status ON markets(status);

-- 6. Wallets: balances for sedis and per-market outcome contract shares
CREATE TABLE wallets (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES accounts(id),
    season_id uuid NOT NULL REFERENCES seasons(id),
    asset_key text NOT NULL,
    free_units bigint NOT NULL DEFAULT 0 CHECK (free_units >= 0),
    reserved_units bigint NOT NULL DEFAULT 0 CHECK (reserved_units >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (account_id, season_id, asset_key)
);
CREATE INDEX idx_wallets_account ON wallets(account_id, season_id);

-- 7. Double-entry ledger transactions & entries
CREATE TABLE ledger_transactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    business_key text NOT NULL UNIQUE,
    kind text NOT NULL CHECK (kind IN ('ISSUANCE_GRANT','ORDER_FILL','MINT_PAIR','MERGE_PAIR','FEE_CHARGE','SETTLEMENT_PAYOUT','TREASURY_TRANSFER')),
    season_id uuid REFERENCES seasons(id),
    market_id uuid REFERENCES markets(id),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_ledger_tx_business_key ON ledger_transactions(business_key);
CREATE INDEX idx_ledger_tx_market ON ledger_transactions(market_id) WHERE market_id IS NOT NULL;

CREATE TABLE ledger_entries (
    id bigserial PRIMARY KEY,
    transaction_id uuid NOT NULL REFERENCES ledger_transactions(id),
    wallet_id uuid NOT NULL REFERENCES wallets(id),
    asset_key text NOT NULL,
    delta_units bigint NOT NULL CHECK (delta_units <> 0)
);
CREATE INDEX idx_ledger_entries_tx ON ledger_entries(transaction_id);
CREATE INDEX idx_ledger_entries_wallet ON ledger_entries(wallet_id);

-- Deferred sum-zero check trigger: every transaction balances per asset
CREATE OR REPLACE FUNCTION check_ledger_transaction_sum_zero()
RETURNS trigger AS $$
DECLARE
    unbalanced RECORD;
BEGIN
    SELECT asset_key, SUM(delta_units) AS total
    FROM ledger_entries
    WHERE transaction_id = NEW.transaction_id
    GROUP BY asset_key
    HAVING SUM(delta_units) <> 0
    LIMIT 1 INTO unbalanced;

    IF FOUND THEN
        RAISE EXCEPTION 'Ledger transaction % unbalanced for asset %: sum = %',
            NEW.transaction_id, unbalanced.asset_key, unbalanced.total
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_check_ledger_sum_zero
AFTER INSERT OR UPDATE ON ledger_entries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION check_ledger_transaction_sum_zero();

-- 8. Orders
CREATE TABLE orders (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES accounts(id),
    market_id uuid NOT NULL REFERENCES markets(id),
    outcome text NOT NULL CHECK (outcome IN ('YES','NO')),
    side text NOT NULL CHECK (side IN ('BUY','SELL')),
    limit_price bigint NOT NULL CHECK (limit_price > 0),
    original_qty bigint NOT NULL CHECK (original_qty > 0),
    remaining_qty bigint NOT NULL CHECK (remaining_qty >= 0),
    status text NOT NULL CHECK (status IN ('OPEN','PARTIAL','FILLED','CANCELLED','REJECTED','EXPIRED')),
    tif text NOT NULL CHECK (tif IN ('GTC','IOC')),
    fee_posted boolean NOT NULL DEFAULT false,
    accepted_seq bigint,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (remaining_qty <= original_qty)
);
CREATE INDEX idx_orders_book ON orders(market_id, outcome, side, limit_price, created_at, id) WHERE remaining_qty > 0;
CREATE INDEX idx_orders_account ON orders(account_id, market_id);

-- 9. Idempotency records for admission
CREATE TABLE idempotency_records (
    account_id uuid NOT NULL REFERENCES accounts(id),
    scope text NOT NULL,
    idem_key text NOT NULL,
    request_hash text NOT NULL,
    order_id uuid REFERENCES orders(id),
    state text NOT NULL CHECK (state IN ('PENDING','COMMITTED','REJECTED')),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, scope, idem_key)
);

-- 10. Durable market command sequence
CREATE TABLE market_commands (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    market_id uuid NOT NULL REFERENCES markets(id),
    seq bigint NOT NULL,
    command_type text NOT NULL,
    payload jsonb NOT NULL,
    state text NOT NULL CHECK (state IN ('ACCEPTED','COMMITTED','REJECTED')),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (market_id, seq)
);

-- 11. Execution fills
CREATE TABLE fills (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    market_id uuid NOT NULL REFERENCES markets(id),
    execution_seq bigint NOT NULL,
    fill_index integer NOT NULL,
    maker_order_id uuid NOT NULL REFERENCES orders(id),
    taker_order_id uuid NOT NULL REFERENCES orders(id),
    mode text NOT NULL CHECK (mode IN ('TRANSFER','MINT','MERGE')),
    qty bigint NOT NULL CHECK (qty > 0),
    yes_equivalent_price bigint NOT NULL,
    journal_id uuid NOT NULL REFERENCES ledger_transactions(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (market_id, execution_seq, fill_index)
);
CREATE INDEX idx_fills_market ON fills(market_id, execution_seq);
CREATE INDEX idx_fills_maker ON fills(maker_order_id);
CREATE INDEX idx_fills_taker ON fills(taker_order_id);

-- 12. Outbox events for streaming to Redis / WebSocket
CREATE TABLE outbox_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    market_id uuid REFERENCES markets(id),
    market_seq bigint,
    book_seq bigint,
    type text NOT NULL,
    payload jsonb NOT NULL,
    published_at timestamptz,
    attempt_count integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_outbox_unprocessed ON outbox_events(created_at) WHERE published_at IS NULL;
CREATE INDEX idx_outbox_market_seq ON outbox_events(market_id, market_seq) WHERE market_id IS NOT NULL;

-- 13. Seasonal 1,000 sedis issuance grants
CREATE TABLE issuance_grants (
    account_id uuid NOT NULL REFERENCES accounts(id),
    season_id uuid NOT NULL REFERENCES seasons(id),
    amount bigint NOT NULL CHECK (amount > 0),
    journal_id uuid NOT NULL UNIQUE REFERENCES ledger_transactions(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, season_id)
);

-- 14. Market resolutions and evidence
CREATE TABLE market_resolutions (
    market_id uuid PRIMARY KEY REFERENCES markets(id),
    proposed_outcome text CHECK (proposed_outcome IN ('YES','NO','VOID')),
    evidence_digest text,
    proposed_at timestamptz,
    dispute_until timestamptz,
    approved_outcome text CHECK (approved_outcome IN ('YES','NO','VOID')),
    super_admin_id uuid REFERENCES accounts(id),
    approved_at timestamptz,
    status text NOT NULL CHECK (status IN ('PENDING_APPROVAL','DISPUTED','APPROVED','CANCELLED'))
);

-- 15. Settlement claims per account position
CREATE TABLE settlement_claims (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    market_id uuid NOT NULL REFERENCES markets(id),
    account_id uuid NOT NULL REFERENCES accounts(id),
    decision_key text NOT NULL,
    outcome text NOT NULL CHECK (outcome IN ('YES','NO')),
    units bigint NOT NULL CHECK (units >= 0),
    journal_id uuid NOT NULL UNIQUE REFERENCES ledger_transactions(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (market_id, account_id, decision_key, outcome)
);

-- 16. Audit events
CREATE TABLE audit_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id uuid REFERENCES accounts(id),
    action text NOT NULL,
    target_type text NOT NULL,
    target_id text,
    ip_address inet,
    user_agent text,
    detail jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_actor ON audit_events(actor_id);
CREATE INDEX idx_audit_action ON audit_events(action);

-- 17. In-memory book snapshots
CREATE TABLE market_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    market_id uuid NOT NULL REFERENCES markets(id),
    committed_seq bigint NOT NULL,
    book_seq bigint NOT NULL,
    state_hash text NOT NULL,
    payload jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (market_id, committed_seq)
);
