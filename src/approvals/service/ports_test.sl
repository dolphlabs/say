fn test_request_preserves_subject_hash_and_slot() {
    let r = Request { id: "a", kind: "market_open", subject_type: "market", subject_id: "m", payload_hash: "hash",
        requested_by: "author", approval_round: 3, slot: 1, status: "pending", version: 1, expires_at: 100 };
    assert(r.payload_hash == "hash" && r.approval_round == 3 && r.slot == 1);
}
