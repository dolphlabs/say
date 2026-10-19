import "timez";
import "../domain" as domain;

pub gc struct UsernameCheck {
    username: str,
    available: bool,
    reason: str,
    suggestions: [str]
}

pub gc struct Hold {
    username: str,
    hold_id: str,
    expires_at: timez.Time
}

fn hold_key(name: str) -> str {
    return "username:hold:" + name;
}

fn taken_among[C](a: Auth[C], names: [str]) -> result[[str], StoreFail] {
    let f = a.store.usernames_taken;
    return f(a.store.context, names);
}

fn held_by[C](a: Auth[C], name: str) -> result[opt[str], str] {
    let f = a.store.eph_get;
    return f(a.store.context, hold_key(name));
}

fn none_names() -> [str] {
    let n: [str] = [];
    return n;
}

// Taken in Postgres and held in Redis are looked up at once; the pure
// checks need neither. A hold is invisible when Redis is down, which is
// fine: the unique constraint is the guarantee, the hold only a courtesy.
pub fn check_username[C](a: Auth[C], raw: str, ip: str) -> result[UsernameCheck, Failed] {
    if let limited = allow(a, rule_username_ip(), ip) {
        return err(limited);
    }
    let name = domain.normalize_username(raw);
    let out = UsernameCheck { username: name, available: false, reason: "", suggestions: none_names() };
    if let _p = domain.username_problem(name) {
        out.reason = "USERNAME_INVALID";
        return ok(out);
    }
    let candidates = domain.suggestion_candidates(name, a.cfg.reserved);
    let names: [str] = [name];
    for c in candidates {
        push(names, c);
    }
    let taken_h = spawn taken_among(a, names);
    let held_h = spawn held_by(a, name);
    let taken_j = join_wait(taken_h);
    let held_j = join_wait(held_h);
    guard let taken_r = taken_j else let e = err_of(taken_j) {
        return err(fail(Why.Unavailable, e));
    }
    guard let taken = taken_r else let f = err_of(taken_r) {
        return err(from_store(f));
    }
    let held = false;
    if let hr = held_j {
        if let h = hr {
            if let _owner = h {
                held = true;
            }
        }
    }
    let name_taken = false;
    for t in taken {
        if domain.normalize_username(t) == name {
            name_taken = true;
        }
    }
    if domain.is_reserved(name, a.cfg.reserved) {
        out.reason = "USERNAME_RESERVED";
    } else if name_taken || held {
        out.reason = "USERNAME_TAKEN";
    } else {
        out.available = true;
        return ok(out);
    }
    out.suggestions = domain.pick_suggestions(candidates, taken, 3);
    return ok(out);
}

fn username_failure(name: str, reserved: [str]) -> opt[Failed] {
    if let p = domain.username_problem(name) {
        return some(fail_field(Why.UsernameInvalid, "username", p));
    }
    if domain.is_reserved(name, reserved) {
        return some(fail_field(Why.UsernameReserved, "username", "is reserved"));
    }
    return none;
}

pub fn hold_username[C](a: Auth[C], raw: str, ip: str) -> result[Hold, Failed] {
    if let limited = allow(a, rule_username_ip(), ip) {
        return err(limited);
    }
    let name = domain.normalize_username(raw);
    if let bad = username_failure(name, a.cfg.reserved) {
        return err(bad);
    }
    let tr = taken_among(a, [name]);
    guard let taken = tr else let f = err_of(tr) {
        return err(from_store(f));
    }
    if len(taken) > 0 {
        return err(fail_field(Why.UsernameTaken, "username", "is taken"));
    }
    let ir = new_hex_id(16);
    guard let hold_id = ir else let e = err_of(ir) {
        return err(fail(Why.Unavailable, e));
    }
    let put = a.store.eph_put_nx;
    let r = put(a.store.context, hold_key(name), hold_id, a.cfg.hold_seconds);
    if let placed = r {
        if !placed {
            return err(fail_field(Why.UsernameTaken, "username", "is being claimed"));
        }
    } else let e = err_of(r) {
        report(a, "username hold not stored, redis unavailable: " + e);
    }
    return ok(Hold { username: name, hold_id: hold_id, expires_at: timez.now().add(a.cfg.hold_seconds * timez.SECOND) });
}

// none when the hold is good (or Redis cannot say), else the failure.
fn hold_problem[C](a: Auth[C], name: str, hold_id: str) -> opt[Failed] {
    let r = held_by(a, name);
    guard let held = r else let e = err_of(r) {
        report(a, "username hold not checked, redis unavailable: " + e);
        return none;
    }
    guard let owner = held else {
        return some(fail_field(Why.UsernameHoldExpired, "hold_id", "has expired"));
    }
    if owner != hold_id {
        return some(fail_field(Why.UsernameHoldExpired, "hold_id", "does not match"));
    }
    return none;
}

fn release_hold[C](a: Auth[C], name: str) {
    let drop = a.store.eph_drop;
    let _r = drop(a.store.context, [hold_key(name)]);
}
