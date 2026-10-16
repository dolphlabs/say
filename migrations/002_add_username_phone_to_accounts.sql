-- say: add username and phone_number to accounts
ALTER TABLE accounts
    ADD COLUMN IF NOT EXISTS username text,
    ADD COLUMN IF NOT EXISTS phone_number text;

-- Unique case-insensitive username index (when username is set)
CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_username_lower
    ON accounts (LOWER(username))
    WHERE username IS NOT NULL;

-- Unique phone number index (when phone_number is set)
CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_phone_number
    ON accounts (phone_number)
    WHERE phone_number IS NOT NULL;
