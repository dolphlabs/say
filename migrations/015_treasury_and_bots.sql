-- 015_treasury_and_bots.sql
-- Prompt 09: Treasury, bot accounts, market-making parameters, and decision logging.

-- 1. Ledger transaction kind constraint expansion
ALTER TABLE ledger_transactions DROP CONSTRAINT IF EXISTS ledger_transactions_kind_check;
ALTER TABLE ledger_transactions ADD CONSTRAINT ledger_transactions_kind_check
    CHECK (kind IN ('SEASON_GRANT', 'ORDER_HOLD', 'ORDER_RELEASE', 'FILL', 'FEE',
                    'MINT', 'MERGE', 'PAYOUT', 'BOT_FUNDING', 'BOT_ALLOCATION', 'BOT_SWEEP',
                    'ADJUSTMENT', 'VOID_REFUND', 'FEE_REFUND', 'VOID_COLLATERAL_RELEASE'));

-- 2. Ensure opening_price on markets and bots_paused on trading_halt
ALTER TABLE markets ADD COLUMN IF NOT EXISTS opening_price bigint;
ALTER TABLE trading_halt ADD COLUMN IF NOT EXISTS bots_paused boolean NOT NULL DEFAULT false;

-- 3. Bot API Keys (scoped for trading & stream ingestion, rotatable)
CREATE TABLE IF NOT EXISTS bot_api_keys (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bot_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    key_hash text NOT NULL UNIQUE,
    key_prefix text NOT NULL,
    label text NOT NULL DEFAULT '',
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz
);
CREATE INDEX IF NOT EXISTS idx_bot_api_keys_lookup ON bot_api_keys(key_hash) WHERE revoked_at IS NULL;

-- 4. Bot Markets (per-market tracking, allocation, status)
CREATE TABLE IF NOT EXISTS bot_markets (
    bot_id uuid NOT NULL REFERENCES accounts(id),
    market_id uuid NOT NULL REFERENCES markets(id),
    season_id uuid NOT NULL REFERENCES seasons(id),
    allocated bigint NOT NULL DEFAULT 0 CHECK (allocated >= 0),
    used bigint NOT NULL DEFAULT 0 CHECK (used >= 0),
    status text NOT NULL DEFAULT 'QUOTING'
        CHECK (status IN ('QUOTING', 'PULLED_STALE', 'PULLED_CAP', 'PULLED_DRAWDOWN', 'PULLED_MARKET', 'PAUSED_MANUAL', 'PAUSED_ALL')),
    status_reason text NOT NULL DEFAULT '',
    params_version int NOT NULL DEFAULT 1,
    last_quote_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (bot_id, market_id)
);
CREATE INDEX IF NOT EXISTS idx_bot_markets_season ON bot_markets(season_id);

-- 5. Bot Parameters (versioned, audited)
CREATE TABLE IF NOT EXISTS bot_params (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bot_id uuid NOT NULL REFERENCES accounts(id),
    market_id uuid NOT NULL REFERENCES markets(id),
    version int NOT NULL DEFAULT 1,
    base_spread_ticks int NOT NULL DEFAULT 2 CHECK (base_spread_ticks >= 1),
    vol_ticks int NOT NULL DEFAULT 1 CHECK (vol_ticks >= 0),
    skew_ticks int NOT NULL DEFAULT 4 CHECK (skew_ticks >= 0),
    levels int NOT NULL DEFAULT 3 CHECK (levels BETWEEN 1 AND 10),
    base_size int NOT NULL DEFAULT 10 CHECK (base_size >= 1),
    max_net_shares int NOT NULL DEFAULT 400 CHECK (max_net_shares >= 1),
    max_loss int NOT NULL DEFAULT 50000 CHECK (max_loss >= 0),
    season_max_drawdown int NOT NULL DEFAULT 100000 CHECK (season_max_drawdown >= 0),
    min_requote_ms int NOT NULL DEFAULT 250 CHECK (min_requote_ms >= 50),
    max_ops_per_sec int NOT NULL DEFAULT 10 CHECK (max_ops_per_sec >= 1),
    max_open_orders int NOT NULL DEFAULT 20 CHECK (max_open_orders >= 1),
    created_by uuid REFERENCES accounts(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (bot_id, market_id, version)
);
CREATE INDEX IF NOT EXISTS idx_bot_params_latest ON bot_params(bot_id, market_id, version DESC);

-- 6. Bot Decisions ("Why did the bot do that?")
CREATE TABLE IF NOT EXISTS bot_decisions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bot_id uuid NOT NULL REFERENCES accounts(id),
    market_id uuid NOT NULL REFERENCES markets(id),
    at timestamptz NOT NULL DEFAULT now(),
    inputs_digest text NOT NULL,
    r int NOT NULL,
    r_prime int NOT NULL,
    spread int NOT NULL,
    util int NOT NULL,
    worst_case_loss int NOT NULL,
    status text NOT NULL,
    actions jsonb NOT NULL DEFAULT '[]'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_bot_decisions_market ON bot_decisions(bot_id, market_id, at DESC);

-- 7. Bot Market Results (post-settlement P/L recording)
CREATE TABLE IF NOT EXISTS bot_market_results (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bot_id uuid NOT NULL REFERENCES accounts(id),
    market_id uuid NOT NULL REFERENCES markets(id) UNIQUE,
    season_id uuid NOT NULL REFERENCES seasons(id),
    allocated bigint NOT NULL CHECK (allocated >= 0),
    topups bigint NOT NULL DEFAULT 0 CHECK (topups >= 0),
    swept bigint NOT NULL DEFAULT 0 CHECK (swept >= 0),
    pnl bigint NOT NULL,
    settled_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_bot_market_results_season ON bot_market_results(season_id);

-- 8. Grants to say_app
GRANT SELECT, INSERT, UPDATE ON bot_api_keys TO say_app;
GRANT SELECT, INSERT, UPDATE ON bot_markets TO say_app;
GRANT SELECT, INSERT ON bot_params TO say_app;
GRANT SELECT, INSERT ON bot_decisions TO say_app;
GRANT SELECT, INSERT, UPDATE ON bot_market_results TO say_app;
GRANT SELECT, UPDATE ON trading_halt TO say_app;
