DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM orders) OR EXISTS (SELECT 1 FROM market_commands)
       OR EXISTS (SELECT 1 FROM fills) OR EXISTS (SELECT 1 FROM market_snapshots) THEN
        RAISE EXCEPTION 'Runtime migration requires verified legacy order/command/fill/snapshot conversion';
    END IF;
END;
$$;

ALTER TABLE markets
    ADD COLUMN rolling_hash text CHECK (rolling_hash ~ '^[0-9a-f]{64}$'),
    ADD COLUMN issued_pairs bigint NOT NULL DEFAULT 0 CHECK (issued_pairs >= 0),
    ADD COLUMN runtime_status text NOT NULL DEFAULT 'RECOVERING'
        CHECK (runtime_status IN ('RECOVERING','READY','DEGRADED','DRAINING','STOPPED')),
    ADD COLUMN runtime_reason text,
    ADD COLUMN runtime_verified_epoch bigint NOT NULL DEFAULT 0 CHECK (runtime_verified_epoch >= 0),
    ADD COLUMN runtime_startup_frontier bigint,
    ADD COLUMN market_slippage_ticks bigint NOT NULL DEFAULT 3 CHECK (market_slippage_ticks BETWEEN 0 AND 1000),
    ADD COLUMN runtime_changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    ADD CONSTRAINT market_runtime_sequences CHECK (committed_seq >= 0 AND book_seq >= 0 AND book_seq <= committed_seq),
    ADD CONSTRAINT market_runtime_verified_epoch CHECK (runtime_verified_epoch <= owner_epoch);
CREATE INDEX idx_markets_runtime ON markets(runtime_status, id);

ALTER TABLE orders DROP CONSTRAINT orders_status_check;
ALTER TABLE orders
    ADD CONSTRAINT orders_status_check CHECK (status IN ('ADMITTED','OPEN','PARTIAL','FILLED','CANCELLED','REJECTED','EXPIRED')),
    ADD COLUMN season_id uuid NOT NULL REFERENCES seasons(id),
    ADD COLUMN owner_kind text NOT NULL CHECK (owner_kind IN ('user','bot')),
    ADD COLUMN owner_group uuid,
    ADD COLUMN sedi_hold_id uuid NOT NULL REFERENCES holds(id),
    ADD COLUMN share_hold_id uuid REFERENCES holds(id),
    ADD COLUMN sedi_original bigint NOT NULL CHECK (sedi_original > 0),
    ADD COLUMN sedi_consumed bigint NOT NULL DEFAULT 0 CHECK (sedi_consumed >= 0),
    ADD COLUMN sedi_released bigint NOT NULL DEFAULT 0 CHECK (sedi_released >= 0),
    ADD COLUMN shares_original bigint NOT NULL DEFAULT 0 CHECK (shares_original >= 0),
    ADD COLUMN shares_consumed bigint NOT NULL DEFAULT 0 CHECK (shares_consumed >= 0),
    ADD COLUMN shares_released bigint NOT NULL DEFAULT 0 CHECK (shares_released >= 0),
    ADD COLUMN filled_qty bigint NOT NULL DEFAULT 0 CHECK (filled_qty >= 0),
    ADD COLUMN cancelled_qty bigint NOT NULL DEFAULT 0 CHECK (cancelled_qty >= 0),
    ADD COLUMN revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    ADD COLUMN original_intent jsonb NOT NULL,
    ADD COLUMN committed_result jsonb,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    ADD CONSTRAINT orders_quantities CHECK (remaining_qty::numeric + filled_qty + cancelled_qty = original_qty),
    ADD CONSTRAINT orders_sedi_budget CHECK (sedi_consumed::numeric + sedi_released <= sedi_original),
    ADD CONSTRAINT orders_share_budget CHECK (shares_consumed::numeric + shares_released <= shares_original),
    ADD CONSTRAINT orders_hold_shape CHECK ((side='BUY' AND share_hold_id IS NULL AND shares_original=0)
        OR (side='SELL' AND share_hold_id IS NOT NULL AND shares_original=original_qty)),
    ADD CONSTRAINT orders_sequence_state CHECK ((status='ADMITTED' AND accepted_seq IS NULL)
        OR (status<>'ADMITTED' AND accepted_seq>0));
