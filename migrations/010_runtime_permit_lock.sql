CREATE FUNCTION say_runtime_lock_permit(p_market uuid,p_command uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE selected_bucket smallint;
BEGIN
    SELECT c.bucket INTO selected_bucket
    FROM public.market_queue_claims c
    WHERE c.market_id=p_market AND c.command_ref=p_command AND c.released_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SAY_QUEUE_CLAIM_LOST'; END IF;

    PERFORM 1 FROM public.market_queue_budgets b
    WHERE b.market_id=p_market AND b.bucket=selected_bucket
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SAY_QUEUE_BUDGET_MISSING'; END IF;
    RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION say_runtime_lock_permit(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION say_runtime_lock_permit(uuid,uuid) TO say_app;
