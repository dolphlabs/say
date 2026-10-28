-- 013_portfolio_and_notifications.sql
-- Prompt 07: Portfolio read models and notification pipeline.

-- 1. position_results: settled results written by prompt 08 in settlement tx, read now by prompt 07
CREATE TABLE IF NOT EXISTS position_results (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    market_id uuid NOT NULL REFERENCES markets(id) ON DELETE CASCADE,
    season_id uuid NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
    outcome text NOT NULL CHECK (outcome IN ('YES', 'NO')),
    qty bigint NOT NULL CHECK (qty >= 0),
    cost_basis bigint NOT NULL CHECK (cost_basis >= 0),
    fees bigint NOT NULL DEFAULT 0 CHECK (fees >= 0),
    paid_out bigint NOT NULL DEFAULT 0 CHECK (paid_out >= 0),
    pnl bigint NOT NULL,
    result text NOT NULL CHECK (result IN ('WON', 'LOST', 'VOIDED')),
    settled_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_position_results_account_market_season_outcome UNIQUE (account_id, market_id, season_id, outcome)
);
CREATE INDEX IF NOT EXISTS idx_position_results_account_season ON position_results(account_id, season_id, settled_at DESC);
CREATE INDEX IF NOT EXISTS idx_position_results_market ON position_results(market_id);

-- 2. notifications: user-facing notifications for portfolio & bell
CREATE TABLE IF NOT EXISTS notifications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    kind text NOT NULL,
    dedupe_key text NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    link text NOT NULL DEFAULT '',
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    read_at timestamptz,
    CONSTRAINT uq_notifications_account_dedupe UNIQUE (account_id, dedupe_key)
);
CREATE INDEX IF NOT EXISTS idx_notifications_account_created ON notifications(account_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_account_unread ON notifications(account_id) WHERE read_at IS NULL;

-- 3. notification_prefs: user notification settings (in_app and email per kind)
CREATE TABLE IF NOT EXISTS notification_prefs (
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    kind text NOT NULL,
    in_app boolean NOT NULL DEFAULT true,
    email boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, kind)
);
CREATE INDEX IF NOT EXISTS idx_notification_prefs_account ON notification_prefs(account_id);

-- 4. fanout_jobs: tracked fan-out work across workers
CREATE TABLE IF NOT EXISTS fanout_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind text NOT NULL,
    subject text NOT NULL,
    cursor text NOT NULL DEFAULT '',
    done boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_fanout_jobs_pending ON fanout_jobs(created_at) WHERE NOT done;

-- 5. email_outbox: general email queue for notification & recap emails
CREATE TABLE IF NOT EXISTS email_outbox (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid REFERENCES accounts(id) ON DELETE CASCADE,
    kind text NOT NULL,
    dedupe_key text,
    recipient_email text NOT NULL,
    subject text NOT NULL,
    body_text text NOT NULL,
    body_html text NOT NULL,
    attempts integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    sent_at timestamptz,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_email_outbox_dedupe ON email_outbox(dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_email_outbox_due ON email_outbox(next_attempt_at) WHERE sent_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_email_outbox_account ON email_outbox(account_id);

-- 6. Add closing_soon_sent_at to markets for 60-minute closing soon scheduler
ALTER TABLE markets ADD COLUMN IF NOT EXISTS closing_soon_sent_at timestamptz;
CREATE INDEX IF NOT EXISTS idx_markets_closing_soon ON markets(close_at) WHERE closing_soon_sent_at IS NULL AND status IN ('OPEN', 'SUSPENDED');

GRANT SELECT, INSERT, UPDATE, DELETE ON position_results, notifications, notification_prefs, fanout_jobs, email_outbox TO say_app;
