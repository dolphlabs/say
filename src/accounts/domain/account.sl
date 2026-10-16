pub gc struct Account {
    id: str,
    email: opt[str],
    password_hash: opt[str],
    auth_provider: str,
    status: str,
    kind: str,
    beneficial_owner_group: opt[str],
    email_verified_at: opt[str],
    verified_at: opt[str],
    age_confirmed_at: opt[str],
    created_at: str
}

pub gc struct Problem {
    field: str,
    reason: str
}

pub fn is_active(a: Account) -> bool {
    return a.status == "ACTIVE";
}

pub fn is_verified(a: Account) -> bool {
    if let _v = a.verified_at {
        return true;
    }
    return false;
}

pub fn is_age_confirmed(a: Account) -> bool {
    if let _v = a.age_confirmed_at {
        return true;
    }
    return false;
}

// Fallback to own account ID if no beneficial_owner_group is configured.
pub fn effective_owner_group(a: Account) -> str {
    guard let g = a.beneficial_owner_group else {
        return a.id;
    }
    return g;
}

pub fn is_eligible_for_grant(a: Account) -> bool {
    return is_active(a) && is_verified(a) && is_age_confirmed(a) && a.kind == "USER";
}

pub fn validate_new(email: opt[str], auth_provider: str) -> [Problem] {
    let out: [Problem] = [];
    if auth_provider != "LOCAL" && auth_provider != "GOOGLE" && auth_provider != "SYSTEM" {
        push(out, Problem { field: "auth_provider", reason: "must be LOCAL, GOOGLE, or SYSTEM" });
    }
    if let em = email {
        if len(em) == 0 {
            push(out, Problem { field: "email", reason: "must not be empty" });
        } else if len(em) > 255 {
            push(out, Problem { field: "email", reason: "must be at most 255 characters" });
        }
    }
    return out;
}
