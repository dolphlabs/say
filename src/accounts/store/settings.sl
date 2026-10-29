import "crypto";
import "encoding";
import "pg";
import "strings";
import "time";
import "zokor";
import "../service" as service;

gc struct IntValRow {
    n: int
}

gc struct SecretEncryptedRow {
    secret_encrypted: str
}

gc struct AccountTotpRow {
    secret_encrypted: str,
    last_verified_step: int
}

gc struct SeasonWindowRow {
    id: str,
    starts_at_ms: int
}

gc struct EmailChangeDbRow {
    old_email: str,
    new_email: str
}

fn pg_until() -> until {
    return until_of(time.mono() + 5000000000);
}

pub fn has_recent_totp(s: Store, session_id: str, account_id: str) -> bool {
    let r: result[[IntValRow], str] = zokor.query_all(s.pg,
        "select 1 as n from session_totp_proofs where session_id = $1 and account_id = $2::uuid and verified_at > now() - interval '12 hours'",
        [pg.arg_text(session_id), pg.arg_text(account_id)], pg_until());
    if let rows = r {
        if len(rows) > 0 { return true; }
    }
    return false;
}

pub fn save_pending_totp(s: Store, account_id: str, encrypted_secret: str) -> result[bool, str] {
    let q = "insert into pending_totp(account_id, secret_encrypted, created_at, expires_at) " +
        "values($1::uuid, $2, now(), now() + interval '10 minutes') " +
        "on conflict (account_id) do update set " +
        "  secret_encrypted = excluded.secret_encrypted, " +
        "  created_at = excluded.created_at, " +
        "  expires_at = excluded.expires_at";
    let r = pg.pool_query(s.pg, q, [pg.arg_text(account_id), pg.arg_text(encrypted_secret)], pg_until());
    guard let _ok = r else let e = err_of(r) { return err(e); }
    return ok(true);
}

pub fn load_pending_totp(s: Store, account_id: str) -> result[opt[str], str] {
    let r: result[[SecretEncryptedRow], str] = zokor.query_all(s.pg,
        "select secret_encrypted from pending_totp where account_id = $1::uuid and expires_at > now()",
        [pg.arg_text(account_id)], pg_until());
    guard let rows = r else let e = err_of(r) { return err(e); }
    if len(rows) == 0 {
        let n: opt[str] = none;
        return ok(n);
    }
    return ok(some(rows[0].secret_encrypted));
}

pub fn activate_totp(s: Store, account_id: str, encrypted_secret: str, step: int, session_id: str) -> result[bool, str] {
    let q = "insert into account_totp(account_id, secret_encrypted, enrolled_at, last_verified_step, last_verified_at) " +
        "values($1::uuid, $2, now(), $3, now()) " +
        "on conflict (account_id) do update set " +
        "  secret_encrypted = excluded.secret_encrypted, " +
        "  enrolled_at = now(), " +
        "  last_verified_step = excluded.last_verified_step, " +
        "  last_verified_at = now()";
    let r1 = pg.pool_query(s.pg, q, [pg.arg_text(account_id), pg.arg_text(encrypted_secret), pg.arg_int(step)], pg_until());
    guard let _ok1 = r1 else let e1 = err_of(r1) { return err(e1); }

    let _del = pg.pool_query(s.pg, "delete from pending_totp where account_id = $1::uuid", [pg.arg_text(account_id)], pg_until());

    let q_proof = "insert into session_totp_proofs(session_id, account_id, verified_at) values($1, $2::uuid, now()) on conflict (session_id) do update set verified_at = now()";
    let _prf = pg.pool_query(s.pg, q_proof, [pg.arg_text(session_id), pg.arg_text(account_id)], pg_until());
    return ok(true);
}

pub fn load_account_totp(s: Store, account_id: str) -> result[opt[service.TotpRow], str] {
    let r: result[[AccountTotpRow], str] = zokor.query_all(s.pg,
        "select secret_encrypted, last_verified_step from account_totp where account_id = $1::uuid",
        [pg.arg_text(account_id)], pg_until());
    guard let rows = r else let e = err_of(r) { return err(e); }
    if len(rows) == 0 {
        let n: opt[service.TotpRow] = none;
        return ok(n);
    }
    return ok(some(service.TotpRow {
        secret_encrypted: rows[0].secret_encrypted,
        last_verified_step: rows[0].last_verified_step
    }));
}

pub fn record_totp_step_up(s: Store, account_id: str, step: int, session_id: str) -> result[bool, str] {
    let q = "update account_totp set last_verified_step = $1, last_verified_at = now() where account_id = $2::uuid";
    let r = pg.pool_query(s.pg, q, [pg.arg_int(step), pg.arg_text(account_id)], pg_until());
    guard let _ok = r else let e = err_of(r) { return err(e); }

    let q_proof = "insert into session_totp_proofs(session_id, account_id, verified_at) values($1, $2::uuid, now()) on conflict (session_id) do update set verified_at = now()";
    let _prf = pg.pool_query(s.pg, q_proof, [pg.arg_text(session_id), pg.arg_text(account_id)], pg_until());
    return ok(true);
}

