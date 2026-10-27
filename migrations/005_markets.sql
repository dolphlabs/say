CREATE EXTENSION IF NOT EXISTS pg_trgm;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM markets) THEN
        RAISE EXCEPTION 'Registry requires explicit legacy-market provenance backfill; rows were preserved';
    END IF;
END $$;
ALTER TABLE account_roles DROP CONSTRAINT account_roles_role_check;
ALTER TABLE account_roles ADD CONSTRAINT account_roles_role_check
    CHECK (role IN ('creator','curator','treasury','resolver','admin','super_admin'));
CREATE TABLE categories (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL UNIQUE,
    icon text NOT NULL, sort_order integer NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE resolution_sources (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL,
    url_pattern text NOT NULL CHECK (url_pattern LIKE 'https://%'),
    kind text NOT NULL CHECK (kind IN ('html','json')), approved boolean NOT NULL DEFAULT false,
    created_by uuid NOT NULL REFERENCES accounts(id), created_at timestamptz NOT NULL DEFAULT now(),
    approved_by uuid REFERENCES accounts(id), approved_at timestamptz,
    CHECK (NOT approved OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))
);
ALTER TABLE markets RENAME COLUMN statement TO question;
ALTER TABLE markets RENAME COLUMN cutoff_at TO close_at;
ALTER TABLE markets
    ALTER COLUMN question DROP NOT NULL, ALTER COLUMN season_id DROP NOT NULL,
    ALTER COLUMN terms_hash DROP NOT NULL, ALTER COLUMN redemption_units DROP NOT NULL,
    ALTER COLUMN min_price DROP NOT NULL, ALTER COLUMN max_price DROP NOT NULL,
    ALTER COLUMN close_at DROP NOT NULL,
    ADD COLUMN slug text NOT NULL UNIQUE,
    ADD COLUMN category_id uuid REFERENCES categories(id),
    ADD COLUMN resolution_source_id uuid REFERENCES resolution_sources(id),
    ADD COLUMN rules jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN open_at timestamptz, ADD COLUMN resolve_by timestamptz,
    ADD COLUMN max_order_qty bigint NOT NULL DEFAULT 10000 CHECK (max_order_qty BETWEEN 1 AND 10000000),
    ADD COLUMN liquidity_request bigint CHECK (liquidity_request > 0 AND liquidity_request <= 1000000000000),
    ADD COLUMN featured_rank bigint CHECK (featured_rank > 0), ADD COLUMN opening_price bigint,
    ADD COLUMN version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    ADD COLUMN terms_version bigint NOT NULL DEFAULT 0 CHECK (terms_version >= 0),
    ADD COLUMN created_by uuid NOT NULL REFERENCES accounts(id),
    ADD COLUMN submitted_by uuid REFERENCES accounts(id), ADD COLUMN approved_by uuid REFERENCES accounts(id),
    ADD COLUMN submitted_at timestamptz, ADD COLUMN approved_at timestamptz,
    ADD COLUMN opened_at timestamptz, ADD COLUMN closed_at timestamptz, ADD COLUMN suspended_at timestamptz,
    ADD COLUMN suspend_reason text, ADD COLUMN status_note text,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
    ADD CONSTRAINT markets_no_self_approval CHECK
        (approved_by IS NULL OR (submitted_by IS NOT NULL AND approved_by <> submitted_by));
ALTER TABLE markets DROP CONSTRAINT markets_status_check;
ALTER TABLE markets ADD CONSTRAINT markets_status_check CHECK
    (status IN ('DRAFT','REVIEW','CHANGES_REQUESTED','REJECTED','APPROVED','FUNDING','OPEN','SUSPENDED','CLOSED',
     'RESOLUTION_PENDING','DISPUTED','RESOLVED','VOIDED','SETTLING','SETTLED'));
ALTER TABLE markets ADD CONSTRAINT markets_price_grid CHECK
    ((redemption_units IS NULL OR redemption_units BETWEEN 10 AND 1000) AND
     (min_price IS NULL OR max_price IS NULL OR redemption_units IS NULL OR
      (min_price >= 1 AND min_price <= max_price AND max_price < redemption_units AND
       min_price + max_price = redemption_units AND min_price % tick = 0 AND
       (max_price-min_price) % tick = 0 AND redemption_units % tick = 0)) AND
     fee_units = 1 AND min_order_notional = 2);
