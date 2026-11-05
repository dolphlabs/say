-- 021_bot_funding.sql
-- Bot money moves only through approved requests. A season budget needs
-- two operators; a top-up needs one who is not the requester. The worker
-- that applies an approved top-up checks it against the season's applied
-- budget and posts BOT_FUNDING in the same transaction.

CREATE TABLE IF NOT EXISTS bot_season_budgets (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    season_id uuid NOT NULL REFERENCES seasons(id),
    cap bigint NOT NULL CHECK (cap > 0),
    reason text NOT NULL DEFAULT '' CHECK (length(reason) <= 500),
    requested_by uuid NOT NULL REFERENCES accounts(id),
    status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPLIED', 'REJECTED')),
    status_reason text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    decided_at timestamptz
);
CREATE INDEX IF NOT EXISTS idx_bot_season_budgets_pending ON bot_season_budgets(created_at) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS idx_bot_season_budgets_applied ON bot_season_budgets(season_id, decided_at) WHERE status = 'APPLIED';

CREATE TABLE IF NOT EXISTS bot_topups (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bot_id uuid NOT NULL,
    market_id uuid NOT NULL,
    season_id uuid NOT NULL REFERENCES seasons(id),
    amount bigint NOT NULL CHECK (amount > 0),
    reason text NOT NULL DEFAULT '' CHECK (length(reason) <= 500),
    requested_by uuid NOT NULL REFERENCES accounts(id),
    status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPLIED', 'REJECTED')),
    status_reason text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    decided_at timestamptz,
    FOREIGN KEY (bot_id, market_id) REFERENCES bot_markets(bot_id, market_id)
);
CREATE INDEX IF NOT EXISTS idx_bot_topups_pending ON bot_topups(created_at) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS idx_bot_topups_bot_market ON bot_topups(bot_id, market_id);
CREATE INDEX IF NOT EXISTS idx_bot_topups_season ON bot_topups(season_id);
CREATE INDEX IF NOT EXISTS idx_bot_api_keys_bot ON bot_api_keys(bot_id);

GRANT SELECT, INSERT, UPDATE ON bot_season_budgets, bot_topups TO say_app;
