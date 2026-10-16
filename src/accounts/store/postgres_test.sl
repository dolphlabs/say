import "crypto";
import "encoding";
import "proc";
import "strings";
import "time";
import "zokor";
import "../domain" as domain;

fn gen_uuid() -> str {
    let rb = crypto.rand(16);
    guard let b = rb else { return "00000000-0000-0000-0000-000000000000"; }
    let h = encoding.hex_encode(b);
    return strings.slice(h, 0, 8) + "-" + strings.slice(h, 8, 12) + "-" + strings.slice(h, 12, 16) + "-" + strings.slice(h, 16, 20) + "-" + strings.slice(h, 20, 32);
}

// Against a real database when TEST_DATABASE_URL is set (the migrations
// are applied first); skipped, and says so, when it is not.
fn live() -> opt[Postgres] {
    let none_here: opt[Postgres] = none;
    let url = proc.getenv("TEST_DATABASE_URL") ?? "";
    if len(url) == 0 {
        println("skip accounts postgres tests (TEST_DATABASE_URL is not set)");
        return none_here;
    }
    let m: map[str]str = {};
    m["DATABASE_URL"] = url;
    let opened = zokor.pg_from_config(zokor.config_from_values(m));
    guard let pool = opened else let e = err_of(opened) { panic(e); }
    let ms = zokor.load_migrations("migrations", zokor.migration_limits());
    guard let loaded = ms else let e = err_of(ms) { panic(e); }
    let applied = zokor.migrate(pool, loaded, until_of(time.mono() + 30000000000));
    guard let _n = applied else let e = err_of(applied) { panic(e); }
    return some(new_postgres(pool));
}

fn test_postgres_accounts_insert_and_find() {
    guard let p = live() else { return; }
    let none_str: opt[str] = none;
    let id = gen_uuid();
    let sid = zokor.new_session_id();
    let email = "pgtest_" + sid + "@say.exchange";
    let a = domain.Account {
        id: id,
        username: some("u_" + strings.slice(sid, 0, 8)),
        email: some(email),
        phone_number: none_str,
        password_hash: none_str,
        auth_provider: "LOCAL",
        status: "ACTIVE",
        kind: "USER",
        beneficial_owner_group: none_str,
        email_verified_at: none_str,
        verified_at: none_str,
        age_confirmed_at: none_str,
        created_at: ""
    };
    let r = pg_insert(p, a);
    guard let _ok = r else let e = err_of(r) { panic(e); }

    let found = pg_find(p, "tenant", id);
    guard let got = found else let e = err_of(found) { panic(e); }
    guard let row = got else { panic("account not found"); }
    assert(row.id == id);
}

fn test_postgres_verify_email() {
    guard let p = live() else { return; }
    let none_str: opt[str] = none;
    let id = gen_uuid();
    let sid = zokor.new_session_id();
    let email = "pgverify_" + sid + "@say.exchange";
    let a = domain.Account {
        id: id,
        username: some("v_" + strings.slice(sid, 0, 8)),
        email: some(email),
        phone_number: none_str,
        password_hash: none_str,
        auth_provider: "LOCAL",
        status: "ACTIVE",
        kind: "USER",
        beneficial_owner_group: none_str,
        email_verified_at: none_str,
        verified_at: none_str,
        age_confirmed_at: none_str,
        created_at: ""
    };
    let r = pg_insert(p, a);
    guard let _ok = r else let e = err_of(r) { panic(e); }

    let unv = pg_find(p, "tenant", id);
    guard let got_unv = unv else let e = err_of(unv) { panic(e); }
    guard let row_unv = got_unv else { panic("account not found"); }
    assert(!domain.is_email_verified(row_unv));
    assert(!domain.is_verified(row_unv));

    let vr = pg_verify_email(p, "tenant", email);
    guard let _v_ok = vr else let e = err_of(vr) { panic(e); }

    let v_row = pg_find(p, "tenant", id);
    guard let got_v = v_row else let e = err_of(v_row) { panic(e); }
    guard let row_v = got_v else { panic("account not found"); }
    assert(domain.is_email_verified(row_v));
    assert(domain.is_verified(row_v));
}