ALTER TABLE markets ADD CONSTRAINT markets_submitted_complete CHECK
    (status IN ('DRAFT','CHANGES_REQUESTED') OR
     (question IS NOT NULL AND char_length(question) BETWEEN 10 AND 140 AND
      category_id IS NOT NULL AND season_id IS NOT NULL AND resolution_source_id IS NOT NULL AND
      redemption_units IS NOT NULL AND min_price IS NOT NULL AND max_price IS NOT NULL AND
      open_at IS NOT NULL AND close_at IS NOT NULL AND resolve_by IS NOT NULL AND
      open_at < close_at AND resolve_by BETWEEN close_at + interval '1 hour' AND close_at + interval '48 hours' AND
      char_length(rules->>'yes_if') BETWEEN 20 AND 600 AND char_length(rules->>'no_if') BETWEEN 20 AND 600 AND
      char_length(rules->>'edge_cases') BETWEEN 20 AND 600 AND
      rules ?& ARRAY['yes_if','no_if','edge_cases'] AND terms_version > 0 AND terms_hash IS NOT NULL));
CREATE INDEX markets_close_due ON markets(close_at) WHERE status IN ('OPEN','SUSPENDED');
CREATE INDEX markets_open_due ON markets(open_at) WHERE status IN ('APPROVED','FUNDING');
CREATE INDEX markets_creator ON markets(created_by,created_at DESC,id);
CREATE INDEX markets_category ON markets(category_id,status,created_at DESC,id);
CREATE INDEX markets_season ON markets(season_id,status);
CREATE INDEX markets_source ON markets(resolution_source_id);
CREATE INDEX markets_search ON markets USING gin(question gin_trgm_ops);
CREATE TABLE market_terms_versions (
    market_id uuid NOT NULL REFERENCES markets(id), terms_version bigint NOT NULL,
    question text NOT NULL, rules jsonb NOT NULL, source_id uuid NOT NULL REFERENCES resolution_sources(id),
    close_at timestamptz NOT NULL, resolve_by timestamptz NOT NULL, hash text NOT NULL,
    source_snapshot jsonb NOT NULL, policy_snapshot jsonb NOT NULL, canonical_payload text NOT NULL,
    reason text NOT NULL, created_by uuid NOT NULL REFERENCES accounts(id), created_at timestamptz NOT NULL,
    PRIMARY KEY(market_id,terms_version)
);
CREATE TABLE market_stats (
    market_id uuid PRIMARY KEY REFERENCES markets(id), last_price bigint,
    yes_bid bigint, yes_ask bigint, no_bid bigint, no_ask bigint,
    volume_units bigint, volume_24h_units bigint, players bigint, change_24h numeric, updated_at timestamptz
);
CREATE TABLE approval_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind text NOT NULL CHECK (kind IN ('market_open','liquidity','issuance_policy','void_shortfall','bot_season_budget','bot_topup','role_grant')),
    subject_type text NOT NULL, subject_id uuid NOT NULL, payload_hash text NOT NULL,
    requested_by uuid NOT NULL REFERENCES accounts(id), approval_round bigint NOT NULL DEFAULT 1,
    slot integer NOT NULL DEFAULT 1 CHECK (slot BETWEEN 1 AND 2), reason text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL, expires_at timestamptz NOT NULL,
    UNIQUE(kind,subject_id,approval_round,slot)
);
CREATE INDEX approval_requests_requester ON approval_requests(requested_by);
CREATE INDEX approval_requests_expiry ON approval_requests(expires_at);
CREATE TABLE approval_decisions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), approval_id uuid NOT NULL UNIQUE REFERENCES approval_requests(id),
    decided_by uuid NOT NULL REFERENCES accounts(id), decision text NOT NULL CHECK (decision IN ('approved','rejected')),
    note text NOT NULL, decided_at timestamptz NOT NULL
);
CREATE INDEX approval_decisions_decider ON approval_decisions(decided_by);
CREATE TABLE approval_state (
    approval_id uuid PRIMARY KEY REFERENCES approval_requests(id),
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','stale')),
    version bigint NOT NULL DEFAULT 1, decision_id uuid UNIQUE REFERENCES approval_decisions(id)
);
CREATE INDEX approval_state_status ON approval_state(status,approval_id);
CREATE TABLE approval_transitions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), approval_id uuid NOT NULL REFERENCES approval_requests(id),
    from_status text NOT NULL, to_status text NOT NULL, reason text NOT NULL, at timestamptz NOT NULL
);
CREATE INDEX approval_transitions_request ON approval_transitions(approval_id,at);
CREATE TABLE approval_applications (
    approval_id uuid PRIMARY KEY REFERENCES approval_requests(id), subject_id uuid NOT NULL, applied_at timestamptz NOT NULL
);
CREATE VIEW approvals AS SELECT r.*,s.status,s.version,d.decided_by,d.decided_at,d.decision,d.note
    FROM approval_requests r JOIN approval_state s ON s.approval_id=r.id
    LEFT JOIN approval_decisions d ON d.id=s.decision_id;
