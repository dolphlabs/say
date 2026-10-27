import "builder";
import "crypto";
import "encoding";
import "json";
import "strings";
import "time";

// What the outbox row carries. The code itself is sealed: XORed with an
// HMAC-SHA256 keystream under a key derived from the OTP secret and a
// per-row random nonce, so the database never holds a usable code; only
// its HMAC (otp_codes) and this sealed copy until delivery.
gc struct OtpEmail {
    to: str,
    username: str,
    purpose: str,
    nonce: str,
    sealed: str
}

fn seal_stream(secret: bytes, nonce: bytes) -> bytes {
    let key = crypto.hmac_sha256(secret, to_bytes("say/outbox-seal/v1"));
    return crypto.hmac_sha256(key, nonce);
}

fn xor_with(data: bytes, stream: bytes) -> bytes {
    let out = builder.new_bytes();
    for i in 0..len(data) {
        out.write_byte(data[i] ^ stream[i]);
    }
    return out.finish();
}

pub fn seal_code(secret: bytes, nonce: bytes, code: str) -> str {
    return encoding.hex_encode(xor_with(to_bytes(code), seal_stream(secret, nonce)));
}

pub fn unseal_code(secret: bytes, nonce: bytes, sealed_hex: str) -> result[str, str] {
    let r = encoding.hex_decode(sealed_hex);
    guard let sealed = r else let e = err_of(r) {
        return err(e);
    }
    if len(sealed) > 32 {
        return err("sealed code too long");
    }
    let plain = xor_with(sealed, seal_stream(secret, nonce));
    return ok(strings.from_bytes(plain, 0, len(plain)));
}

fn otp_payload(secret: bytes, to: str, username: str, purpose: str, code: str) -> result[str, str] {
    let nr = crypto.rand(16);
    guard let nonce = nr else let e = err_of(nr) {
        return err(e);
    }
    let p = OtpEmail {
        to: to,
        username: username,
        purpose: purpose,
        nonce: encoding.hex_encode(nonce),
        sealed: seal_code(secret, nonce, code)
    };
    return ok(json.encode(p));
}

fn open_payload(secret: bytes, payload: str) -> result[Mail, str] {
    let r: result[OtpEmail, str] = json.decode(payload);
    guard let p = r else let e = err_of(r) {
        return err("outbox payload: " + e);
    }
    let nr = encoding.hex_decode(p.nonce);
    guard let nonce = nr else let e = err_of(nr) {
        return err("outbox nonce: " + e);
    }
    let cr = unseal_code(secret, nonce, p.sealed);
    guard let code = cr else let e = err_of(cr) {
        return err(e);
    }
    return ok(Mail { to: p.to, username: p.username, purpose: p.purpose, code: code });
}

pub fn outbox_lease_seconds() -> int {
    return 60;
}

pub fn outbox_backoff_seconds(attempts: int) -> int {
    let d = 1;
    for i in 0..attempts {
        d = d * 2;
        if d >= 3600 {
            return 3600;
        }
    }
    return d;
}

// Delivers the one row `id`, or every due row when id is "". Rows are
// claimed with a lease, so the immediate attempt and the drainer never
// send the same row twice while either is still within the lease.
pub fn deliver[C, M](a: Auth[C], m: Mailer[M], id: str) -> int {
    let claim = a.store.claim_outbox;
    let r = claim(a.store.context, id, 20, outbox_lease_seconds());
    guard let items = r else let e = err_of(r) {
        report(a, "outbox claim failed: " + e);
        return 0;
    }
    let sent = 0;
    for item in items {
        let mr = open_payload(a.cfg.otp_secret, item.payload);
        let outcome: result[bool, str] = err("unopened");
        if let mail = mr {
            let send = m.send;
            outcome = send(m.context, mail);
        } else let e = err_of(mr) {
            outcome = err(e);
        }
        if let _ok = outcome {
            let done = a.store.outbox_sent;
            let dr = done(a.store.context, item.id);
            if let _d = dr {
                sent += 1;
            } else let e = err_of(dr) {
                report(a, "outbox " + item.id + " sent but not marked: " + e);
            }
        } else let e = err_of(outcome) {
            let retry = a.store.outbox_retry;
            let _rr = retry(a.store.context, item.id, e, outbox_backoff_seconds(item.attempts));
            report(a, "outbox " + item.id + " attempt " + to_str(item.attempts) + " failed: " + e);
        }
    }
    return sent;
}

pub fn deliver_now[C, M](a: Auth[C], m: Mailer[M], id: str) {
    let _n = deliver(a, m, id);
}

pub fn run_outbox_worker[C, M](a: Auth[C], m: Mailer[M], every_ms: int) -> int {
    while true {
        let _n = deliver(a, m, "");
        time.sleep(every_ms * 1000000);
    }
    return 0;
}

pub fn run_cleanup_worker[C](a: Auth[C], every_ms: int) -> int {
    while true {
        time.sleep(every_ms * 1000000);
        let sweep = a.store.sweep_expired;
        let r = sweep(a.store.context);
        if let _n = r {
        } else let e = err_of(r) {
            report(a, "expired-row cleanup failed: " + e);
        }
    }
    return 0;
}
