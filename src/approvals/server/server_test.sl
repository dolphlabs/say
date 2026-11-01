fn test_decision_payload_fields() {
    let decision = DecisionDto { payload_hash: "hash", note: some("approved"), reason: none };
    assert(decision.payload_hash == "hash");
    guard let note = decision.note else { panic("note missing"); }
    assert(note == "approved");
    if let reason = decision.reason { panic(reason); }
}
