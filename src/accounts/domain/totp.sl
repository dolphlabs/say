import "builder";
import "crypto";
import "encoding";
import "strings";

fn b32_chars() -> str {
    return "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
}

pub fn base32_encode(data: bytes) -> str {
    let out = builder.new_str();
    let buffer = 0;
    let bits_left = 0;
    let chars = b32_chars();
    for i in 0..len(data) {
        let b = (data[i] as int) & 255;
        buffer = (buffer << 8) | b;
        bits_left = bits_left + 8;
        while bits_left >= 5 {
            bits_left = bits_left - 5;
            let idx = (buffer >> bits_left) & 31;
            out.write(strings.slice(chars, idx, idx + 1));
        }
    }
    if bits_left > 0 {
        let idx = (buffer << (5 - bits_left)) & 31;
        out.write(strings.slice(chars, idx, idx + 1));
    }
    return out.finish();
}

pub fn base32_decode(s: str) -> result[bytes, str] {
    let out = builder.new_bytes();
    let buffer = 0;
    let bits_left = 0;
    let clean = strings.to_upper(s);
    let chars = b32_chars();
    for i in 0..len(clean) {
        let ch = strings.slice(clean, i, i + 1);
        if ch == "=" || ch == " " || ch == "-" {
            continue;
        }
        let val = -1;
        for j in 0..len(chars) {
            if strings.slice(chars, j, j + 1) == ch {
                val = j;
                break;
            }
        }
        if val < 0 {
            return err("invalid base32 character: " + ch);
        }
        buffer = (buffer << 5) | val;
        bits_left = bits_left + 5;
        if bits_left >= 8 {
            bits_left = bits_left - 8;
            let byte_val = (buffer >> bits_left) & 255;
            out.write_byte(byte_val);
        }
    }
    return ok(out.finish());
}

pub fn compute_step(time_sec: int) -> int {
    return time_sec / 30;
}

pub fn totp_code_for_step(secret: bytes, step: int) -> str {
    let b = builder.new_bytes();
    // 8-byte big-endian counter
    let s = step;
    let bytes_arr: [int] = [0, 0, 0, 0, 0, 0, 0, 0];
    for i in 0..8 {
        bytes_arr[7 - i] = s & 255;
        s = s >> 8;
    }
    for i in 0..8 {
        b.write_byte(bytes_arr[i]);
    }
    let msg = b.finish();
    let h = crypto.hmac_sha256(secret, msg);
    let offset = (h[len(h) - 1] as int) & 15;
    let b0 = (h[offset] as int) & 127;
    let b1 = (h[offset + 1] as int) & 255;
    let b2 = (h[offset + 2] as int) & 255;
    let b3 = (h[offset + 3] as int) & 255;
    let v = (b0 * 16777216) + (b1 * 65536) + (b2 * 256) + b3;
    let code_num = v % 1000000;
    let code_str = to_str(code_num);
    while len(code_str) < 6 {
        code_str = "0" + code_str;
    }
    return code_str;
}

pub fn totp_code_at(secret: bytes, time_sec: int) -> str {
    return totp_code_for_step(secret, compute_step(time_sec));
}

pub fn verify_totp(secret: bytes, code: str, time_sec: int, last_step: int) -> result[int, str] {
    if len(code) != 6 {
        return err("INVALID_CODE");
    }
    let cur_step = compute_step(time_sec);
    // Check current step first
    let c0 = totp_code_for_step(secret, cur_step);
    if c0 == code {
        if cur_step <= last_step {
            return err("CODE_REPLAY");
        }
        return ok(cur_step);
    }
    // Allow 1 step grace for drift
    let prev_step = cur_step - 1;
    let c1 = totp_code_for_step(secret, prev_step);
    if c1 == code {
        if prev_step <= last_step {
            return err("CODE_REPLAY");
        }
        return ok(prev_step);
    }
    return err("INVALID_CODE");
}

pub fn generate_totp_secret() -> result[bytes, str] {
    let r = crypto.rand(32);
    guard let b = r else let e = err_of(r) {
        return err(e);
    }
    return ok(b);
}

pub fn totp_uri(secret_b32: str, account_username: str, issuer: str) -> str {
    return "otpauth://totp/" + issuer + ":" + account_username + "?secret=" + secret_b32 + "&issuer=" + issuer + "&algorithm=SHA256&digits=6&period=30";
}
