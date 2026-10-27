ALTER TABLE orders DROP CONSTRAINT orders_sequence_state;
ALTER TABLE orders ADD CONSTRAINT orders_sequence_state CHECK (
    (status='ADMITTED' AND accepted_seq IS NULL) OR (status<>'ADMITTED' AND accepted_seq IS NOT NULL AND accepted_seq>0));
ALTER TABLE market_commands DROP CONSTRAINT market_commands_state_shape;
ALTER TABLE market_commands ADD CONSTRAINT market_commands_state_shape CHECK (
    (state='PENDING' AND seq IS NULL AND transition IS NULL AND state_hash IS NULL AND completed_at IS NULL)
    OR (state IN ('DONE','REJECTED') AND seq IS NOT NULL AND seq>0 AND transition IS NOT NULL AND resolved_input IS NOT NULL
        AND previous_hash IS NOT NULL AND state_hash IS NOT NULL AND owner_epoch IS NOT NULL AND owner_epoch>0
        AND node_id IS NOT NULL AND executed_at IS NOT NULL AND completed_at IS NOT NULL));
ALTER TABLE outbox_events DROP CONSTRAINT runtime_outbox_audience;
ALTER TABLE outbox_events ADD CONSTRAINT runtime_outbox_audience CHECK (
    (audience='legacy' AND account_id IS NULL)
    OR (audience='market' AND market_id IS NOT NULL AND account_id IS NULL AND market_seq IS NOT NULL AND market_seq>0
        AND event_ordinal IS NOT NULL AND event_ordinal>=0 AND owner_epoch IS NOT NULL AND owner_epoch>0)
    OR (audience='account' AND account_id IS NOT NULL AND market_id IS NOT NULL AND market_seq IS NOT NULL AND market_seq>0
        AND event_ordinal IS NOT NULL AND event_ordinal>=0 AND owner_epoch IS NOT NULL AND owner_epoch>0));
ALTER TABLE market_queue_claims ADD COLUMN command_type text NOT NULL, ADD COLUMN source_key text NOT NULL;

CREATE OR REPLACE FUNCTION say_runtime_reserve(p_market uuid,p_command uuid,p_kind text,p_source text,p_start integer)
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
    INSERT INTO public.market_queue_claims(command_ref,market_id,bucket,command_type,source_key) VALUES(p_command,p_market,chosen,p_kind,p_source);
    RETURN QUERY SELECT p_command,chosen,false;
END;
$$;

CREATE OR REPLACE FUNCTION say_runtime_enqueue(p_market uuid,p_command uuid,p_kind text,p_order uuid,p_source text,p_payload jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE claim public.market_queue_claims; ordinal bigint;
BEGIN
    PERFORM pg_advisory_xact_lock_shared(73101,hashtext(p_market::text));
    SELECT * INTO claim FROM public.market_queue_claims WHERE command_ref=p_command AND market_id=p_market AND released_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SAY_QUEUE_CLAIM_REQUIRED'; END IF;
    IF claim.command_type IS DISTINCT FROM p_kind OR claim.source_key IS DISTINCT FROM p_source THEN RAISE EXCEPTION 'SAY_QUEUE_CLAIM_IDENTITY'; END IF;
    IF (p_kind='Place' AND claim.bucket>=16) OR (p_kind='Close' AND claim.bucket<>17)
       OR (p_kind NOT IN ('Place','Close') AND claim.bucket<>16) THEN RAISE EXCEPTION 'SAY_QUEUE_CLAIM_KIND'; END IF;
    INSERT INTO public.market_commands(id,market_id,command_type,payload,state,order_id,source_key,queue_bucket)
    VALUES(p_command,p_market,p_kind,p_payload,'PENDING',p_order,p_source,claim.bucket)
    RETURNING command_id INTO ordinal;
    RETURN ordinal;
END;
$$;

CREATE OR REPLACE FUNCTION say_runtime_final_guard() RETURNS trigger
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
        IF m.status<>'OPEN' OR m.close_at<=at_time THEN RAISE EXCEPTION 'SAY_ELIGIBILITY:MARKET_NOT_OPEN'; END IF;
        IF s.status<>'ACTIVE' OR s.ends_at<=at_time THEN RAISE EXCEPTION 'SAY_ELIGIBILITY:SEASON_NOT_ACTIVE'; END IF;
        IF halted IS DISTINCT FROM false THEN RAISE EXCEPTION 'SAY_ELIGIBILITY:TRADING_HALTED'; END IF;
        IF m.runtime_status NOT IN ('READY','RECOVERING') THEN RAISE EXCEPTION 'SAY_ELIGIBILITY:MARKET_DEGRADED'; END IF;
    END IF;
    RETURN NEW;
END;
$$;
