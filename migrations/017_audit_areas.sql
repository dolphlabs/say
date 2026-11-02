-- 017_audit_areas.sql
-- Audit events carry an area for filtering, but no writer sets one, so every
-- event defaulted to 'Access'. The area follows from the target, so it is
-- derived once here instead of in every writer.

CREATE FUNCTION audit_event_area(p_target_type text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN lower(p_target_type) IN ('market', 'resolution_source', 'category') THEN 'Markets'
        WHEN lower(p_target_type) IN ('issuance_policy', 'trading_halt', 'reconciliation', 'ledger', 'grant', 'treasury', 'season') THEN 'Money'
        WHEN lower(p_target_type) IN ('resolution', 'dispute', 'evidence', 'settlement') THEN 'Resolution'
        WHEN lower(p_target_type) IN ('bot', 'bot_market', 'bot_params') THEN 'Bots'
        ELSE 'Access'
    END
$$;

CREATE FUNCTION audit_events_set_area() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.area IS NULL OR NEW.area = 'Access' THEN
        NEW.area := audit_event_area(NEW.target_type);
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER audit_events_area BEFORE INSERT ON audit_events
    FOR EACH ROW EXECUTE FUNCTION audit_events_set_area();

UPDATE audit_events SET area = audit_event_area(target_type)
WHERE area = 'Access' AND audit_event_area(target_type) <> 'Access';
