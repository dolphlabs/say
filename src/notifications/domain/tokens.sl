import "crypto";
import "encoding";
import "strings";

pub fn sign_unsubscribe_token(secret: str, account_id: str, kind: str, expires_at: int) -> str {
    let payload = account_id + "." + kind + "." + to_str(expires_at);
    let h = crypto.hmac_sha256(to_bytes(secret), to_bytes(payload));
    let sig = encoding.hex_encode(h);
    return payload + "." + sig;
}

pub fn verify_unsubscribe_token(secret: str, token: str, now_s: int) -> result[UnsubscribeToken, str] {
    let parts = strings.split(token, ".");
    if len(parts) != 4 {
        return err("INVALID_TOKEN");
    }
    let account_id = parts[0];
    let kind = parts[1];
    let exp_str = parts[2];
    let sig = parts[3];

    let exp_res = to_int(exp_str);
    guard let exp = exp_res else {
        return err("INVALID_TOKEN");
    }

    if exp < now_s {
        return err("TOKEN_EXPIRED");
    }

    let payload = account_id + "." + kind + "." + exp_str;
    let expected_h = crypto.hmac_sha256(to_bytes(secret), to_bytes(payload));
    let expected_sig = encoding.hex_encode(expected_h);

    if sig != expected_sig {
        return err("INVALID_SIGNATURE");
    }

    return ok(UnsubscribeToken {
        account_id: account_id,
        kind: kind,
        expires_at: exp
    });
}
