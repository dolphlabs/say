-- 019_account_avatar_url.sql
-- Profile photos live on Cloudinary; the account keeps only the delivery URL,
-- which the service builds itself from a signed upload response.

ALTER TABLE accounts ADD COLUMN IF NOT EXISTS avatar_url text
    CHECK (avatar_url IS NULL OR (avatar_url LIKE 'https://res.cloudinary.com/%' AND length(avatar_url) <= 512));
