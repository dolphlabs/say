import "timez";
import "zokor";
import "../domain" as domain;
import "../../ledger/domain" as ledger;

gc struct HoldDto {
    username: str
}

gc struct SignupDto {
    username: str,
    hold_id: str,
    email: str,
    password: str
}

gc struct ResendDto {
    signup_token: opt[str],
    email: opt[str],
    purpose: str
}

gc struct VerifyDto {
    signup_token: str,
    code: str
}

gc struct LoginDto {
    email: str,
    password: str
}

gc struct GoogleCompleteDto {
    pending_token: str,
    username: str,
    hold_id: str
}

gc struct ForgotDto {
    email: str
}

gc struct ResetDto {
    email: str,
    code: str,
    new_password: str
}

gc struct ChangePasswordDto {
    current_password: str,
    new_password: str
}

gc struct ChangeUsernameDto {
    username: str,
    hold_id: str
}

gc struct RequestEmailChangeDto {
    new_email: str
}

gc struct VerifyEmailChangeDto {
    change_token: str,
    code: str
}

gc struct Verify2faDto {
    code: str
}

gc struct DeleteMeDto {
    password: opt[str],
    otp: opt[str]
}

gc struct RoleAdminDto {
    username: str,
    role: str,
    reason: str
}

fn user_json(a: domain.Account, changeable_at: timez.Time) -> zokor.Json {
    return zokor.jobj()
        .set_str("id", a.id)
        .set_str("username", a.username)
        .set_opt_str("email", a.email)
        .set_bool("email_verified", a.email_verified)
        .set_bool("has_password", a.has_password)
        .set_bool("google_linked", a.google_linked)
        .set_str("username_changeable_at", changeable_at.rfc3339())
        .set_str("created_at", a.created_at.rfc3339());
}

fn grant_json(g: opt[ledger.Grant]) -> zokor.Json {
    guard let grant = g else {
        return zokor.jnull();
    }
    return zokor.jobj()
        .set_int("amount", grant.amount)
        .set_int("season_ordinal", grant.season_ordinal)
        .set_str("season_ends_at", grant.season_ends_at.rfc3339());
}

// A username is fixed until the season it was set in ends.
fn changeable_at(a: domain.Account, g: opt[ledger.Grant]) -> timez.Time {
    if let grant = g {
        if grant.season_ends_at.after(a.username_changeable_at) {
            return grant.season_ends_at;
        }
    }
    return a.username_changeable_at;
}
