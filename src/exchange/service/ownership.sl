import "../domain" as core;

pub gc struct Ownership[C] {
    store: OwnershipStore[C]
}

pub fn new_ownership[C](store: OwnershipStore[C]) -> Ownership[C] {
    return Ownership[C] { store: store };
}

pub fn register_node[C](ownership: Ownership[C], node_id: str, name: str, live_seconds: int) -> result[bool, str] {
    if !valid_uuid(node_id) || len(name) < 1 || len(name) > 128 || live_seconds < 3 || live_seconds > 60 {
        return err("INVALID_NODE");
    }
    let register = ownership.store.register_node;
    return register(ownership.store.context, node_id, name, live_seconds);
}

pub fn heartbeat[C](ownership: Ownership[C], node_id: str, live_seconds: int, market_ids: [str], epochs: [int]) -> result[Heartbeat, str] {
    if !valid_uuid(node_id) || live_seconds < 3 || live_seconds > 60 ||
       len(market_ids) != len(epochs) || len(market_ids) > 500 {
        return err("INVALID_HEARTBEAT");
    }
    for i in 0..len(market_ids) {
        if !valid_uuid(market_ids[i]) || epochs[i] < 1 {
            return err("INVALID_HEARTBEAT");
        }
        for j in 0..i {
            if market_ids[i] == market_ids[j] {
                return err("INVALID_HEARTBEAT");
            }
        }
    }
    let beat = ownership.store.heartbeat;
    return beat(ownership.store.context, node_id, live_seconds, market_ids, epochs);
}

pub fn acquire[C](ownership: Ownership[C], market_id: str, node_id: str, lease_seconds: int) -> result[Claim, str] {
    if !valid_uuid(market_id) || !valid_uuid(node_id) || lease_seconds < 3 || lease_seconds > 30 {
        return err("INVALID_LEASE");
    }
    let take = ownership.store.acquire;
    return take(ownership.store.context, market_id, node_id, lease_seconds);
}

pub fn release[C](ownership: Ownership[C], market_id: str, node_id: str, epoch: int) -> result[bool, str] {
    if !valid_uuid(market_id) || !valid_uuid(node_id) || epoch < 1 {
        return err("INVALID_LEASE");
    }
    let relinquish = ownership.store.release;
    return relinquish(ownership.store.context, market_id, node_id, epoch);
}

fn valid_uuid(value: str) -> bool {
    let scratch = core.byte_writer(36);
    return core.canonical_uuid(value, scratch.data);
}