CREATE FUNCTION approval_independence() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r approval_requests;
BEGIN
    SELECT * INTO STRICT r FROM approval_requests WHERE id=NEW.approval_id;
    IF NEW.decided_by=r.requested_by THEN RAISE EXCEPTION 'SELF_APPROVAL_FORBIDDEN'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(r.kind || r.subject_id::text,0));
    IF EXISTS (SELECT 1 FROM approval_decisions d JOIN approval_requests q ON q.id=d.approval_id
        WHERE q.kind=r.kind AND q.subject_id=r.subject_id AND q.approval_round=r.approval_round
          AND d.decided_by=NEW.decided_by) THEN RAISE EXCEPTION 'DUPLICATE_APPROVER'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER approval_independence BEFORE INSERT ON approval_decisions
    FOR EACH ROW EXECUTE FUNCTION approval_independence();
CREATE FUNCTION registry_immutable_economics() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.opened_at IS NOT NULL OR OLD.status IN
        ('OPEN','SUSPENDED','CLOSED','RESOLUTION_PENDING','DISPUTED','RESOLVED','VOIDED','SETTLING','SETTLED') THEN
        IF (NEW.redemption_units,NEW.min_price,NEW.max_price,NEW.tick,NEW.fee_units,
            NEW.min_order_notional,NEW.season_id,NEW.close_at,NEW.max_order_qty,
            NEW.opening_price,NEW.open_at,NEW.resolution_source_id) IS DISTINCT FROM
           (OLD.redemption_units,OLD.min_price,OLD.max_price,OLD.tick,OLD.fee_units,
            OLD.min_order_notional,OLD.season_id,OLD.close_at,OLD.max_order_qty,
            OLD.opening_price,OLD.open_at,OLD.resolution_source_id) THEN RAISE EXCEPTION 'LOCKED_AFTER_OPEN'; END IF;
        IF NEW.status IN ('DRAFT','REVIEW','APPROVED','FUNDING','CHANGES_REQUESTED','REJECTED') THEN
            RAISE EXCEPTION 'INVALID_TRANSITION'; END IF;
    ELSIF NEW.status IN ('OPEN','SUSPENDED') AND
        (NEW.redemption_units,NEW.min_price,NEW.max_price,NEW.tick,NEW.season_id,NEW.close_at) IS DISTINCT FROM
        (OLD.redemption_units,OLD.min_price,OLD.max_price,OLD.tick,OLD.season_id,OLD.close_at) THEN
        RAISE EXCEPTION 'LOCKED_AFTER_OPEN';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER registry_immutable_economics BEFORE UPDATE ON markets
    FOR EACH ROW EXECUTE FUNCTION registry_immutable_economics();
REVOKE UPDATE,DELETE,TRUNCATE ON market_terms_versions,approval_requests,approval_decisions,
    approval_transitions,approval_applications,audit_events FROM say_app;
REVOKE DELETE,TRUNCATE ON markets,categories,resolution_sources,approval_state FROM say_app;
INSERT INTO categories(id,name,icon,sort_order) VALUES
    ('00000000-0000-4000-a000-000000000101','Football','football',1),
    ('00000000-0000-4000-a000-000000000102','Music','music',2),
    ('00000000-0000-4000-a000-000000000103','Tech','laptop',3),
    ('00000000-0000-4000-a000-000000000104','Culture','culture',4),
    ('00000000-0000-4000-a000-000000000105','Weather','cloud-rain',5);