pub fn delete_totp(s: Store, account_id: str) -> result[bool, str] {
    let _del1 = pg.pool_query(s.pg, "delete from account_totp where account_id = $1::uuid", [pg.arg_text(account_id)], pg_until());
    let _del2 = pg.pool_query(s.pg, "delete from session_totp_proofs where account_id = $1::uuid", [pg.arg_text(account_id)], pg_until());
    return ok(true);
}

pub fn get_season_window(s: Store) -> result[opt[service.SeasonWindow], str] {
    let empty_args: [pg.Arg] = [];
    let r: result[[SeasonWindowRow], str] = zokor.query_all(s.pg,
        "select id::text as id, (extract(epoch from starts_at)*1000)::bigint as starts_at_ms from seasons where status = 'ACTIVE' order by ordinal desc limit 1",
        empty_args, pg_until());
    guard let rows = r else let e = err_of(r) { return err(e); }
    if len(rows) == 0 {
        let n: opt[service.SeasonWindow] = none;
        return ok(n);
    }
    return ok(some(service.SeasonWindow {
        season_id: rows[0].id,
        starts_at_ms: rows[0].starts_at_ms
    }));
}

pub fn has_username_history_in_season(s: Store, account_id: str, season_id: str) -> result[bool, str] {
    let r: result[[IntValRow], str] = zokor.query_all(s.pg,
        "select 1 as n from username_history where account_id = $1::uuid and season_id = $2::uuid",
        [pg.arg_text(account_id), pg.arg_text(season_id)], pg_until());
    guard let rows = r else let e = err_of(r) { return err(e); }
    return ok(len(rows) > 0);
}

pub fn change_username_tx(s: Store, account_id: str, season_id: str, old_username: str, new_username: str) -> result[bool, str] {
    let q1 = "insert into username_history(account_id, old_username, new_username, season_id, changed_at) " +
        "values($1::uuid, $2, $3, $4::uuid, now())";
    let r1 = pg.pool_query(s.pg, q1, [pg.arg_text(account_id), pg.arg_text(old_username), pg.arg_text(new_username), pg.arg_text(season_id)], pg_until());
    guard let _ok1 = r1 else let e1 = err_of(r1) { return err(e1); }

    let q2 = "insert into username_reservations(username, account_id, reserved_until, created_at) " +
        "values($1, $2::uuid, now() + interval '30 days', now()) " +
        "on conflict (username) do update set reserved_until = excluded.reserved_until";
    let r2 = pg.pool_query(s.pg, q2, [pg.arg_text(old_username), pg.arg_text(account_id)], pg_until());
    guard let _ok2 = r2 else let e2 = err_of(r2) { return err(e2); }

    let q3 = "update accounts set username = $1 where id = $2::uuid";
    let r3 = pg.pool_query(s.pg, q3, [pg.arg_text(new_username), pg.arg_text(account_id)], pg_until());
    guard let _ok3 = r3 else let e3 = err_of(r3) { return err(e3); }

    return ok(true);
}

pub fn request_email_change(s: Store, account_id: str, new_email: str, token_hash: bytes, code_hash: bytes) -> result[bool, str] {
    let q = "insert into email_changes(account_id, new_email, token_hash, code_hash, created_at, expires_at) " +
        "values($1::uuid, $2, $3, $4, now(), now() + interval '15 minutes') " +
        "on conflict (account_id) do update set " +
        "  new_email = excluded.new_email, " +
        "  token_hash = excluded.token_hash, " +
        "  code_hash = excluded.code_hash, " +
        "  created_at = excluded.created_at, " +
        "  expires_at = excluded.expires_at";
    let r = pg.pool_query(s.pg, q, [pg.arg_text(account_id), pg.arg_text(new_email), pg.arg_bytes(token_hash), pg.arg_bytes(code_hash)], pg_until());
    guard let _ok = r else let e = err_of(r) { return err(e); }
    return ok(true);
}

pub fn verify_email_change(s: Store, token_hash: bytes, account_id: str, code_hash: bytes) -> result[opt[service.EmailChangeRow], str] {
    let q = "select ec.new_email, a.email as old_email from email_changes ec " +
        "join accounts a on a.id = ec.account_id " +
        "where ec.token_hash = $1 and ec.account_id = $2::uuid and ec.code_hash = $3 and ec.expires_at > now()";
    let r: result[[EmailChangeDbRow], str] = zokor.query_all(s.pg, q, [pg.arg_bytes(token_hash), pg.arg_text(account_id), pg.arg_bytes(code_hash)], pg_until());
    guard let rows = r else let e = err_of(r) { return err(e); }
    if len(rows) == 0 {
        let n: opt[service.EmailChangeRow] = none;
        return ok(n);
    }
    return ok(some(service.EmailChangeRow {
        old_email: rows[0].old_email,
        new_email: rows[0].new_email
    }));
}

