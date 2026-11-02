import "crypto";
import "encoding";
import "strings";
import "time";
import "timez";
import "../domain" as domain;

pub gc struct TotpEnrollResult {
    secret_b32: str,
    uri: str
}

pub gc struct EmailChangeRequested {
    token: str,
    code: str
}

pub gc struct EmailChangedResult {
    old_email: str,
    new_email: str,
    revoked_sessions: [bytes]
}

fn get_settings_store[C](a: Auth[C]) -> result[SettingsStore[C], str] {
    guard let s = a.settings else {
        return err("settings store not configured");
    }
    return ok(s);
}

pub fn has_recent_totp[C](a: Auth[C], session_id: str, account_id: str) -> bool {
    guard let st = a.settings else { return true; }
    let f = st.has_recent_totp;
    return f(st.context, session_id, account_id);
}

pub fn enroll_totp[C](a: Auth[C], account_id: str, username: str) -> result[TotpEnrollResult, str] {
    let st_r = get_settings_store(a);
    guard let st = st_r else let e = err_of(st_r) { return err(e); }

    let sec_r = domain.generate_totp_secret();
    guard let secret = sec_r else let e = err_of(sec_r) { return err(e); }

    let b32 = domain.base32_encode(secret);
    let hex_secret = encoding.hex_encode(secret);
    let uri = domain.totp_uri(b32, username, "say");

    let save_f = st.save_pending_totp;
    let r = save_f(st.context, account_id, hex_secret);
    guard let _ok = r else let e = err_of(r) { return err(e); }

    return ok(TotpEnrollResult {
        secret_b32: b32,
        uri: uri
    });
}

pub fn verify_totp[C](a: Auth[C], account_id: str, session_id: str, code: str, now_sec: int) -> result[bool, str] {
    let st_r = get_settings_store(a);
    guard let st = st_r else let e = err_of(st_r) { return err(e); }

    // 1. Check pending_totp first
    let load_p_f = st.load_pending_totp;
    let p_r = load_p_f(st.context, account_id);
    if let opt_sec = p_r {
        if let hex_sec = opt_sec {
            let sec_b = encoding.hex_decode(hex_sec) ?? b"";
            let ver = domain.verify_totp(sec_b, code, now_sec, 0);
            guard let step = ver else {
                return err("INVALID_CODE");
            }
            let act_f = st.activate_totp;
            let act_r = act_f(st.context, account_id, hex_sec, step, session_id);
            guard let _ok = act_r else let e = err_of(act_r) { return err(e); }
            return ok(true);
        }
    }

    // 2. Check active account_totp
    let load_a_f = st.load_account_totp;
    let a_r = load_a_f(st.context, account_id);
    guard let opt_row = a_r else let e = err_of(a_r) { return err(e); }
    guard let row = opt_row else {
        return err("NO_PENDING_OR_ACTIVE_2FA");
    }

    let sec_b = encoding.hex_decode(row.secret_encrypted) ?? b"";
    let ver = domain.verify_totp(sec_b, code, now_sec, row.last_verified_step);
    guard let step = ver else {
        return err("INVALID_CODE");
    }

    let step_up_f = st.record_totp_step_up;
    let su_r = step_up_f(st.context, account_id, step, session_id);
    guard let _ok = su_r else let e = err_of(su_r) { return err(e); }
    return ok(true);
}

pub fn disable_totp[C](a: Auth[C], account_id: str, code: str, now_sec: int) -> result[bool, str] {
    let st_r = get_settings_store(a);
    guard let st = st_r else let e = err_of(st_r) { return err(e); }

    let load_a_f = st.load_account_totp;
    let a_r = load_a_f(st.context, account_id);
    guard let opt_row = a_r else let e = err_of(a_r) { return err(e); }
    guard let row = opt_row else {
        return err("2FA_NOT_ENROLLED");
    }

    let sec_b = encoding.hex_decode(row.secret_encrypted) ?? b"";
    let ver = domain.verify_totp(sec_b, code, now_sec, row.last_verified_step);
    guard let _step = ver else {
        return err("INVALID_CODE");
    }

    let del_f = st.delete_totp;
    let del_r = del_f(st.context, account_id);
    guard let _ok = del_r else let e = err_of(del_r) { return err(e); }
    return ok(true);
}

