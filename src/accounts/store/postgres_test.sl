import "proc";
import "time";
import "zokor";
import "../domain" as domain;

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
    let id = "a0000000-0000-0000-0000-000000000001";
    let email = "pgtest_" + zokor.new_session_id() + "@say.exchange";
    let a = domain.Account {
        id: id,
        username: some("pg_user_1"),
        email: some(email),
        phone_number: some("+2348000000001"),
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
