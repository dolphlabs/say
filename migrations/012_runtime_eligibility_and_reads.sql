CREATE OR REPLACE FUNCTION say_runtime_final_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE m public.markets; o public.market_owners; n public.runtime_nodes; s public.seasons; halted boolean; at_time timestamptz;
BEGIN
    IF NEW.state='PENDING' THEN RETURN NEW; END IF;
    SELECT * INTO m FROM public.markets WHERE id=NEW.market_id FOR NO KEY UPDATE;
    SELECT * INTO n FROM public.runtime_nodes WHERE id=NEW.node_id FOR SHARE;
    SELECT * INTO o FROM public.market_owners WHERE market_id=NEW.market_id FOR SHARE;
    at_time:=clock_timestamp();
    IF n.id IS NULL OR o.market_id IS NULL OR o.node_id<>NEW.node_id OR o.epoch<>NEW.owner_epoch
       OR m.owner_epoch<>NEW.owner_epoch OR o.lease_until<=at_time OR n.live_until<=at_time
       OR m.runtime_verified_epoch<>NEW.owner_epoch OR n.draining THEN
        RAISE EXCEPTION 'SAY_OWNER_FENCED' USING ERRCODE='40001';
    END IF;
    IF m.committed_seq IS DISTINCT FROM NEW.seq OR m.rolling_hash IS DISTINCT FROM NEW.state_hash
       OR NEW.transition->>'schema' IS DISTINCT FROM 'say.transition.v1'
       OR NEW.transition->>'market_id' IS DISTINCT FROM NEW.market_id::text
       OR NEW.transition->>'season_id' IS DISTINCT FROM m.season_id::text
       OR NEW.transition->>'state_hash' IS DISTINCT FROM NEW.state_hash
       OR (NEW.transition->>'seq')::bigint IS DISTINCT FROM NEW.seq
       OR NEW.transition->>'command_ref' IS DISTINCT FROM NEW.id::text
       OR NEW.transition->>'prev_hash' IS DISTINCT FROM NEW.previous_hash
       OR NEW.transition->>'decision' IS NULL
       OR (NEW.resolved_input->>'seq')::bigint IS DISTINCT FROM NEW.seq
       OR NEW.resolved_input->>'ref' IS DISTINCT FROM NEW.id::text
       OR NEW.transition->>'command_kind' IS DISTINCT FROM NEW.resolved_input->>'kind'
       OR (NEW.resolved_input->>'kind' IS DISTINCT FROM NEW.command_type AND NOT
            (NEW.command_type='Place' AND NEW.resolved_input->>'kind'='RejectPlace')) THEN
        RAISE EXCEPTION 'SAY_TRANSITION_CHAIN_INVALID';
    END IF;
    IF NEW.command_type='Place' AND NEW.transition->>'decision'='ACCEPTED' THEN
        SELECT * INTO s FROM public.seasons WHERE id=m.season_id FOR SHARE;
        SELECT h.halted INTO halted FROM public.trading_halt h WHERE h.id=1 FOR SHARE;
        at_time:=clock_timestamp();
        IF m.status='SUSPENDED' THEN RAISE EXCEPTION 'SAY_ELIGIBILITY:MARKET_SUSPENDED'; END IF;
        IF m.status<>'OPEN' OR m.close_at<=at_time THEN RAISE EXCEPTION 'SAY_ELIGIBILITY:MARKET_NOT_OPEN'; END IF;
        IF s.status<>'ACTIVE' OR s.ends_at<=at_time THEN RAISE EXCEPTION 'SAY_ELIGIBILITY:SEASON_NOT_ACTIVE'; END IF;
        IF halted IS DISTINCT FROM false THEN RAISE EXCEPTION 'SAY_ELIGIBILITY:TRADING_HALTED'; END IF;
        IF m.runtime_status NOT IN ('READY','RECOVERING') THEN RAISE EXCEPTION 'SAY_ELIGIBILITY:MARKET_DEGRADED'; END IF;
        PERFORM id FROM public.accounts WHERE id=(NEW.resolved_input->'order'->>'account_id')::uuid
            AND status='ACTIVE' AND deleted_at IS NULL FOR SHARE;
        IF NOT FOUND THEN RAISE EXCEPTION 'SAY_ELIGIBILITY:ACCOUNT_DISABLED'; END IF;
    END IF;
    IF o.lease_until<=clock_timestamp() OR n.live_until<=clock_timestamp() THEN
        RAISE EXCEPTION 'SAY_OWNER_FENCED' USING ERRCODE='40001';
    END IF;
    RETURN NEW;
END;
$$;

CREATE INDEX idx_runtime_fills_maker_order ON fills(maker_order_id);
CREATE INDEX idx_runtime_fills_taker_order ON fills(taker_order_id);
CREATE INDEX idx_order_idempotency ON idempotency_records(order_id) WHERE order_id IS NOT NULL;
