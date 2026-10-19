-- say: authentication (Prompt 01). Sessions, OTPs, Google identities and
-- the auth outbox; accounts move to case-insensitive identity columns;
-- the issuance account can post the S 1,000 grant.

CREATE EXTENSION IF NOT EXISTS citext;

-- 1. accounts: citext identity, credentials split out, spec statuses.
DROP INDEX IF EXISTS idx_accounts_username_lower;
DROP INDEX IF EXISTS idx_accounts_email;
ALTER TABLE accounts DROP CONSTRAINT IF EXISTS accounts_email_key;
ALTER TABLE accounts DROP CONSTRAINT IF EXISTS accounts_status_check;
ALTER TABLE accounts DROP CONSTRAINT IF EXISTS accounts_auth_provider_check;

ALTER TABLE accounts
    ALTER COLUMN username TYPE citext,
    ALTER COLUMN email TYPE citext,
    DROP COLUMN IF EXISTS password_hash,
    DROP COLUMN IF EXISTS auth_provider,
    DROP COLUMN IF EXISTS verified_at,
    DROP COLUMN IF EXISTS age_confirmed_at,
    ADD COLUMN deleted_at timestamptz,
    ADD COLUMN username_changeable_at timestamptz NOT NULL DEFAULT now(),
    ALTER COLUMN status SET DEFAULT 'UNVERIFIED';

ALTER TABLE accounts
    ADD CONSTRAINT accounts_username_key UNIQUE (username),
    ADD CONSTRAINT accounts_email_key UNIQUE (email),
    ADD CONSTRAINT accounts_status_check
        CHECK (status IN ('UNVERIFIED','ACTIVE','SUSPENDED','LOCKED','DELETED')),
    -- System accounts (issuance, treasury ...) have no username; people do.
    ADD CONSTRAINT accounts_user_has_username
        CHECK (kind <> 'USER' OR username IS NOT NULL);

-- 2. Credentials and external identities.
CREATE TABLE password_credentials (
    account_id uuid PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    hash text NOT NULL,
    algo text NOT NULL,
    params text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE auth_identities (
    provider text NOT NULL CHECK (provider IN ('google')),
    subject text NOT NULL,
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    email_at_link citext,
    linked_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (provider, subject),
    UNIQUE (account_id, provider)
);

-- 3. Sessions: only sha256(token) is stored.
CREATE TABLE sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    token_hash bytea NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    ip inet,
    user_agent text
);
CREATE INDEX idx_sessions_account_live ON sessions(account_id) WHERE revoked_at IS NULL;
CREATE INDEX idx_sessions_expires ON sessions(expires_at);

-- 4. One-time codes: HMAC only, one live code per account and purpose.
DROP TABLE IF EXISTS auth_otps;
CREATE TABLE otp_codes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    purpose text NOT NULL CHECK (purpose IN ('verify_email','reset_password')),
    code_hmac bytea NOT NULL,
    expires_at timestamptz NOT NULL,
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    consumed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_otp_codes_live ON otp_codes(account_id, purpose) WHERE consumed_at IS NULL;
CREATE INDEX idx_otp_codes_expires ON otp_codes(expires_at);

-- Every code sent, for the 60 s cooldown and the 5-per-hour cap.
CREATE TABLE otp_sends (
    id bigserial PRIMARY KEY,
    email citext NOT NULL,
    purpose text NOT NULL,
    sent_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_otp_sends_email ON otp_sends(email, sent_at);

-- 5. Signup tokens: let an unverified client verify or resend, nothing else.
CREATE TABLE signup_tokens (
    token_hash bytea PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    expires_at timestamptz NOT NULL
);
CREATE INDEX idx_signup_tokens_account ON signup_tokens(account_id);
CREATE INDEX idx_signup_tokens_expires ON signup_tokens(expires_at);

-- 6. Outbox: written in the transaction that owes the email, delivered after.
CREATE TABLE auth_outbox (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind text NOT NULL CHECK (kind IN ('otp_email')),
    payload jsonb NOT NULL,
    attempts integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    sent_at timestamptz,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_auth_outbox_due ON auth_outbox(next_attempt_at) WHERE sent_at IS NULL;

CREATE INDEX idx_audit_created ON audit_events(created_at);

-- 7. Ledger: the issuance account's wallet is the one balance allowed below
-- zero, so a grant can be posted as a balanced pair.
ALTER TABLE wallets DROP CONSTRAINT IF EXISTS wallets_free_units_check;
ALTER TABLE wallets
    ADD COLUMN allow_negative boolean NOT NULL DEFAULT false,
    ADD CONSTRAINT wallets_free_units_check CHECK (allow_negative OR free_units >= 0);

INSERT INTO accounts (id, kind, status)
VALUES ('00000000-0000-4000-8000-000000000001', 'ISSUANCE', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

CREATE INDEX idx_seasons_active ON seasons(starts_at) WHERE status = 'ACTIVE';
CREATE INDEX idx_issuance_grants_season ON issuance_grants(season_id);
