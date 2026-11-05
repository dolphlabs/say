import "crypto";
import "encoding";

// Bots share one beneficial-owner group, so self-trade prevention keeps
// house bots from trading with each other.
pub fn house_group() -> str {
    return "00000000-0000-4000-8000-0000000b0700";
}

pub fn max_funding_amount() -> int {
    return 100000000;
}

// What an approver signs off on. A change to any of these after the request
// is made produces a different hash, and the approval no longer matches.
pub fn topup_hash(topup_id: str, bot_id: str, market_id: str, amount: int) -> str {
    return encoding.hex_encode(crypto.sha256(to_bytes("bot_topup|" + topup_id + "|" + bot_id + "|" + market_id + "|" + to_str(amount))));
}

pub fn season_budget_hash(budget_id: str, season_id: str, cap: int) -> str {
    return encoding.hex_encode(crypto.sha256(to_bytes("bot_season_budget|" + budget_id + "|" + season_id + "|" + to_str(cap))));
}

pub fn valid_bot_username(name: str) -> bool {
    let b = to_bytes(name);
    if len(b) < 3 || len(b) > 24 { return false; }
    for c in b {
        let lower = c >= 97 && c <= 122;
        let digit = c >= 48 && c <= 57;
        if !lower && !digit && c != 95 { return false; }
    }
    return true;
}

pub fn valid_reason(reason: str) -> bool {
    return len(reason) <= 500;
}
