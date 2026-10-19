import "timez";

pub gc struct Rule {
    name: str,
    limit: int,
    window_seconds: int
}

pub fn rule_signup_ip() -> Rule {
    return Rule { name: "signup_ip", limit: 5, window_seconds: 3600 };
}

pub fn rule_login_email() -> Rule {
    return Rule { name: "login_email", limit: 10, window_seconds: 900 };
}

pub fn rule_login_ip() -> Rule {
    return Rule { name: "login_ip", limit: 30, window_seconds: 900 };
}

pub fn rule_verify_ip() -> Rule {
    return Rule { name: "verify_ip", limit: 20, window_seconds: 3600 };
}

pub fn rule_username_ip() -> Rule {
    return Rule { name: "username_ip", limit: 60, window_seconds: 60 };
}

pub fn rule_recovery_ip() -> Rule {
    return Rule { name: "recovery_ip", limit: 20, window_seconds: 3600 };
}

// The in-process fallback when Redis cannot count: fixed windows per key,
// so auth stays protected (per instance) while Redis is down.
pub gc struct LocalLimiter {
    lock: mutex,
    counts: map[str]int,
    windows: map[str]int,
    last_warned: int
}

pub fn new_local_limiter() -> LocalLimiter {
    let counts: map[str]int = {};
    let windows: map[str]int = {};
    return LocalLimiter { lock: make_mutex(), counts: counts, windows: windows, last_warned: 0 };
}

fn local_hit(l: LocalLimiter, key: str, window_seconds: int, now: int) -> int {
    let window = now / window_seconds;
    mutex_lock(l.lock);
    if !has(l.windows, key) || l.windows[key] != window {
        l.windows[key] = window;
        l.counts[key] = 0;
    }
    l.counts[key] = l.counts[key] + 1;
    let n = l.counts[key];
    if len(l.counts) > 100000 {
        let fresh: map[str]int = {};
        let fresh_w: map[str]int = {};
        l.counts = fresh;
        l.windows = fresh_w;
    }
    mutex_unlock(l.lock);
    return n;
}

fn should_warn(l: LocalLimiter, now: int) -> bool {
    mutex_lock(l.lock);
    let warn = now - l.last_warned >= 60;
    if warn {
        l.last_warned = now;
    }
    mutex_unlock(l.lock);
    return warn;
}

// none to go on, or the failure to answer with.
pub fn allow[C](a: Auth[C], rule: Rule, key: str) -> opt[Failed] {
    if len(key) == 0 {
        return none;
    }
    let full = "rl:" + rule.name + ":" + key;
    let hit = a.store.eph_hit;
    let r = hit(a.store.context, full, rule.window_seconds);
    let count = 0;
    if let n = r {
        count = n;
    } else let e = err_of(r) {
        let now = timez.now().unix();
        count = local_hit(a.limiter, full, rule.window_seconds, now);
        if should_warn(a.limiter, now) {
            report(a, "rate limiting in-process: redis unavailable: " + e);
        }
    }
    if count > rule.limit {
        return some(fail_retry(Why.RateLimited, rule.window_seconds));
    }
    return none;
}
