import "strings";

// slang integers wrap on overflow; money must not, so every sum goes
// through these and an out-of-range result is an error, never a wrap.

pub fn max_units() -> int {
    return 9223372036854775807;
}

pub fn checked_add(a: int, b: int) -> opt[int] {
    if b > 0 && a > max_units() - b {
        return none;
    }
    if b < 0 && a < (0 - max_units() - 1) - b {
        return none;
    }
    return some(a + b);
}

pub fn checked_mul(a: int, b: int) -> opt[int] {
    if a == 0 || b == 0 {
        return some(0);
    }
    let p = a * b;
    if p / b != a || (a == -1 && b == 0 - max_units() - 1) || (b == -1 && a == 0 - max_units() - 1) {
        return none;
    }
    return some(p);
}

pub fn sedi() -> str {
    return "SEDI";
}

pub fn yes_asset(market_id: str) -> str {
    return "YES:" + market_id;
}

pub fn no_asset(market_id: str) -> str {
    return "NO:" + market_id;
}

fn is_hex_lower(c: int) -> bool {
    return (c >= 48 && c <= 57) || (c >= 97 && c <= 102);
}

// Lowercase canonical form only, so one market has exactly one key.
pub fn is_uuid(s: str) -> bool {
    if len(s) != 36 {
        return false;
    }
    let b = to_bytes(s);
    for i in 0..36 {
        if i == 8 || i == 13 || i == 18 || i == 23 {
            if b[i] != 45 {
                return false;
            }
        } else if !is_hex_lower(b[i]) {
            return false;
        }
    }
    return true;
}

pub fn valid_asset(key: str) -> bool {
    if key == sedi() {
        return true;
    }
    if strings.has_prefix(key, "YES:") {
        return is_uuid(strings.slice(key, 4, len(key)));
    }
    if strings.has_prefix(key, "NO:") {
        return is_uuid(strings.slice(key, 3, len(key)));
    }
    return false;
}