pub fn change_username[C](a: Auth[C], account_id: str, old_username: str, new_username: str, now_ms: int) -> result[bool, str] {
    let st_r = get_settings_store(a);
    guard let st = st_r else let e = err_of(st_r) { return err(e); }

    // 1. Check season window (first 72h)
    let w_f = st.get_season_window;
    let w_r = w_f(st.context);
    guard let opt_w = w_r else let e = err_of(w_r) { return err(e); }
    guard let win = opt_w else {
        return err("USERNAME_CHANGE_WINDOW_CLOSED");
    }

    let window_ends_ms = win.starts_at_ms + 72 * 3600 * 1000;
    if now_ms < win.starts_at_ms || now_ms >= window_ends_ms {
        return err("USERNAME_CHANGE_WINDOW_CLOSED");
    }

    // 2. Check once per season
    let hist_f = st.has_username_history_in_season;
    let h_r = hist_f(st.context, account_id, win.season_id);
    guard let has_changed = h_r else let e = err_of(h_r) { return err(e); }
    if has_changed {
        return err("USERNAME_ALREADY_CHANGED_THIS_SEASON");
    }

    // 3. Execute change
    let chg_f = st.change_username;
    let chg_r = chg_f(st.context, account_id, win.season_id, old_username, new_username);
    guard let _ok = chg_r else let e = err_of(chg_r) { return err(e); }
    return ok(true);
}

pub fn request_email_change[C](a: Auth[C], account_id: str, new_email: str) -> result[EmailChangeRequested, str] {
    let st_r = get_settings_store(a);
    guard let st = st_r else let e = err_of(st_r) { return err(e); }

    let rb = crypto.rand(16);
    guard let b = rb else let e = err_of(rb) { return err(e); }
    let token = encoding.hex_encode(b);
    let token_hash = crypto.sha256(to_bytes(token));

    let r_code = crypto.rand(3);
    let code = "123456";
    if let cb = r_code {
        let n = ((cb[0] as int) * 65536 + (cb[1] as int) * 256 + (cb[2] as int)) % 1000000;
        code = to_str(n);
        while len(code) < 6 { code = "0" + code; }
    }
    let code_hash = crypto.sha256(to_bytes(code));

    let req_f = st.request_email_change;
    let r = req_f(st.context, account_id, new_email, token_hash, code_hash);
    guard let _ok = r else let e = err_of(r) { return err(e); }

    return ok(EmailChangeRequested {
        token: token,
        code: code
    });
}

pub fn verify_email_change[C](a: Auth[C], account_id: str, token: str, code: str) -> result[EmailChangedResult, str] {
    let st_r = get_settings_store(a);
    guard let st = st_r else let e = err_of(st_r) { return err(e); }

    let token_hash = crypto.sha256(to_bytes(token));
    let code_hash = crypto.sha256(to_bytes(code));

    let ver_f = st.verify_email_change;
    let ver_r = ver_f(st.context, token_hash, account_id, code_hash);
    guard let opt_row = ver_r else let e = err_of(ver_r) { return err(e); }
    guard let row = opt_row else {
        return err("INVALID_CODE");
    }

    let apply_f = st.apply_email_change;
    let apply_r = apply_f(st.context, account_id, row.new_email);
    guard let revoked = apply_r else let e = err_of(apply_r) { return err(e); }

    return ok(EmailChangedResult {
        old_email: row.old_email,
        new_email: row.new_email,
        revoked_sessions: revoked
    });
}

pub fn find_account_id_by_username[C](a: Auth[C], username: str) -> result[opt[str], str] {
    let st_r = get_settings_store(a);
    guard let st = st_r else let e = err_of(st_r) { return err(e); }
    let f = st.find_account_id_by_username;
    return f(st.context, username);
}


pub fn revoke_role[C](a: Auth[C], account_id: str, role: str) -> result[bool, str] {
    let st_r = get_settings_store(a);
    guard let st = st_r else let e = err_of(st_r) { return err(e); }
    let f = st.revoke_role_direct;
    return f(st.context, account_id, role);
}

pub fn open_markets_for_account[C](a: Auth[C], account_id: str) -> result[[str], str] {
    let st_r = get_settings_store(a);
    guard let st = st_r else let e = err_of(st_r) { return err(e); }
    let f = st.open_markets_for_account;
    return f(st.context, account_id);
}

pub fn anonymise_account[C](a: Auth[C], account_id: str) -> result[[bytes], str] {
    let st_r = get_settings_store(a);
    guard let st = st_r else let e = err_of(st_r) { return err(e); }

    let rand_b = crypto.rand(3);
    let rnd_hex = "123456";
    if let rb = rand_b { rnd_hex = encoding.hex_encode(rb); }
    let anon_user = "deleted-" + rnd_hex;
    let anon_email = "deleted-" + account_id + "@deleted.local";

    let f = st.anonymise_account;
    return f(st.context, account_id, anon_user, anon_email);
}
