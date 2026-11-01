-- 018_account_avatar_color.sql
-- Standings and public profiles read accounts.avatar_color, which no earlier
-- migration created, so both queries failed outright. The colour only needs
-- to be stable per account, so it is derived from the id rather than stored
-- by a writer.

ALTER TABLE accounts ADD COLUMN IF NOT EXISTS avatar_color text
    GENERATED ALWAYS AS (
        (ARRAY['#C6F432', '#FF7AC6', '#6FA8FF', '#FFB86B', '#A992FF', '#5FD4F0'])
            [1 + get_byte(decode(md5(id::text), 'hex'), 0) % 6]
    ) STORED;
