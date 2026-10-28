import "builder";
import "crypto";
import "strings";

// kind is "user", "bot" or "system"; id is the account uuid, or
// "system:<name>" for platform accounts.
pub gc struct Owner {
    kind: str,
    id: str
}

pub fn user(account_id: str) -> Owner {
    return Owner { kind: "user", id: account_id };
}

pub fn bot(account_id: str) -> Owner {
    return Owner { kind: "bot", id: account_id };
}

pub fn system(name: str) -> Owner {
    return Owner { kind: "system", id: "system:" + name };
}

pub fn issuance() -> Owner { return system("issuance"); }
pub fn fees() -> Owner { return system("fees"); }
pub fn treasury() -> Owner { return system("treasury"); }
pub fn collateral(market_id: str) -> Owner { return system("collateral:" + market_id); }
pub fn shares(market_id: str) -> Owner { return system("shares:" + market_id); }

pub fn new_hold() -> str {
    return "new";
}

// `hold` ties a held-bucket entry to a hold: new_hold() for the hold this
// posting opens, the hold's id for one it consumes or releases.
pub gc struct Entry {
    owner: Owner,
    asset_key: str,
    bucket: str,
    delta: int,
    hold: str
}

pub fn free(owner: Owner, asset: str, delta: int) -> Entry {
    return Entry { owner: owner, asset_key: asset, bucket: "free", delta: delta, hold: "" };
}

pub fn held(owner: Owner, asset: str, delta: int, hold: str) -> Entry {
    return Entry { owner: owner, asset_key: asset, bucket: "held", delta: delta, hold: hold };
}

// op is "open", "consume" or "release". An open names its wallet by owner
// and asset; the others name the hold.
pub gc struct HoldOp {
    op: str,
    hold_id: str,
    owner: Owner,
    asset_key: str,
    amount: int
}

pub gc struct LedgerTx {
    business_key: str,
    kind: str,
    season_id: str,
    market_id: str,
    ref_type: str,
    ref_id: str,
    metadata: str,
    entries: [Entry],
    holds: [HoldOp]
}

pub gc struct Posted {
    tx_id: int,
    public_id: str,
    replayed: bool,
    hold_ids: [str]
}

pub fn kinds() -> [str] {
    return ["SEASON_GRANT", "ORDER_HOLD", "ORDER_RELEASE", "FILL", "FEE", "MINT", "MERGE", "PAYOUT",
            "BOT_FUNDING", "BOT_ALLOCATION", "BOT_SWEEP", "ADJUSTMENT", "VOID_REFUND", "FEE_REFUND", "VOID_COLLATERAL_RELEASE"];
}

fn known_kind(k: str) -> bool {
    for x in kinds() {
        if x == k {
            return true;
        }
    }
    return false;
}

fn valid_owner(o: Owner) -> bool {
    if o.kind == "system" {
        return strings.has_prefix(o.id, "system:") && len(o.id) > 7;
    }
    return (o.kind == "user" || o.kind == "bot") && is_uuid(o.id);
}

fn malformed(detail: str) -> opt[LedgerError] {
    return some(failure(Fault.Malformed, detail));
}

gc struct AssetSum {
    asset: str,
    sum: int
}

fn held_sum(entries: [Entry], owner: Owner, asset: str, hold: str) -> int {
    let n = 0;
    for e in entries {
        if e.bucket == "held" && e.hold == hold && e.owner.id == owner.id && e.asset_key == asset {
            n = n + e.delta;
        }
    }
    return n;
}

fn hold_sum(entries: [Entry], hold: str) -> int {
    let n = 0;
    for e in entries {
        if e.bucket == "held" && e.hold == hold {
            n = n + e.delta;
        }
    }
    return n;
}

