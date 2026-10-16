import "strings";

pub gc struct Account {
    id: str,
    username: opt[str],
    email: opt[str],
    phone_number: opt[str],
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

pub fn is_email_verified(a: Account) -> bool {
    if let _v = a.email_verified_at {
        return true;
    }
    return false;
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

pub fn effective_owner_group(a: Account) -> str {
    guard let g = a.beneficial_owner_group else {
        return a.id;
    }
    return g;
}

pub fn is_eligible_for_grant(a: Account) -> bool {
    return is_active(a) && is_verified(a) && is_age_confirmed(a) && a.kind == "USER";
}

pub fn validate_username(u: str) -> opt[str] {
    let n = len(u);
    if n < 3 {
        return some("must be at least 3 characters");
    }
    if n > 10 {
        return some("must be at most 10 characters");
    }
    for i in 0..n {
        let ch = strings.slice(u, i, i + 1);
        let is_letter = (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z");
        let is_digit = ch >= "0" && ch <= "9";
        let is_score = ch == "_";
        if !is_letter && !is_digit && !is_score {
            return some("can only contain letters, numbers, and underscores");
        }
    }
    return none;
}

pub fn validate_password(p: str) -> opt[str] {
    let n = len(p);
    if n < 8 {
        return some("must be at least 8 characters");
    }
    if n > 128 {
        return some("must be at most 128 characters");
    }
    let has_upper = false;
    let has_lower = false;
    let has_digit = false;
    let has_special = false;
    for i in 0..n {
        let ch = strings.slice(p, i, i + 1);
        if ch >= "A" && ch <= "Z" {
            has_upper = true;
        } else if ch >= "a" && ch <= "z" {
            has_lower = true;
        } else if ch >= "0" && ch <= "9" {
            has_digit = true;
        } else if ch == " " {
            return some("must not contain spaces");
        } else {
            has_special = true;
        }
    }
    if !has_upper {
        return some("must contain at least one uppercase letter");
    }
    if !has_lower {
        return some("must contain at least one lowercase letter");
    }
    if !has_digit {
        return some("must contain at least one number");
    }
    if !has_special {
        return some("must contain at least one special character");
    }
    return none;
}

pub fn validate_phone_number(phone: str) -> opt[str] {
    let n = len(phone);
    if n == 0 {
        return none;
    }
    if n < 8 || n > 16 {
        return some("must be between 8 and 16 characters including country code");
    }
    if strings.slice(phone, 0, 1) != "+" {
        return some("must start with country code + (e.g. +234...)");
    }
    for i in 1..n {
        let ch = strings.slice(phone, i, i + 1);
        if ch < "0" || ch > "9" {
            return some("must only contain digits after leading +");
        }
    }
    return none;
}

pub fn validate_email(email: str) -> opt[str] {
    let n = len(email);
    if n == 0 {
        return some("must not be empty");
    }
    if n > 255 {
        return some("must be at most 255 characters");
    }
    let at_idx = strings.find(email, "@");
    if at_idx <= 0 {
        return some("must be a valid email address");
    }
    let rest = strings.slice(email, at_idx + 1, n);
    let dot_idx = strings.find(rest, ".");
    if dot_idx <= 0 || dot_idx >= len(rest) - 1 {
        return some("must be a valid email address with a domain");
    }
    return none;
}
