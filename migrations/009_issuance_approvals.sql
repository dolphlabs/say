CREATE FUNCTION issuance_policy_payload_hash(p_policy_id uuid) RETURNS text
LANGUAGE sql STABLE STRICT AS $$
    SELECT encode(sha256(convert_to(
        jsonb_build_object('id',id,'amount',amount,'season_cap',season_cap)::text,
        'UTF8'
    )), 'hex')
    FROM issuance_policies
    WHERE id=p_policy_id
$$;
REVOKE ALL ON FUNCTION issuance_policy_payload_hash(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION issuance_policy_payload_hash(uuid) TO say_app;

CREATE INDEX approval_requests_subject_hash
    ON approval_requests(kind,subject_id,payload_hash,approval_round,slot);

WITH pending AS (
    SELECT p.id,p.proposed_by,issuance_policy_payload_hash(p.id) AS payload_hash,
           count(a.operator_id) FILTER (WHERE a.operator_id<>p.proposed_by) AS eligible_votes
    FROM issuance_policies p
    LEFT JOIN issuance_policy_approvals a ON a.policy_id=p.id
    WHERE p.status='PROPOSED'
    GROUP BY p.id
), requests AS (
    INSERT INTO approval_requests(
        kind,subject_type,subject_id,payload_hash,requested_by,approval_round,slot,reason,created_at,expires_at
    )
    SELECT 'issuance_policy','issuance_policy',p.id,p.payload_hash,p.proposed_by,1,slot,
           'Continue pending issuance policy after approval workflow migration',
           now(),now()+interval '7 days'
    FROM pending p
    CROSS JOIN LATERAL generate_series(p.eligible_votes+1,2) AS slots(slot)
    RETURNING id
)
INSERT INTO approval_state(approval_id)
SELECT id FROM requests;

REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON issuance_policy_approvals FROM say_app;