pub fn apply_email_change(s: Store, account_id: str, new_email: str) -> result[[bytes], str] {
    let q1 = "update accounts set email = $1 where id = $2::uuid";
    let r1 = pg.pool_query(s.pg, q1, [pg.arg_text(new_email), pg.arg_text(account_id)], pg_until());
    guard let _ok1 = r1 else let e1 = err_of(r1) { return err(e1); }

    let _ = pg.pool_query(s.pg, "delete from email_changes where account_id = $1::uuid", [pg.arg_text(account_id)], pg_until());

    // Revoke sessions
    let r_sess: result[[TokenHashRow], str] = zokor.query_all(s.pg, "delete from sessions where account_id = $1::uuid returning token_hash", [pg.arg_text(account_id)], pg_until());
    let out: [bytes] = [];
    if let rows = r_sess {
        for row in rows {
            push(out, row.token_hash);
        }
    }
    return ok(out);
}

pub fn find_account_id_by_username(s: Store, username: str) -> result[opt[str], str] {
    let r: result[[IdRow], str] = zokor.query_all(s.pg, "select id::text as id from accounts where lower(username) = lower($1)", [pg.arg_text(username)], pg_until());
    guard let rows = r else let e = err_of(r) { return err(e); }
    if len(rows) == 0 {
        let n: opt[str] = none;
        return ok(n);
    }
    return ok(some(rows[0].id));
}

pub fn grant_role_direct(s: Store, account_id: str, role: str) -> result[bool, str] {
    let q = "insert into account_roles(account_id, role) values($1::uuid, $2) on conflict do nothing";
    let r = pg.pool_query(s.pg, q, [pg.arg_text(account_id), pg.arg_text(role)], pg_until());
    guard let _ok = r else let e = err_of(r) { return err(e); }
    return ok(true);
}

pub fn revoke_role_direct(s: Store, account_id: str, role: str) -> result[bool, str] {
    let q = "delete from account_roles where account_id = $1::uuid and role = $2";
    let r = pg.pool_query(s.pg, q, [pg.arg_text(account_id), pg.arg_text(role)], pg_until());
    guard let _ok = r else let e = err_of(r) { return err(e); }
    return ok(true);
}

pub fn open_markets_for_account(s: Store, account_id: str) -> result[[str], str] {
    let q = "select distinct market_id::text as id from orders where account_id = $1::uuid and status in ('OPEN', 'PARTIAL')";
    let r: result[[IdRow], str] = zokor.query_all(s.pg, q, [pg.arg_text(account_id)], pg_until());
    guard let rows = r else let e = err_of(r) { return err(e); }
    let out: [str] = [];
    for row in rows {
        push(out, row.id);
    }
    return ok(out);
}

pub fn anonymise_account(s: Store, account_id: str, anon_username: str, anon_email: str) -> result[[bytes], str] {
    let q1 = "update accounts set " +
        "  status = 'DELETED', " +
        "  username = $1, " +
        "  email = $2, " +
        "  password_hash = null, " +
        "  google_sub = null, " +
        "  phone = null, " +
        "  leaderboard_eligible = false, " +
        "  deleted_at = coalesce(deleted_at, now()) " +
        "where id = $3::uuid";
    let r1 = pg.pool_query(s.pg, q1, [pg.arg_text(anon_username), pg.arg_text(anon_email), pg.arg_text(account_id)], pg_until());
    guard let _ok1 = r1 else let e1 = err_of(r1) { return err(e1); }

    let _ = pg.pool_query(s.pg, "delete from notification_preferences where account_id = $1::uuid", [pg.arg_text(account_id)], pg_until());

    let r_sess: result[[TokenHashRow], str] = zokor.query_all(s.pg, "delete from sessions where account_id = $1::uuid returning token_hash", [pg.arg_text(account_id)], pg_until());
    let out: [bytes] = [];
    if let rows = r_sess {
        for row in rows {
            push(out, row.token_hash);
        }
    }
    return ok(out);
}

pub fn settings_store(s: Store) -> service.SettingsStore[Store] {
    return service.SettingsStore[Store] {
        context: s,
        has_recent_totp: has_recent_totp,
        save_pending_totp: save_pending_totp,
        load_pending_totp: load_pending_totp,
        activate_totp: activate_totp,
        load_account_totp: load_account_totp,
        record_totp_step_up: record_totp_step_up,
        delete_totp: delete_totp,
        get_season_window: get_season_window,
        has_username_history_in_season: has_username_history_in_season,
        change_username: change_username_tx,
        request_email_change: request_email_change,
        verify_email_change: verify_email_change,
        apply_email_change: apply_email_change,
        find_account_id_by_username: find_account_id_by_username,
        grant_role_direct: grant_role_direct,
        revoke_role_direct: revoke_role_direct,
        open_markets_for_account: open_markets_for_account,
        anonymise_account: anonymise_account
    };
}
