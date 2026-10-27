import "strings";

pub fn normalize_username(raw: str) -> str {
    return strings.to_lower(strings.trim(raw));
}

fn is_alnum(ch: str) -> bool {
    return (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9");
}

// ^[a-z0-9][a-z0-9._]{1,18}[a-z0-9_]$, checked by hand: routing and
// validation here never compile a regex per request.
pub fn username_problem(u: str) -> opt[str] {
    let n = len(u);
    if n < 3 || n > 20 {
        return some("must be 3 to 20 characters");
    }
    if !is_alnum(strings.slice(u, 0, 1)) {
        return some("must start with a letter or a number");
    }
    for i in 1..n - 1 {
        let ch = strings.slice(u, i, i + 1);
        if !is_alnum(ch) && ch != "." && ch != "_" {
            return some("can only use a-z, 0-9, . and _");
        }
    }
    let last = strings.slice(u, n - 1, n);
    if !is_alnum(last) && last != "_" {
        return some("must not end with .");
    }
    return none;
}

pub fn is_reserved(u: str, reserved: [str]) -> bool {
    for r in reserved {
        if u == r {
            return true;
        }
    }
    return false;
}

fn suffixes() -> [str] {
    return ["_says", ".ng", "99", "_ng", "1", "_x", "007", "2", "_01", "3", "_9ja", "10"];
}

// Variations of `base` to offer when it is taken, best first. Every one is
// a valid, unreserved name; the caller keeps the first three nobody holds.
pub fn suggestion_candidates(base: str, reserved: [str]) -> [str] {
    let out: [str] = [];
    let stem = base;
    while len(stem) > 0 {
        let tail = strings.slice(stem, len(stem) - 1, len(stem));
        if tail != "." && tail != "_" {
            break;
        }
        stem = strings.slice(stem, 0, len(stem) - 1);
    }
    if len(stem) == 0 {
        return out;
    }
    for s in suffixes() {
        let room = 20 - len(s);
        let b = stem;
        if len(b) > room {
            b = strings.slice(b, 0, room);
        }
        let candidate = b + s;
        if candidate == base {
            continue;
        }
        let problem = username_problem(candidate);
        if let _p = problem {
            continue;
        }
        if is_reserved(candidate, reserved) {
            continue;
        }
        let dup = false;
        for o in out {
            if o == candidate {
                dup = true;
            }
        }
        if !dup {
            push(out, candidate);
        }
    }
    return out;
}

pub fn pick_suggestions(candidates: [str], taken: [str], want: int) -> [str] {
    let out: [str] = [];
    for c in candidates {
        if len(out) >= want {
            break;
        }
        let held = false;
        for t in taken {
            if strings.to_lower(t) == c {
                held = true;
            }
        }
        if !held {
            push(out, c);
        }
    }
    return out;
}
