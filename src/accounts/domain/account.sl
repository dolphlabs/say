import "strings";
import "timez";

pub gc struct Account {
    id: str,
    username: str,
    email: opt[str],
    status: str,
    email_verified: bool,
    has_password: bool,
    google_linked: bool,
    username_changeable_at: timez.Time,
    created_at: timez.Time
}

pub fn status_unverified() -> str {
    return "UNVERIFIED";
}

pub fn status_active() -> str {
    return "ACTIVE";
}

pub fn status_deleted() -> str {
    return "DELETED";
}

pub fn can_sign_in(status: str) -> bool {
    return status == status_active();
}

pub fn normalize_email(raw: str) -> str {
    return strings.to_lower(strings.trim(raw));
}

pub fn email_problem(email: str) -> opt[str] {
    let n = len(email);
    if n == 0 {
        return some("must not be empty");
    }
    if n > 254 {
        return some("must be at most 254 characters");
    }
    let at = strings.find(email, "@");
    if at <= 0 || at != strings.rfind(email, "@") {
        return some("must be a valid email address");
    }
    let domain_part = strings.slice(email, at + 1, n);
    let dot = strings.find(domain_part, ".");
    if dot <= 0 || dot >= len(domain_part) - 1 {
        return some("must be a valid email address");
    }
    for i in 0..n {
        let ch = strings.slice(email, i, i + 1);
        if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
            return some("must be a valid email address");
        }
    }
    return none;
}

// "utee@gmail.com" -> "u•••@gmail.com": enough for the owner to recognise.
pub fn mask_email(email: str) -> str {
    let at = strings.find(email, "@");
    if at <= 0 {
        return "•••";
    }
    return strings.slice(email, 0, 1) + "•••" + strings.slice(email, at, len(email));
}

pub fn min_password_bytes() -> int {
    return 8;
}

// Bounded so a megabyte "password" never reaches the hasher.
pub fn max_password_bytes() -> int {
    return 128;
}

pub fn password_problem(p: str) -> opt[str] {
    if len(p) < min_password_bytes() {
        return some("must be at least 8 characters");
    }
    if len(p) > max_password_bytes() {
        return some("must be at most 128 characters");
    }
    if len(strings.trim(p)) == 0 {
        return some("must not be only spaces");
    }
    return none;
}

// 0-4, the same scale the app's strength bar shows. Advisory only: the
// policy is the length rule above.
pub fn password_strength(p: str) -> int {
    let n = len(p);
    if n < min_password_bytes() {
        return 0;
    }
    let lower = false;
    let upper = false;
    let digit = false;
    let other = false;
    for i in 0..n {
        let ch = strings.slice(p, i, i + 1);
        if ch >= "a" && ch <= "z" {
            lower = true;
        } else if ch >= "A" && ch <= "Z" {
            upper = true;
        } else if ch >= "0" && ch <= "9" {
            digit = true;
        } else {
            other = true;
        }
    }
    let kinds = 0;
    for k in [lower, upper, digit, other] {
        if k {
            kinds += 1;
        }
    }
    let score = 1;
    if n >= 12 {
        score += 1;
    }
    if kinds >= 3 {
        score += 1;
    }
    if n >= 16 && kinds >= 2 {
        score += 1;
    }
    if score > 4 {
        return 4;
    }
    return score;
}
