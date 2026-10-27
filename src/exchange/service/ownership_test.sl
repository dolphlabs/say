gc struct Fake {
    register_result: bool,
    heartbeat_result: Heartbeat,
    claim_result: Claim,
    release_result: bool,
    failure: str
}

fn fake_register(f: Fake, _node: str, _name: str, _live: int) -> result[bool, str] {
    if len(f.failure) > 0 { return err(f.failure); }
    return ok(f.register_result);
}

fn fake_heartbeat(f: Fake, _node: str, _live: int, _markets: [str], _epochs: [int]) -> result[Heartbeat, str] {
    if len(f.failure) > 0 { return err(f.failure); }
    return ok(f.heartbeat_result);
}

fn fake_acquire(f: Fake, _market: str, _node: str, _lease: int) -> result[Claim, str] {
    if len(f.failure) > 0 { return err(f.failure); }
    return ok(f.claim_result);
}

fn fake_release(f: Fake, _market: str, _node: str, _epoch: int) -> result[bool, str] {
    if len(f.failure) > 0 { return err(f.failure); }
    return ok(f.release_result);
}

fn fake_ownership(f: Fake) -> Ownership[Fake] {
    return new_ownership(OwnershipStore[Fake] {
        context: f,
        register_node: fake_register,
        heartbeat: fake_heartbeat,
        acquire: fake_acquire,
        release: fake_release
    });
}

fn fake() -> Fake {
    return Fake {
        register_result: true,
        heartbeat_result: Heartbeat { node_live: true, markets: [] },
        claim_result: Claim {
            market_id: "00000000-0000-4000-a000-000000000001",
            node_id: "00000000-0000-4000-a000-000000000002",
            epoch: 2,
            acquired: true,
            renewed: false
        },
        release_result: true,
        failure: ""
    };
}

fn test_node_registration_and_lease_operations_accept_valid_identifiers() {
    let ownership = fake_ownership(fake());
    let registered = register_node(ownership, "00000000-0000-4000-a000-000000000002", "say-node", 15);
    guard let ok_register = registered else { panic("valid node rejected"); }
    assert(ok_register);
    let heartbeat_result = heartbeat(ownership, "00000000-0000-4000-a000-000000000002", 15,
        ["00000000-0000-4000-a000-000000000001"], [2]);
    guard let beat = heartbeat_result else { panic("valid heartbeat rejected"); }
    assert(beat.node_live);
    let claim_result = acquire(ownership, "00000000-0000-4000-a000-000000000001",
        "00000000-0000-4000-a000-000000000002", 10);
    guard let claim = claim_result else { panic("valid lease rejected"); }
    assert(claim.acquired && claim.epoch == 2);
    let released = release(ownership, claim.market_id, claim.node_id, claim.epoch);
    guard let did_release = released else { panic("valid release rejected"); }
    assert(did_release);
}

fn test_node_and_lease_limits_fail_before_store_calls() {
    let ownership = fake_ownership(fake());
    let bad_node = register_node(ownership, "not-a-uuid", "say-node", 15);
    if let _ok = bad_node { panic("invalid node ID accepted"); }
    else let error = err_of(bad_node) { assert(error == "INVALID_NODE"); }
    let bad_name = register_node(ownership, "00000000-0000-4000-a000-000000000002", "", 15);
    if let _ok = bad_name { panic("empty node name accepted"); }
    else let error = err_of(bad_name) { assert(error == "INVALID_NODE"); }
    let bad_ttl = acquire(ownership, "00000000-0000-4000-a000-000000000001",
        "00000000-0000-4000-a000-000000000002", 2);
    if let _ok = bad_ttl { panic("short lease accepted"); }
    else let error = err_of(bad_ttl) { assert(error == "INVALID_LEASE"); }
}

fn test_heartbeat_rejects_mismatched_or_duplicate_market_epochs() {
    let ownership = fake_ownership(fake());
    let no_epochs: [int] = [];
    let mismatched = heartbeat(ownership, "00000000-0000-4000-a000-000000000002", 15,
        ["00000000-0000-4000-a000-000000000001"], no_epochs);
    if let _ok = mismatched { panic("mismatched heartbeat accepted"); }
    else let error = err_of(mismatched) { assert(error == "INVALID_HEARTBEAT"); }
    let duplicate = heartbeat(ownership, "00000000-0000-4000-a000-000000000002", 15,
        ["00000000-0000-4000-a000-000000000001", "00000000-0000-4000-a000-000000000001"], [1, 2]);
    if let _ok = duplicate { panic("duplicate market lease accepted"); }
    else let error = err_of(duplicate) { assert(error == "INVALID_HEARTBEAT"); }
}
