import "crypto";
import "timez";

pub gc struct Grant {
    amount: int,
    season_ordinal: int,
    season_ends_at: timez.Time
}

pub gc struct Policy {
    id: str,
    amount: int,
    season_cap: int,
    status: str,
    approvals: [str]
}

pub fn budget_shards() -> int {
    return 16;
}

// One grant per account per season, whatever retries or races happen.
pub fn grant_business_key(season_id: str, account_id: str) -> str {
    return "grant:" + season_id + ":" + account_id;
}

// Spreads grants over the budget rows, so concurrent grants rarely meet.
pub fn shard_of(account_id: str) -> int {
    let h = crypto.sha256(to_bytes(account_id));
    return (h[0] as int) % budget_shards();
}

// The cap split across the shards in whole grants (a shard never holds a
// fraction of one); the first shards take the remainder, one grant each.
pub fn shard_budget(cap: int, amount: int, shard: int) -> int {
    let grants = cap / amount;
    let each = grants / budget_shards();
    if shard < grants % budget_shards() {
        each = each + 1;
    }
    return each * amount;
}

pub fn grant_tx(account_id: str, season_id: str, amount: int) -> LedgerTx {
    let none_holds: [HoldOp] = [];
    return LedgerTx {
        business_key: grant_business_key(season_id, account_id),
        kind: "SEASON_GRANT",
        season_id: season_id,
        market_id: "",
        ref_type: "season",
        ref_id: season_id,
        metadata: "{}",
        entries: [free(issuance(), sedi(), 0 - amount), free(user(account_id), sedi(), amount)],
        holds: none_holds
    };
}

pub gc struct HoldInfo {
    id: str,
    owner: Owner,
    asset_key: str,
    season_id: str,
    ref_type: str,
    ref_id: str,
    status: str,
    remaining: int
}

pub fn hold_tx(owner: Owner, season_id: str, asset: str, amount: int, ref_type: str, ref_id: str,
               business_key: str, metadata: str) -> LedgerTx {
    return LedgerTx {
        business_key: business_key,
        kind: "ORDER_HOLD",
        season_id: season_id,
        market_id: "",
        ref_type: ref_type,
        ref_id: ref_id,
        metadata: metadata,
        entries: [free(owner, asset, 0 - amount), held(owner, asset, amount, new_hold())],
        holds: [HoldOp { op: "open", hold_id: "", owner: owner, asset_key: asset, amount: amount }]
    };
}

pub fn release_tx(h: HoldInfo, amount: int, business_key: str, metadata: str) -> LedgerTx {
    return LedgerTx {
        business_key: business_key,
        kind: "ORDER_RELEASE",
        season_id: h.season_id,
        market_id: "",
        ref_type: h.ref_type,
        ref_id: h.ref_id,
        metadata: metadata,
        entries: [held(h.owner, h.asset_key, 0 - amount, h.id), free(h.owner, h.asset_key, amount)],
        holds: [HoldOp { op: "release", hold_id: h.id, owner: h.owner, asset_key: h.asset_key, amount: amount }]
    };
}

// Spends `amount` of the hold into `counter`, which the caller balances
// (counterparty, collateral, fees).
pub fn consume_tx(h: HoldInfo, amount: int, kind: str, counter: [Entry], business_key: str,
                  metadata: str) -> LedgerTx {
    let entries: [Entry] = [held(h.owner, h.asset_key, 0 - amount, h.id)];
    for e in counter {
        push(entries, e);
    }
    return LedgerTx {
        business_key: business_key,
        kind: kind,
        season_id: h.season_id,
        market_id: "",
        ref_type: h.ref_type,
        ref_id: h.ref_id,
        metadata: metadata,
        entries: entries,
        holds: [HoldOp { op: "consume", hold_id: h.id, owner: h.owner, asset_key: h.asset_key, amount: amount }]
    };
}