CREATE INDEX idx_orders_season ON orders(season_id);
CREATE INDEX idx_orders_sedi_hold ON orders(sedi_hold_id);
CREATE INDEX idx_orders_share_hold ON orders(share_hold_id) WHERE share_hold_id IS NOT NULL;
CREATE INDEX idx_orders_private ON orders(account_id, created_at DESC, id DESC);
CREATE INDEX idx_orders_live ON orders(market_id, accepted_seq, id) WHERE status IN ('ADMITTED','OPEN','PARTIAL');

CREATE TABLE runtime_nodes (
    id uuid PRIMARY KEY,
    name text NOT NULL,
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    heartbeat_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    live_until timestamptz NOT NULL,
    draining boolean NOT NULL DEFAULT false
);
CREATE INDEX idx_runtime_nodes_live ON runtime_nodes(live_until, id);
CREATE TABLE market_owners (
    market_id uuid PRIMARY KEY REFERENCES markets(id),
    node_id uuid NOT NULL REFERENCES runtime_nodes(id),
    epoch bigint NOT NULL CHECK (epoch > 0),
    lease_until timestamptz NOT NULL,
    acquired_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    renewed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX idx_market_owners_node ON market_owners(node_id, lease_until);
CREATE INDEX idx_market_owners_expiry ON market_owners(lease_until, market_id);

CREATE TABLE market_queue_budgets (
    market_id uuid NOT NULL REFERENCES markets(id),
    bucket smallint NOT NULL CHECK (bucket BETWEEN 0 AND 17),
    capacity integer NOT NULL CHECK (capacity > 0),
    remaining integer NOT NULL CHECK (remaining >= 0 AND remaining <= capacity),
    PRIMARY KEY (market_id, bucket)
);

ALTER TABLE market_commands DROP CONSTRAINT market_commands_state_check;
ALTER TABLE market_commands ALTER COLUMN seq DROP NOT NULL;
ALTER TABLE market_commands
    ADD COLUMN command_id bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
    ADD COLUMN order_id uuid REFERENCES orders(id),
    ADD COLUMN source_key text,
    ADD COLUMN queue_bucket smallint NOT NULL,
    ADD COLUMN resolved_input jsonb,
    ADD COLUMN transition jsonb,
    ADD COLUMN previous_hash text CHECK (previous_hash ~ '^[0-9a-f]{64}$'),
    ADD COLUMN state_hash text CHECK (state_hash ~ '^[0-9a-f]{64}$'),
    ADD COLUMN owner_epoch bigint,
    ADD COLUMN node_id uuid REFERENCES runtime_nodes(id),
    ADD COLUMN executed_at timestamptz,
    ADD COLUMN completed_at timestamptz,
    ADD CONSTRAINT market_commands_state_check CHECK (state IN ('PENDING','DONE','REJECTED')),
    ADD CONSTRAINT market_commands_kind CHECK (command_type IN ('Place','Cancel','CancelAll','Suspend','Resume','Close','Snapshot')),
    ADD CONSTRAINT market_commands_state_shape CHECK (
        (state='PENDING' AND seq IS NULL AND transition IS NULL AND state_hash IS NULL AND completed_at IS NULL)
        OR (state IN ('DONE','REJECTED') AND seq>0 AND transition IS NOT NULL AND resolved_input IS NOT NULL
            AND previous_hash IS NOT NULL AND state_hash IS NOT NULL AND owner_epoch>0 AND node_id IS NOT NULL
            AND executed_at IS NOT NULL AND completed_at IS NOT NULL)),
    ADD CONSTRAINT market_commands_order_shape CHECK ((command_type IN ('Place','Cancel') AND order_id IS NOT NULL)
        OR (command_type NOT IN ('Place','Cancel') AND order_id IS NULL)),
    ADD CONSTRAINT market_commands_budget FOREIGN KEY (market_id,queue_bucket) REFERENCES market_queue_budgets(market_id,bucket),
    ADD CONSTRAINT market_commands_claim_identity UNIQUE(id,market_id,queue_bucket);
CREATE INDEX idx_market_commands_pending ON market_commands(market_id,command_id) WHERE state='PENDING';
CREATE INDEX idx_market_commands_order ON market_commands(order_id) WHERE order_id IS NOT NULL;
CREATE INDEX idx_market_commands_node ON market_commands(node_id) WHERE node_id IS NOT NULL;
CREATE UNIQUE INDEX idx_market_commands_source ON market_commands(market_id,source_key) WHERE source_key IS NOT NULL;
CREATE UNIQUE INDEX idx_market_commands_pending_cancel ON market_commands(order_id) WHERE command_type='Cancel' AND state='PENDING';

CREATE TABLE market_queue_claims (
    command_ref uuid PRIMARY KEY,
    market_id uuid NOT NULL,
    bucket smallint NOT NULL,
    claimed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    released_at timestamptz,
    UNIQUE(command_ref,market_id,bucket),
    FOREIGN KEY(market_id,bucket) REFERENCES market_queue_budgets(market_id,bucket),
    FOREIGN KEY(command_ref,market_id,bucket) REFERENCES market_commands(id,market_id,queue_bucket) DEFERRABLE INITIALLY DEFERRED
);
ALTER TABLE market_commands ADD CONSTRAINT market_commands_claim
    FOREIGN KEY(id,market_id,queue_bucket) REFERENCES market_queue_claims(command_ref,market_id,bucket) DEFERRABLE INITIALLY DEFERRED;
CREATE INDEX idx_queue_claims_live ON market_queue_claims(market_id,bucket) WHERE released_at IS NULL;

CREATE FUNCTION say_runtime_prepare_queue(p_market uuid,p_pending integer,p_controls integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE i integer; n integer;
BEGIN
    IF p_pending<1 OR p_pending>100000 OR p_controls<1 OR p_controls>10000 THEN
        RAISE EXCEPTION 'SAY_QUEUE_CONFIG_INVALID';
    END IF;
    FOR i IN 0..15 LOOP
        n := p_pending/16 + CASE WHEN i < p_pending%16 THEN 1 ELSE 0 END;
        IF n>0 THEN
            INSERT INTO public.market_queue_budgets(market_id,bucket,capacity,remaining)
            VALUES(p_market,i,n,n) ON CONFLICT DO NOTHING;
        END IF;
    END LOOP;
    INSERT INTO public.market_queue_budgets(market_id,bucket,capacity,remaining)
    VALUES(p_market,16,p_controls,p_controls),(p_market,17,1,1) ON CONFLICT DO NOTHING;
    IF (SELECT sum(capacity) FROM public.market_queue_budgets WHERE market_id=p_market AND bucket<16)<>p_pending
       OR (SELECT capacity FROM public.market_queue_budgets WHERE market_id=p_market AND bucket=16)<>p_controls THEN
        RAISE EXCEPTION 'SAY_QUEUE_CONFIG_MISMATCH';
    END IF;
END;
$$;

CREATE FUNCTION say_runtime_reserve(p_market uuid,p_command uuid,p_kind text,p_source text,p_start integer)
RETURNS TABLE(command_ref uuid,bucket smallint,existing boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE found_command public.market_commands; chosen smallint; i integer;
BEGIN
    IF p_kind NOT IN ('Place','Cancel','CancelAll','Suspend','Resume','Close','Snapshot')
       OR p_source IS NULL OR length(p_source)>200 OR length(p_source)=0 OR p_start<0 OR p_start>15 THEN
        RAISE EXCEPTION 'SAY_COMMAND_INVALID';
    END IF;
    PERFORM pg_advisory_xact_lock_shared(73101,hashtext(p_market::text));
    PERFORM pg_advisory_xact_lock(73102,hashtext(p_market::text||':'||p_source));
    SELECT * INTO found_command FROM public.market_commands WHERE market_id=p_market AND source_key=p_source;
    IF FOUND THEN
        IF found_command.command_type<>p_kind THEN RAISE EXCEPTION 'SAY_COMMAND_CONFLICT'; END IF;
        RETURN QUERY SELECT found_command.id,found_command.queue_bucket,true;
        RETURN;
    END IF;
    chosen := NULL;
    IF p_kind='Place' THEN
        FOR i IN 0..15 LOOP
            UPDATE public.market_queue_budgets b SET remaining=remaining-1
            WHERE b.market_id=p_market AND b.bucket=(p_start+i)%16 AND b.remaining>0
            RETURNING b.bucket INTO chosen;
            EXIT WHEN chosen IS NOT NULL;
        END LOOP;
    ELSE
        UPDATE public.market_queue_budgets b SET remaining=remaining-1
        WHERE b.market_id=p_market AND b.bucket=CASE WHEN p_kind='Close' THEN 17 ELSE 16 END AND b.remaining>0
        RETURNING b.bucket INTO chosen;
    END IF;
    IF chosen IS NULL THEN RAISE EXCEPTION 'SAY_QUEUE_FULL'; END IF;
    INSERT INTO public.market_queue_claims(command_ref,market_id,bucket) VALUES(p_command,p_market,chosen);
    RETURN QUERY SELECT p_command,chosen,false;
END;
$$;

CREATE FUNCTION say_runtime_enqueue(p_market uuid,p_command uuid,p_kind text,p_order uuid,p_source text,p_payload jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE claim public.market_queue_claims; ordinal bigint;
BEGIN
    PERFORM pg_advisory_xact_lock_shared(73101,hashtext(p_market::text));
    SELECT * INTO claim FROM public.market_queue_claims WHERE command_ref=p_command AND market_id=p_market AND released_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SAY_QUEUE_CLAIM_REQUIRED'; END IF;
    IF (p_kind='Place' AND claim.bucket>=16) OR (p_kind='Close' AND claim.bucket<>17)
       OR (p_kind NOT IN ('Place','Close') AND claim.bucket<>16) THEN RAISE EXCEPTION 'SAY_QUEUE_CLAIM_KIND'; END IF;
    INSERT INTO public.market_commands(id,market_id,command_type,payload,state,order_id,source_key,queue_bucket)
    VALUES(p_command,p_market,p_kind,p_payload,'PENDING',p_order,p_source,claim.bucket)
    RETURNING command_id INTO ordinal;
    RETURN ordinal;
END;
$$;

CREATE FUNCTION say_runtime_command_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.state<>'PENDING' OR ROW(NEW.id,NEW.market_id,NEW.command_id,NEW.command_type,NEW.payload,NEW.order_id,NEW.source_key,NEW.queue_bucket,NEW.created_at)
        IS DISTINCT FROM ROW(OLD.id,OLD.market_id,OLD.command_id,OLD.command_type,OLD.payload,OLD.order_id,OLD.source_key,OLD.queue_bucket,OLD.created_at) THEN
        RAISE EXCEPTION 'SAY_COMMAND_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER market_command_immutable BEFORE UPDATE ON market_commands FOR EACH ROW EXECUTE FUNCTION say_runtime_command_immutable();

CREATE FUNCTION say_runtime_return_permit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE returned integer;
BEGIN
    IF OLD.state='PENDING' AND NEW.state<>'PENDING' THEN
        UPDATE public.market_queue_claims SET released_at=clock_timestamp() WHERE command_ref=NEW.id AND released_at IS NULL;
        GET DIAGNOSTICS returned=ROW_COUNT;
        IF returned<>1 THEN RAISE EXCEPTION 'SAY_QUEUE_CLAIM_LOST'; END IF;
        UPDATE public.market_queue_budgets SET remaining=remaining+1 WHERE market_id=NEW.market_id AND bucket=NEW.queue_bucket AND remaining<capacity;
        GET DIAGNOSTICS returned=ROW_COUNT;
        IF returned<>1 THEN RAISE EXCEPTION 'SAY_QUEUE_RETURN_INVALID'; END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER market_command_return_permit AFTER UPDATE ON market_commands FOR EACH ROW EXECUTE FUNCTION say_runtime_return_permit();

CREATE FUNCTION say_runtime_final_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE m public.markets; o public.market_owners; n public.runtime_nodes; s public.seasons; halted boolean; at_time timestamptz;
BEGIN
    IF NEW.state='PENDING' THEN RETURN NEW; END IF;
    SELECT * INTO m FROM public.markets WHERE id=NEW.market_id FOR UPDATE;
    SELECT * INTO n FROM public.runtime_nodes WHERE id=NEW.node_id FOR SHARE;
    SELECT * INTO o FROM public.market_owners WHERE market_id=NEW.market_id FOR SHARE;
    at_time:=clock_timestamp();
    IF n.id IS NULL OR o.market_id IS NULL OR o.node_id<>NEW.node_id OR o.epoch<>NEW.owner_epoch
       OR m.owner_epoch<>NEW.owner_epoch OR o.lease_until<=at_time OR n.live_until<=at_time
       OR m.runtime_verified_epoch<>NEW.owner_epoch THEN
        RAISE EXCEPTION 'SAY_OWNER_FENCED' USING ERRCODE='40001';
    END IF;
    IF m.committed_seq<>NEW.seq OR m.rolling_hash<>NEW.state_hash OR NEW.transition->>'state_hash'<>NEW.state_hash
       OR (NEW.transition->>'seq')::bigint<>NEW.seq OR NEW.transition->>'prev_hash'<>NEW.previous_hash THEN
        RAISE EXCEPTION 'SAY_TRANSITION_CHAIN_INVALID';
    END IF;
    IF NEW.command_type='Place' AND NEW.transition->>'decision'='ACCEPTED' THEN
        SELECT * INTO s FROM public.seasons WHERE id=m.season_id FOR SHARE;
        SELECT h.halted INTO halted FROM public.trading_halt h WHERE h.id=1 FOR SHARE;
        at_time:=clock_timestamp();
        IF m.status<>'OPEN' OR m.close_at<=at_time THEN RAISE EXCEPTION 'SAY_ELIGIBILITY:MARKET_NOT_OPEN'; END IF;
        IF s.status<>'ACTIVE' OR s.ends_at<=at_time THEN RAISE EXCEPTION 'SAY_ELIGIBILITY:SEASON_NOT_ACTIVE'; END IF;
        IF halted THEN RAISE EXCEPTION 'SAY_ELIGIBILITY:TRADING_HALTED'; END IF;
        IF m.runtime_status NOT IN ('READY','RECOVERING') THEN RAISE EXCEPTION 'SAY_ELIGIBILITY:MARKET_DEGRADED'; END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE CONSTRAINT TRIGGER market_command_final_guard AFTER UPDATE ON market_commands
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION say_runtime_final_guard();

ALTER TABLE fills DROP CONSTRAINT fills_mode_check;
ALTER TABLE fills
    ADD CONSTRAINT fills_mode_check CHECK (mode IN ('TRANSFER_YES','TRANSFER_NO','MINT','MERGE')),
    ADD COLUMN maker_account_id uuid NOT NULL REFERENCES accounts(id),
    ADD COLUMN taker_account_id uuid NOT NULL REFERENCES accounts(id),
    ADD COLUMN maker_outcome text NOT NULL CHECK (maker_outcome IN ('YES','NO')),
    ADD COLUMN taker_outcome text NOT NULL CHECK (taker_outcome IN ('YES','NO')),
    ADD COLUMN maker_side text NOT NULL CHECK (maker_side IN ('BUY','SELL')),
    ADD COLUMN taker_side text NOT NULL CHECK (taker_side IN ('BUY','SELL')),
    ADD COLUMN aggressor text NOT NULL CHECK (aggressor IN ('bid','ask')),
    ADD COLUMN executed_at timestamptz NOT NULL DEFAULT clock_timestamp();
CREATE INDEX idx_fills_maker_account ON fills(maker_account_id,executed_at);
CREATE INDEX idx_fills_taker_account ON fills(taker_account_id,executed_at);
CREATE INDEX idx_fills_recent ON fills(market_id,execution_seq DESC,fill_index DESC);

CREATE TABLE positions (
    account_id uuid NOT NULL REFERENCES accounts(id),
    market_id uuid NOT NULL REFERENCES markets(id),
    season_id uuid NOT NULL REFERENCES seasons(id),
    outcome text NOT NULL CHECK (outcome IN ('YES','NO')),
    qty bigint NOT NULL DEFAULT 0 CHECK (qty>=0),
    cost_basis bigint NOT NULL DEFAULT 0 CHECK (cost_basis>=0),
    realized_pnl bigint NOT NULL DEFAULT 0,
    fees_paid bigint NOT NULL DEFAULT 0 CHECK (fees_paid>=0),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision>0),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY(account_id,market_id,season_id,outcome),
    CHECK (qty<>0 OR cost_basis=0)
);
CREATE INDEX idx_positions_market ON positions(market_id,account_id,outcome);
CREATE INDEX idx_positions_season ON positions(season_id,account_id);
CREATE TABLE market_participants (
    market_id uuid NOT NULL REFERENCES markets(id),
    account_id uuid NOT NULL REFERENCES accounts(id),
    first_seq bigint NOT NULL CHECK (first_seq>0),
    first_at timestamptz NOT NULL,
    PRIMARY KEY(market_id,account_id)
);
CREATE INDEX idx_participants_account ON market_participants(account_id,market_id);
CREATE TABLE market_price_points (
    market_id uuid NOT NULL REFERENCES markets(id),
    minute_at timestamptz NOT NULL,
    open_price bigint NOT NULL,
    high_price bigint NOT NULL,
    low_price bigint NOT NULL,
    close_price bigint NOT NULL,
    volume_units bigint NOT NULL CHECK (volume_units>=0),
    first_seq bigint NOT NULL,
    first_index integer NOT NULL,
    last_seq bigint NOT NULL,
    last_index integer NOT NULL,
    PRIMARY KEY(market_id,minute_at),
    CHECK (low_price>0 AND low_price<=open_price AND low_price<=close_price AND high_price>=open_price AND high_price>=close_price)
);
CREATE TABLE market_book_views (
    market_id uuid PRIMARY KEY REFERENCES markets(id),
    owner_epoch bigint NOT NULL CHECK (owner_epoch>0),
    committed_seq bigint NOT NULL CHECK (committed_seq>=0),
    book_seq bigint NOT NULL CHECK (book_seq>=0 AND book_seq<=committed_seq),
    payload jsonb NOT NULL,
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE market_snapshots
    ADD COLUMN schema_version integer NOT NULL DEFAULT 1 CHECK (schema_version=1),
    ADD COLUMN owner_epoch bigint NOT NULL CHECK (owner_epoch>0),
    ADD COLUMN full_hash text NOT NULL CHECK (full_hash ~ '^[0-9a-f]{64}$');

ALTER TABLE outbox_events
    ADD COLUMN audience text NOT NULL DEFAULT 'legacy' CHECK (audience IN ('legacy','market','account')),
    ADD COLUMN account_id uuid REFERENCES accounts(id),
    ADD COLUMN event_ordinal integer,
    ADD COLUMN owner_epoch bigint,
    ADD COLUMN claim_node uuid,
    ADD COLUMN claim_until timestamptz,
    ADD COLUMN next_attempt_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    ADD CONSTRAINT runtime_outbox_audience CHECK ((audience='legacy' AND account_id IS NULL)
        OR (audience='market' AND market_id IS NOT NULL AND account_id IS NULL AND market_seq>0 AND event_ordinal>=0 AND owner_epoch>0)
        OR (audience='account' AND account_id IS NOT NULL AND market_id IS NOT NULL AND market_seq>0 AND event_ordinal>=0 AND owner_epoch>0));
CREATE INDEX idx_runtime_outbox_head ON outbox_events(market_id,market_seq,event_ordinal) WHERE audience<>'legacy' AND published_at IS NULL;
CREATE INDEX idx_runtime_outbox_account ON outbox_events(account_id,created_at) WHERE account_id IS NOT NULL;
CREATE UNIQUE INDEX idx_runtime_outbox_identity ON outbox_events(market_id,market_seq,event_ordinal) WHERE audience<>'legacy';

REVOKE INSERT,DELETE,TRUNCATE ON market_commands FROM say_app;
REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON market_queue_claims,market_queue_budgets FROM say_app;
REVOKE UPDATE,DELETE,TRUNCATE ON fills,market_snapshots FROM say_app;
REVOKE DELETE,TRUNCATE ON orders,positions,market_participants,market_price_points,market_book_views,market_owners,runtime_nodes FROM say_app;
REVOKE ALL ON FUNCTION say_runtime_prepare_queue(uuid,integer,integer),say_runtime_reserve(uuid,uuid,text,text,integer),
    say_runtime_enqueue(uuid,uuid,text,uuid,text,jsonb),say_runtime_return_permit() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION say_runtime_prepare_queue(uuid,integer,integer),say_runtime_reserve(uuid,uuid,text,text,integer),
    say_runtime_enqueue(uuid,uuid,text,uuid,text,jsonb) TO say_app;
