import "encoding";
import "pg";
import "redis";
import "strings";
import "time";
import "zokor";
import "../service" as service;

fn stub_exchange(s: Store, code: str, verifier: str, redirect: str) -> result[str, str] {
    return ok(fixture_good());
}

fn stub_jwks(s: Store) -> result[service.JwksDoc, str] {
    return ok(service.JwksDoc { body: fixture_jwks(), max_age_seconds: 3600 });
}

fn google_auth(l: Live, token_url: str, google_ns: int, stubbed: bool) -> service.Auth[Store] {
    let st = new_store(l.pool, l.cache,
        GoogleEndpoints { client_id: "client-1", client_secret: "s", token_url: token_url, jwks_url: token_url },
        Timeouts { pg_ns: 10000000000, redis_ns: 200000000, google_ns: google_ns });
    let port = auth_store(st);
    if stubbed {
        port.google_exchange = stub_exchange;
        port.google_jwks = stub_jwks;
    }
    return service.new_auth(port, config(), service.new_hasher(2, 64, stub_hash, stub_verify), uuid);
}

fn state_of(url: str) -> str {
    let at = strings.find(url, "&state=");
    let rest = strings.slice(url, at + 7, len(url));
    return strings.slice(rest, 0, strings.find(rest, "&"));
}

fn fix_nonce(l: Live, state: str, intent: str) {
    guard let pool = l.cache else { panic("no redis"); }
    let key = "oauth:state:" + encoding.hex_encode(service.hash_token(state));
    let d = until_of(time.mono() + 1000000000);
    let cr = redis.acquire(pool, d);
    guard let conn = cr else { panic("redis"); }
    let body = "{\"nonce\":\"fixed-nonce-7701\",\"verifier\":\"v\",\"intent\":\"" + intent + "\",\"account_id\":\"\"}";
    let r = redis.set_ex(conn, key, 600, to_bytes(body), d);
    redis.release(pool, conn);
    guard let _ok = r else { panic("redis set"); }
}

// The fixtures name one Google subject and email, so a rerun against the
// same database first moves the previous run's account out of the way.
fn forget_fixture_identity(l: Live) {
    let d = until_of(time.mono() + 5000000000);
    let empty: [pg.Arg] = [];
    for sql in [
        "delete from auth_identities where subject = 'google-sub-7701'",
        "update accounts set email = id::text || '@moved.test', username = 'mv' || left(md5(id::text), 12) " +
        "where email = 'g.tester@gmail.com'"
    ] {
        let r = pg.pool_query(l.pool, sql, empty, d);
        guard let _r = r else let e = err_of(r) { panic(e); }
    }
}

fn test_should_create_a_verified_granted_account_through_google() {
    guard let l = live() else { return; }
    forget_fixture_identity(l);
    let a = google_auth(l, "http://127.0.0.1:9/token", 1000000000, true);
    let sr = service.google_start(a, "signup", "");
    guard let url = sr else let f = err_of(sr) { panic(inspect(f.why)); }
    let state = state_of(url);
    fix_nonce(l, state, "signup");
    let cr = service.google_callback(a, state, "code", meta_from("10.11.0.1"));
    guard let cb = cr else let f = err_of(cr) { panic(inspect(f.why) + " " + f.detail); }
    assert(cb.kind == service.CallbackKind.Pending);
    let name = "gg" + suffix();
    let hr = service.hold_username(a, name, "10.11.0.1");
    guard let hold = hr else { panic("hold"); }
    let done = service.google_complete(a, cb.pending_token, name, hold.hold_id, meta_from("10.11.0.1"));
    guard let s = done else let f = err_of(done) { panic(inspect(f.why) + " " + f.detail); }
    guard let grant = s.grant else { panic("no grant"); }
    assert(grant.amount == 1000);
    assert(s.account.email_verified && s.account.google_linked);
    let id = s.account.id;
    assert(count(l.pool, "select free_units as n from wallets where account_id = $1", id) == 1000);
    assert(count(l.pool, "select count(*)::bigint as n from auth_identities where account_id = $1", id) == 1);
    guard let _sess = session_of(a, s.session_token) else { panic("no session"); }

    let again = service.google_complete(a, cb.pending_token, name, hold.hold_id, meta_from("10.11.0.1"));
    guard let _x = again else let f = err_of(again) {
        assert(f.why == service.Why.PendingExpired, inspect(f.why));
        return;
    }
    panic("pending google signup completed twice");
}

fn test_should_time_out_on_google_cleanly_and_create_nothing() {
    guard let l = live() else { return; }
    let a = google_auth(l, "http://10.255.255.1/token", 300000000, false);
    let sr = service.google_start(a, "signup", "");
    guard let url = sr else let f = err_of(sr) { panic(inspect(f.why)); }
    let state = state_of(url);
    let before = count(l.pool, "select count(*)::bigint as n from accounts where kind = $1", "USER");
    let t0 = time.mono();
    let cr = service.google_callback(a, state, "code", meta_from("10.11.0.2"));
    let took_ms = ((time.mono() - t0) as int) / 1000000;
    guard let _x = cr else let f = err_of(cr) {
        assert(f.why == service.Why.GoogleFailed, inspect(f.why));
        assert(took_ms < 3000, "timeout took " + to_str(took_ms) + " ms");
        assert(count(l.pool, "select count(*)::bigint as n from accounts where kind = $1", "USER") == before);
        return;
    }
    panic("callback succeeded without google");
}