fn check_holds(tx: LedgerTx) -> opt[LedgerError] {
    let opened: [str] = [];
    for h in tx.holds {
        if h.amount <= 0 {
            return malformed("hold amount must be positive");
        }
        if h.op == "open" {
            if h.owner.kind == "system" || !valid_owner(h.owner) {
                return malformed("only user and bot wallets hold funds");
            }
            let key = h.owner.id + "|" + h.asset_key;
            for k in opened {
                if k == key {
                    return malformed("one hold per wallet per posting");
                }
            }
            push(opened, key);
            if held_sum(tx.entries, h.owner, h.asset_key, new_hold()) != h.amount {
                return malformed("the held entries do not match the hold opened");
            }
        } else if h.op == "consume" || h.op == "release" {
            if len(h.hold_id) == 0 || h.hold_id == new_hold() {
                return malformed(h.op + " needs a hold id");
            }
            if hold_sum(tx.entries, h.hold_id) != 0 - h.amount {
                return malformed("the held entries do not match the " + h.op + " of " + h.hold_id);
            }
        } else {
            return malformed("unknown hold op " + h.op);
        }
    }
    for e in tx.entries {
        if e.bucket != "held" {
            continue;
        }
        if len(e.hold) == 0 {
            return malformed("a held-bucket entry must name its hold");
        }
        let covered = false;
        for h in tx.holds {
            if (e.hold == new_hold() && h.op == "open" && h.owner.id == e.owner.id && h.asset_key == e.asset_key) ||
               (e.hold != new_hold() && h.hold_id == e.hold) {
                covered = true;
            }
        }
        if !covered {
            return malformed("held entry for " + e.owner.id + " has no hold op");
        }
    }
    return none;
}

// Rule 1 of post(), before any I/O: shape, then per-asset balance with
// checked sums.
pub fn validate(tx: LedgerTx) -> opt[LedgerError] {
    if len(tx.business_key) == 0 || len(tx.business_key) > 200 {
        return malformed("business_key must be 1-200 bytes");
    }
    if !known_kind(tx.kind) {
        return malformed("unknown kind " + tx.kind);
    }
    if !is_uuid(tx.season_id) {
        return malformed("season_id must be a uuid");
    }
    if len(tx.market_id) > 0 && !is_uuid(tx.market_id) {
        return malformed("market_id must be a uuid");
    }
    if !strings.has_prefix(tx.metadata, "{") {
        return malformed("metadata must be a JSON object");
    }
    if len(tx.entries) < 2 {
        return malformed("a posting needs at least two entries");
    }
    let sums: [AssetSum] = [];
    for e in tx.entries {
        if e.delta == 0 {
            return malformed("zero delta for " + e.owner.id);
        }
        if !valid_owner(e.owner) {
            return malformed("bad owner " + e.owner.kind + " " + e.owner.id);
        }
        if !valid_asset(e.asset_key) {
            return malformed("bad asset " + e.asset_key);
        }
        if e.bucket != "free" && e.bucket != "held" {
            return malformed("bad bucket " + e.bucket);
        }
        if e.owner.kind == "system" && (e.bucket != "free" || len(e.hold) > 0) {
            return malformed("system wallets have only a free bucket");
        }
        let found = false;
        for s in sums {
            if s.asset == e.asset_key {
                guard let n = checked_add(s.sum, e.delta) else {
                    return some(failure(Fault.Overflow, "sum of " + e.asset_key));
                }
                s.sum = n;
                found = true;
            }
        }
        if !found {
            push(sums, AssetSum { asset: e.asset_key, sum: e.delta });
        }
    }
    for s in sums {
        if s.sum != 0 {
            let u = failure(Fault.Unbalanced, s.asset + " sums to " + to_str(s.sum));
            u.asset = s.asset;
            u.needed = s.sum;
            return some(u);
        }
    }
    return check_holds(tx);
}

fn entry_key(e: Entry) -> str {
    return e.owner.id + "|" + e.asset_key + "|" + e.bucket + "|" + e.hold;
}

fn entry_before(a: Entry, b: Entry) -> bool {
    let ka = entry_key(a);
    let kb = entry_key(b);
    if ka != kb {
        return ka < kb;
    }
    return a.delta < b.delta;
}

