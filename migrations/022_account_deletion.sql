-- 022_account_deletion.sql
-- Deleting an account is two steps. DELETING fences it at once: sessions
-- are revoked and order admission, which requires ACTIVE, refuses it. A
-- worker cancels its open orders and, once none remain, anonymises it
-- (DELETED). Each step can be retried until it completes.

ALTER TABLE accounts DROP CONSTRAINT IF EXISTS accounts_status_check;
ALTER TABLE accounts ADD CONSTRAINT accounts_status_check
    CHECK (status IN ('UNVERIFIED','ACTIVE','SUSPENDED','LOCKED','DELETING','DELETED'));

ALTER TABLE accounts ADD COLUMN IF NOT EXISTS deletion_requested_at timestamptz;
CREATE INDEX IF NOT EXISTS idx_accounts_deleting ON accounts(deletion_requested_at) WHERE status = 'DELETING';
