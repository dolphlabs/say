import "builder";
import "crypto";
import "strings";

pub fn purpose_verify_email() -> str {
    return "verify_email";
}

pub fn purpose_reset_password() -> str {
    return "reset_password";
}

pub fn is_purpose(p: str) -> bool {
    return p == purpose_verify_email() || p == purpose_reset_password();
}

pub fn otp_ttl_seconds() -> int {
    return 600;
}

pub fn otp_max_attempts() -> int {
    return 5;
}

pub fn resend_cooldown_seconds() -> int {
    return 60;
}

pub fn max_sends_per_hour() -> int {
    return 5;
}

// 2^32 rounded down to a multiple of 10^6: values at or above it are
// rejected so every code is equally likely.
fn otp_limit() -> int {
    return 4294000000;
}

// Six digits from four random bytes, or none when the draw falls in the
// biased tail and the caller must draw again.
pub fn code_from(b: bytes) -> opt[str] {
    if len(b) != 4 {
        return none;
    }
    let v = (b[0] as int) * 16777216 + (b[1] as int) * 65536 + (b[2] as int) * 256 + (b[3] as int);
    if v >= otp_limit() {
        return none;
    }
    let s = to_str(v % 1000000);
    while len(s) < 6 {
        s = "0" + s;
    }
    return some(s);
}

pub fn is_code_shape(code: str) -> bool {
    if len(code) != 6 {
        return false;
    }
    for i in 0..6 {
        let ch = strings.slice(code, i, i + 1);
        if ch < "0" || ch > "9" {
            return false;
        }
    }
    return true;
}

// The purpose and account are inside the MAC, so a reset code can never
// stand in for a verification code, nor one account's code for another's.
pub fn code_hmac(secret: bytes, purpose: str, account_id: str, code: str) -> bytes {
    let msg = builder.new_bytes()
        .write_str(purpose)
        .write_str("|")
        .write_str(account_id)
        .write_str("|")
        .write_str(code)
        .finish();
    return crypto.hmac_sha256(secret, msg);
}

pub enum OtpState {
    Live,
    Expired,
    Locked,
    Consumed
}

pub fn otp_state(attempts: int, expired: bool, consumed: bool) -> OtpState {
    if consumed {
        return OtpState.Consumed;
    }
    if attempts >= otp_max_attempts() {
        return OtpState.Locked;
    }
    if expired {
        return OtpState.Expired;
    }
    return OtpState.Live;
}

pub fn attempts_left(attempts_after_miss: int) -> int {
    let left = otp_max_attempts() - attempts_after_miss;
    if left < 0 {
        return 0;
    }
    return left;
}