pub fn sorted_entries(xs: [Entry]) -> [Entry] {
    let out: [Entry] = [];
    for x in xs {
        push(out, x);
    }
    for i in 1..len(out) {
        let j = i;
        while j > 0 && entry_before(out[j], out[j - 1]) {
            let t = out[j];
            out[j] = out[j - 1];
            out[j - 1] = t;
            j = j - 1;
        }
    }
    return out;
}

fn hold_key(h: HoldOp) -> str {
    return h.op + "|" + h.hold_id + "|" + h.owner.id + "|" + h.asset_key + "|" + to_str(h.amount);
}

fn sorted_holds(xs: [HoldOp]) -> [HoldOp] {
    let out: [HoldOp] = [];
    for x in xs {
        push(out, x);
    }
    for i in 1..len(out) {
        let j = i;
        while j > 0 && hold_key(out[j]) < hold_key(out[j - 1]) {
            let t = out[j];
            out[j] = out[j - 1];
            out[j - 1] = t;
            j = j - 1;
        }
    }
    return out;
}

fn field(b: builder.Bytes, s: str) {
    b.write_str(to_str(len(s)));
    b.write_str(":");
    b.write_str(s);
}

// What makes two postings "the same" for idempotency: the money movement,
// in a fixed order, each field length-prefixed so none can bleed into the
// next. metadata is display text and stays out.
pub fn canonical_payload(tx: LedgerTx) -> bytes {
    let b = builder.new_bytes();
    field(b, "say.ledger.v1");
    field(b, tx.kind);
    field(b, tx.season_id);
    field(b, tx.market_id);
    field(b, tx.ref_type);
    field(b, tx.ref_id);
    field(b, to_str(len(tx.entries)));
    for e in sorted_entries(tx.entries) {
        field(b, e.owner.kind);
        field(b, e.owner.id);
        field(b, e.asset_key);
        field(b, e.bucket);
        field(b, e.hold);
        field(b, to_str(e.delta));
    }
    field(b, to_str(len(tx.holds)));
    for h in sorted_holds(tx.holds) {
        field(b, h.op);
        field(b, h.hold_id);
        field(b, h.owner.id);
        field(b, h.asset_key);
        field(b, to_str(h.amount));
    }
    return b.finish();
}

pub fn payload_hash(tx: LedgerTx) -> bytes {
    return crypto.sha256(canonical_payload(tx));
}

// A locked user or bot wallet, before and after the posting.
pub gc struct WalletState {
    wallet_id: str,
    owner_id: str,
    asset_key: str,
    free: int,
    held: int,
    free_before: int,
    held_before: int
}

// Applies the entries to the locked wallets with checked sums. A negative
// result is InsufficientFunds, reported against the balance before.
pub fn apply(states: [WalletState], entries: [Entry]) -> opt[LedgerError] {
    for e in entries {
        if e.owner.kind == "system" {
            continue;
        }
        let found = false;
        for s in states {
            if s.owner_id == e.owner.id && s.asset_key == e.asset_key {
                found = true;
                if e.bucket == "free" {
                    guard let n = checked_add(s.free, e.delta) else {
                        return some(failure(Fault.Overflow, "free balance of " + e.owner.id));
                    }
                    s.free = n;
                } else {
                    guard let n = checked_add(s.held, e.delta) else {
                        return some(failure(Fault.Overflow, "held balance of " + e.owner.id));
                    }
                    s.held = n;
                }
            }
        }
        if !found {
            return some(failure(Fault.WalletNotFound, e.owner.id + " " + e.asset_key));
        }
    }
    for s in states {
        if s.free < 0 {
            return some(insufficient(s.owner_id, s.asset_key, s.free_before - s.free, s.free_before));
        }
        if s.held < 0 {
            return some(insufficient(s.owner_id, s.asset_key, s.held_before - s.held, s.held_before));
        }
    }
    return none;
}
