import "strings";

pub enum Fault {
    InsufficientFunds,
    IdempotencyConflict,
    SeasonMismatch,
    SeasonNotActive,
    Unbalanced,
    Overflow,
    HoldNotOpen,
    HoldExceeded,
    WalletNotFound,
    PolicyMissing,
    CapReached,
    Malformed,
    Store
}

pub gc struct LedgerError {
    fault: Fault,
    wallet: str,
    asset: str,
    needed: int,
    available: int,
    detail: str
}

pub fn failure(f: Fault, detail: str) -> LedgerError {
    return LedgerError { fault: f, wallet: "", asset: "", needed: 0, available: 0, detail: detail };
}

pub fn insufficient(wallet: str, asset: str, needed: int, available: int) -> LedgerError {
    return LedgerError { fault: Fault.InsufficientFunds, wallet: wallet, asset: asset, needed: needed,
                         available: available, detail: "insufficient " + asset };
}

pub fn fault_name(f: Fault) -> str {
    switch f {
        case Fault.InsufficientFunds { return "InsufficientFunds"; }
        case Fault.IdempotencyConflict { return "IdempotencyConflict"; }
        case Fault.SeasonMismatch { return "SeasonMismatch"; }
        case Fault.SeasonNotActive { return "SeasonNotActive"; }
        case Fault.Unbalanced { return "Unbalanced"; }
        case Fault.Overflow { return "Overflow"; }
        case Fault.HoldNotOpen { return "HoldNotOpen"; }
        case Fault.HoldExceeded { return "HoldExceeded"; }
        case Fault.WalletNotFound { return "WalletNotFound"; }
        case Fault.PolicyMissing { return "PolicyMissing"; }
        case Fault.CapReached { return "CapReached"; }
        case Fault.Malformed { return "Malformed"; }
        default { return "Store"; }
    }
}

fn fault_named(name: str) -> Fault {
    switch name {
        case "InsufficientFunds" { return Fault.InsufficientFunds; }
        case "IdempotencyConflict" { return Fault.IdempotencyConflict; }
        case "SeasonMismatch" { return Fault.SeasonMismatch; }
        case "SeasonNotActive" { return Fault.SeasonNotActive; }
        case "Unbalanced" { return Fault.Unbalanced; }
        case "Overflow" { return Fault.Overflow; }
        case "HoldNotOpen" { return Fault.HoldNotOpen; }
        case "HoldExceeded" { return Fault.HoldExceeded; }
        case "WalletNotFound" { return Fault.WalletNotFound; }
        case "PolicyMissing" { return Fault.PolicyMissing; }
        case "CapReached" { return Fault.CapReached; }
        case "Malformed" { return Fault.Malformed; }
        default { return Fault.Store; }
    }
}

// zokor.transaction bodies fail with a string, so a typed error crosses
// the transaction boundary as text and is rebuilt on the other side.
pub fn encode(e: LedgerError) -> str {
    return "ledger:" + fault_name(e.fault) + "|" + e.wallet + "|" + e.asset + "|" + to_str(e.needed) + "|" +
           to_str(e.available) + "|" + e.detail;
}

pub fn decode(s: str) -> LedgerError {
    if !strings.has_prefix(s, "ledger:") {
        return failure(Fault.Store, s);
    }
    let parts = strings.split(strings.slice(s, 7, len(s)), "|");
    if len(parts) < 6 {
        return failure(Fault.Store, s);
    }
    let detail = parts[5];
    for i in 6..len(parts) {
        detail = detail + "|" + parts[i];
    }
    return LedgerError {
        fault: fault_named(parts[0]),
        wallet: parts[1],
        asset: parts[2],
        needed: to_int(parts[3]) ?? 0,
        available: to_int(parts[4]) ?? 0,
        detail: detail
    };
}

pub fn is_ledger_error(s: str) -> bool {
    return strings.has_prefix(s, "ledger:");
}
