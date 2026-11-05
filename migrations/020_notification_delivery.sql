-- 020_notification_delivery.sql
-- Notification emails are rendered when sent, so the outbox keeps the link
-- rather than finished HTML. A fan-out job is unique per kind and subject:
-- a retried fan-out resumes the job it started instead of starting another.

ALTER TABLE email_outbox ADD COLUMN IF NOT EXISTS link_url text NOT NULL DEFAULT ''
    CHECK (length(link_url) <= 512);

DELETE FROM fanout_jobs a USING fanout_jobs b
    WHERE a.kind = b.kind AND a.subject = b.subject
    AND (a.created_at, a.id) > (b.created_at, b.id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_fanout_jobs_kind_subject ON fanout_jobs(kind, subject);
