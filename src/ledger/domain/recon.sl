pub gc struct Check {
    name: str,
    status: str,
    count: int,
    detail: str
}

pub fn passed(name: str) -> Check {
    return Check { name: name, status: "ok", count: 0, detail: "" };
}

pub fn failed(name: str, count: int, detail: str) -> Check {
    return Check { name: name, status: "failed", count: count, detail: detail };
}

pub fn not_yet(name: str, prompt: str) -> Check {
    return Check { name: name, status: "not_applicable", count: 0, detail: "arrives with " + prompt };
}

// The order the treasury screen shows them in.
pub fn check_names() -> [str] {
    return ["entries_balance", "cached_balances", "no_negative_balances", "grants", "season_isolation",
            "holds", "yes_no_supply", "collateral", "fee_once"];
}

pub fn all_ok(checks: [Check]) -> bool {
    for c in checks {
        if c.status == "failed" {
            return false;
        }
    }
    return true;
}
