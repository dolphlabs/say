import "crypto";
import "encoding";
import "pg";
import "proc";
import "redis";
import "strings";
import "time";
import "timez";
import "zokor";
import "../domain" as domain;
import "../service" as service;

fn dl() -> until {
    return until_of(time.mono() + 60000000000);
}

fn at(s: str) -> timez.Time {
    let r = timez.parse_rfc3339(s);
    guard let t = r else let e = err_of(r) { panic(e); }
    return t;
}

fn anchor() -> timez.Time {
    return at("2026-10-11T23:00:00Z");
}

fn open_pool(url: str, size: int) -> pg.Pool {
    let m: map[str]str = {};
    m["DATABASE_URL"] = url;
    m["DB_POOL_SIZE"] = to_str(size);
    let r = zokor.pg_from_config(zokor.config_from_values(m));
    guard let pool = r else let e = err_of(r) { panic(e); }
    return pool;
}

fn run(pool: pg.Pool, sql: str) {
    let none_args: [pg.Arg] = [];
    let r = pg.pool_query(pool, sql, none_args, dl());
    guard let _rows = r else let e = err_of(r) { panic(sql + ": " + e); }
}

gc struct Env {
    name: str,
    base: pg.Pool,
    owner: pg.Pool,
    app: pg.Pool,
    store: Postgres,
    app_url: str
}

// A database of its own, migrated by the owner and used as say_api, so a
// test can move the season clock without disturbing any other test.
fn fresh_env() -> opt[Env] {
    let none_env: opt[Env] = none;
    let owner_url = proc.getenv("TEST_DATABASE_URL") ?? "";
    let app_url = proc.getenv("TEST_APP_DATABASE_URL") ?? "";
    if len(owner_url) == 0 || len(app_url) == 0 {
        println("skip ledger postgres tests (TEST_DATABASE_URL / TEST_APP_DATABASE_URL not set)");
        return none_env;
    }
    let rb = crypto.rand(5);
    guard let b = rb else { panic("rand"); }
    let name = "say_t_" + encoding.hex_encode(b);
    let base = open_pool(owner_url, 2);
    run(base, "create database " + name);
    let owner = open_pool(strings.replace(owner_url, "/say_test?", "/" + name + "?"), 4);
    let ms = zokor.load_migrations("migrations", zokor.migration_limits());
    guard let loaded = ms else let e = err_of(ms) { panic(e); }
    let applied = zokor.migrate(owner, loaded, dl());
    guard let _n = applied else let e = err_of(applied) { panic(e); }
    let url = strings.replace(app_url, "/say_test?", "/" + name + "?");
    let app = open_pool(url, 40);
    let none_redis: opt[redis.Pool] = none;
    return some(Env { name: name, base: base, owner: owner, app: app,
                      store: new_postgres(app, none_redis, 10000000000, 50000000), app_url: url });
}

fn drop_env(e: Env) {
    zokor.pg_close(e.app);
    zokor.pg_close(e.owner);
    run(e.base, "drop database " + e.name + " with (force)");
    zokor.pg_close(e.base);
}

gc struct NRow {
    n: int
}

gc struct TRow {
    t: str
}

fn int_of(pool: pg.Pool, sql: str, args: [pg.Arg]) -> int {
    let r: result[[NRow], str] = zokor.query_all(pool, sql, args, dl());
    guard let rows = r else let e = err_of(r) { panic(sql + ": " + e); }
    if len(rows) == 0 {
        return -1;
    }
    return rows[0].n;
}

fn text_of(pool: pg.Pool, sql: str, args: [pg.Arg]) -> str {
    let r: result[[TRow], str] = zokor.query_all(pool, sql, args, dl());
    guard let rows = r else let e = err_of(r) { panic(sql + ": " + e); }
    if len(rows) == 0 {
        return "";
    }
    return rows[0].t;
}

fn tick(e: Env, now: str) -> service.TickReport {
    let r = st_tick(e.store, at(now), anchor());
    guard let rep = r else let x = err_of(r) { panic("tick: " + x); }
    return rep;
}

fn season_id(e: Env, ordinal: int) -> str {
    return text_of(e.app, "select id::text as t from seasons where ordinal = $1", [pg.arg_int(ordinal)]);
}

fn status_of(e: Env, ordinal: int) -> str {
    return text_of(e.app, "select status as t from seasons where ordinal = $1", [pg.arg_int(ordinal)]);
}

fn new_user(e: Env) -> str {
    let rb = crypto.rand(8);
    guard let b = rb else { panic("rand"); }
    let name = "u" + encoding.hex_encode(b);
    let email = name + "@test.say";
    return text_of(e.app,
        "insert into accounts (username, email, status, email_verified_at) values ($1, $2, 'ACTIVE', now()) returning id::text as t",
        [pg.arg_text(name), pg.arg_text(email)]);
}

fn new_operator(e: Env) -> str {
    let id = new_user(e);
    run_args(e.app, "insert into account_roles (account_id, role) values ($1::uuid, 'admin')", [pg.arg_text(id)]);
    return id;
}

fn run_args(pool: pg.Pool, sql: str, args: [pg.Arg]) {
    let r = pg.pool_query(pool, sql, args, dl());
    guard let _rows = r else let e = err_of(r) { panic(sql + ": " + e); }
}

fn approve(e: Env, amount: int, cap: int) -> str {
    let a = new_operator(e);
    let b = new_operator(e);
    let pr = st_policy_propose(e.store, amount, cap, a);
    guard let id = pr else let x = err_of(pr) { panic(x); }
    let r1 = st_policy_approve(e.store, id, a);
    guard let v1 = r1 else let x = err_of(r1) { panic(x); }
    assert(v1.status == "PROPOSED", inspect(v1));
    let r2 = st_policy_approve(e.store, id, b);
    guard let v2 = r2 else let x = err_of(r2) { panic(x); }
    assert(v2.status == "APPROVED", inspect(v2));
    return id;
}

// An active season 1 with an approved S 1,000 policy.
fn ready() -> opt[Env] {
    guard let e = fresh_env() else {
        let none_env: opt[Env] = none;
        return none_env;
    }
    let _r = tick(e, "2026-10-12T10:00:00Z");
    let _p = approve(e, 1000, 100000000);
    return some(e);
}

gc struct PostArg {
    txs: [domain.LedgerTx],
    twice: bool
}

fn post_body(c: pg.Conn, a: PostArg) -> result[[domain.Posted], str] {
    let r = post_many(c, a.txs, dl());
    guard let ps = r else let e = err_of(r) {
        return err(domain.encode(e));
    }
    if a.twice {
        let again = post_many(c, a.txs, dl());
        guard let _p = again else let e = err_of(again) {
            return err(domain.encode(e));
        }
    }
    return ok(ps);
}

fn post_tx(e: Env, tx: domain.LedgerTx) -> result[domain.Posted, domain.LedgerError] {
    let r = zokor.transaction(e.app, PostArg { txs: [tx], twice: false }, post_body, dl());
    guard let ps = r else let x = err_of(r) {
        return err(domain.decode(x));
    }
    return ok(ps[0]);
}

fn must_post(e: Env, tx: domain.LedgerTx) -> domain.Posted {
    let r = post_tx(e, tx);
    guard let p = r else let x = err_of(r) { panic(inspect(x)); }
    return p;
}

fn adjust(season: str, key: str, from: domain.Owner, to: domain.Owner, amount: int) -> domain.LedgerTx {
    let none_holds: [domain.HoldOp] = [];
    return domain.LedgerTx { business_key: key, kind: "ADJUSTMENT", season_id: season, market_id: "", ref_type: "test",
                             ref_id: key, metadata: "{}", entries: [domain.free(from, domain.sedi(), 0 - amount),
                             domain.free(to, domain.sedi(), amount)], holds: none_holds };
}

fn fund(e: Env, season: str, account: str, amount: int) {
    let _p = must_post(e, adjust(season, "fund:" + account + ":" + to_str(amount), domain.treasury(), domain.user(account), amount));
}

gc struct WalletNums {
    free_units: int,
    held_units: int
}

fn wallet(e: Env, season: str, account: str) -> WalletNums {
    let r: result[[WalletNums], str] = zokor.query_all(e.app,
        "select free_units, held_units from wallets where season_id = $1::uuid and owner_id = $2 and asset_key = 'SEDI'",
        [pg.arg_text(season), pg.arg_text(account)], dl());
    guard let rows = r else let x = err_of(r) { panic(x); }
    if len(rows) == 0 {
        return WalletNums { free_units: 0, held_units: 0 };
    }
    return rows[0];
}

gc struct GrantArg {
    account: str,
    season: str,
    lock_issuance: bool
}

fn grant_body(c: pg.Conn, a: GrantArg) -> result[int, str] {
    if a.lock_issuance {
        let lr = pg.query(c, "select id from wallets where season_id = $1::uuid and owner_id = 'system:issuance' for update",
                          [pg.arg_text(a.season)], dl());
        guard let _l = lr else let x = err_of(lr) { return err(x); }
    }
    let r = grant_season_allowance(c, a.account, a.season, dl());
    guard let found = r else let x = err_of(r) {
        return err(domain.encode(x));
    }
    guard let g = found else {
        return ok(0);
    }
    return ok(g.amount);
}

fn grant(e: Env, account: str, season: str) -> int {
    let r = zokor.transaction(e.app, GrantArg { account: account, season: season, lock_issuance: false }, grant_body, dl());
    guard let n = r else let x = err_of(r) { panic(x); }
    return n;
}

fn recon(e: Env) -> service.ReconRun {
    let r = st_recon_run(e.store, true);
    guard let found = r else let x = err_of(r) { panic(x); }
    guard let run = found else { panic("no run"); }
    return run;
}

fn assert_books_balance(e: Env, context: str) {
    let run = recon(e);
    if let good = run.ok {
        if good {
            return;
        }
    }
    panic(context + ": " + inspect(run.checks));
}

// ---- restricted role ----

fn test_should_refuse_journal_rewrites_to_the_runtime_role() {
    guard let e = fresh_env() else { return; }
    let none_args: [pg.Arg] = [];
    let u = pg.pool_query(e.app, "update ledger_entries set delta = 1", none_args, dl());
    guard let _x = u else let x = err_of(u) {
        assert(strings.contains(x, "permission denied"), x);
        let d = pg.pool_query(e.app, "delete from ledger_transactions", none_args, dl());
        if let _y = d {
            panic("delete allowed");
        }
        drop_env(e);
        return;
    }
    panic("update allowed");
}

// ---- seasons ----

fn test_should_bootstrap_season_one_and_schedule_the_next() {
    guard let e = fresh_env() else { return; }
    let rep = tick(e, "2026-10-12T10:00:00Z");
    assert(len(rep.steps) == 1 && rep.steps[0].ordinal == 1 && rep.steps[0].to == "ACTIVE", inspect(rep));
    assert(status_of(e, 1) == "ACTIVE");
    assert(status_of(e, 2) == "SCHEDULED");
    assert(text_of(e.app, "select starts_at::text as t from seasons where ordinal = 2", no_args()) == "2026-10-25 23:00:00+00");
    assert(len(rep.rollover) > 0, "season 1 should get a rollover");
    let again = tick(e, "2026-10-12T10:00:00Z");
    assert(len(again.steps) == 0, inspect(again));
    assert(int_of(e.app, "select count(*)::bigint as n from wallets where owner_kind = 'system'", no_args()) == 3);
    drop_env(e);
}

fn test_should_cross_a_boundary_in_order_exactly_once() {
    guard let e = fresh_env() else { return; }
    let _a = tick(e, "2026-10-12T10:00:00Z");
    let before = tick(e, "2026-10-25T22:59:59.999Z");
    assert(len(before.steps) == 0);
    let rep = tick(e, "2026-10-25T23:00:00Z");
    assert(len(rep.steps) == 2, inspect(rep));
    assert(rep.steps[0].ordinal == 1 && rep.steps[0].to == "CLOSING");
    assert(rep.steps[1].ordinal == 2 && rep.steps[1].to == "ACTIVE");
    assert(inspect(rep.closed) == "[1]", inspect(rep.closed));
    assert(status_of(e, 1) == "CLOSED" && status_of(e, 2) == "ACTIVE" && status_of(e, 3) == "SCHEDULED");
    let again = tick(e, "2026-10-25T23:00:01Z");
    assert(len(again.steps) == 0 && len(again.closed) == 0);
    assert(int_of(e.app, "select count(*)::bigint as n from outbox_events where type = 'season.started'", no_args()) == 2);
    assert(int_of(e.app, "select count(*)::bigint as n from outbox_events where type = 'season.closing'", no_args()) == 1);
    assert(int_of(e.app, "select count(*)::bigint as n from outbox_events where type = 'season.closed'", no_args()) == 1);
    drop_env(e);
}

fn test_should_stay_closing_while_holds_are_open() {
    guard let e = ready() else { return; }
    let s1 = season_id(e, 1);
    let u = new_user(e);
    assert(grant(e, u, s1) == 1000);
    let hr = zokor.transaction(e.app, HoldArg { owner: u, season: s1, amount: 10, key: "hold:closing" }, hold_body, dl());
    guard let hold_id = hr else let x = err_of(hr) { panic(x); }
    let rep = tick(e, "2026-10-25T23:00:00Z");
    assert(status_of(e, 1) == "CLOSING" && len(rep.closed) == 0, inspect(rep));
    let late = post_tx(e, domain.hold_tx(domain.user(u), s1, domain.sedi(), 5, "order", "late", "hold:late", "{}"));
    guard let _l = late else let x = err_of(late) {
        assert(x.fault == domain.Fault.SeasonNotActive, inspect(x));
        let rr = zokor.transaction(e.app, ReleaseArg { hold: hold_id, amount: 10, key: "release:closing" }, release_body, dl());
        guard let _r = rr else let y = err_of(rr) { panic("release in CLOSING: " + y); }
        let after = tick(e, "2026-10-25T23:01:00Z");
        assert(inspect(after.closed) == "[1]", inspect(after));
        drop_env(e);
        return;
    }
    panic("hold accepted while CLOSING");
}

fn test_should_catch_up_on_boot_and_grant_only_the_live_season() {
    guard let e = fresh_env() else { return; }
    let rep = tick(e, "2026-11-09T00:00:00Z");
    assert(len(rep.steps) == 5, inspect(rep));
    assert(status_of(e, 1) == "CLOSED" && status_of(e, 2) == "CLOSED" && status_of(e, 3) == "ACTIVE");
    assert(status_of(e, 4) == "SCHEDULED");
    assert(int_of(e.app, "select count(*)::bigint as n from grant_runs", no_args()) == 1);
    assert(rep.rollover == season_id(e, 3));
    drop_env(e);
}

fn test_should_refuse_to_schedule_against_a_different_anchor() {
    guard let e = fresh_env() else { return; }
    let _a = tick(e, "2026-10-12T10:00:00Z");
    let r = st_tick(e.store, at("2026-10-12T10:00:00Z"), at("2026-10-12T23:00:00Z"));
    if let _x = r {
        panic("moved anchor accepted");
    }
    drop_env(e);
}

fn test_should_let_only_one_instance_hold_a_lease() {
    guard let e = fresh_env() else { return; }
    let other = new_postgres(open_pool(e.app_url, 4), e.store.redis, 10000000000, 50000000);
    let ar = st_lease_try(e.store, service.lock_seasons());
    guard let a = ar else let x = err_of(ar) { panic(x); }
    guard let first = a else { panic("first lease refused"); }
    let br = st_lease_try(other, service.lock_seasons());
    guard let b = br else let x = err_of(br) { panic(x); }
    if let _second = b {
        panic("two instances hold the seasons lease");
    }
    st_lease_release(e.store, first);
    let cr = st_lease_try(other, service.lock_seasons());
    guard let c = cr else let x = err_of(cr) { panic(x); }
    guard let third = c else { panic("lease not released"); }
    st_lease_release(other, third);
    zokor.pg_close(other.pool);
    drop_env(e);
}

// ---- grants ----

fn test_should_grant_once_per_account_and_season() {
    guard let e = ready() else { return; }
    let s1 = season_id(e, 1);
    let u = new_user(e);
    assert(grant(e, u, s1) == 1000);
    assert(grant(e, u, s1) == 1000);
    assert(int_of(e.app, "select count(*)::bigint as n from issuance_grants where account_id = $1::uuid", [pg.arg_text(u)]) == 1);
    assert(wallet(e, s1, u).free_units == 1000);
    assert(int_of(e.app, "select coalesce(sum(delta), 0)::bigint as n from ledger_entries", no_args()) == 0);
    let ar = st_aggregate(e.store);
    guard let _n = ar else let x = err_of(ar) { panic(x); }
    assert(int_of(e.app, "select balance as n from system_balances where owner_id = 'system:issuance'", no_args()) == -1000);
    assert_books_balance(e, "after one grant");
    drop_env(e);
}

fn test_should_not_grant_without_an_approved_policy() {
    guard let e = fresh_env() else { return; }
    let _t = tick(e, "2026-10-12T10:00:00Z");
    let s1 = season_id(e, 1);
    let u = new_user(e);
    assert(grant(e, u, s1) == 0);
    assert(int_of(e.app, "select count(*)::bigint as n from issuance_grants", no_args()) == 0);
    let op = new_operator(e);
    let pr = st_policy_propose(e.store, 1000, 5000, op);
    guard let id = pr else let x = err_of(pr) { panic(x); }
    let _a1 = st_policy_approve(e.store, id, op);
    let again = st_policy_approve(e.store, id, op);
    guard let v = again else let x = err_of(again) { panic(x); }
    assert(v.status == "PROPOSED" && len(v.approvals) == 1, "one operator approved twice: " + inspect(v));
    let stranger = new_user(e);
    if let _p = st_policy_propose(e.store, 1000, 5000, stranger) {
        panic("non-operator proposed a policy");
    }
    drop_env(e);
}

fn test_should_stop_at_the_season_cap_and_post_nothing_past_it() {
    guard let e = fresh_env() else { return; }
    let _t = tick(e, "2026-10-12T10:00:00Z");
    let _p = approve(e, 1000, 2000);
    let s1 = season_id(e, 1);
    assert(grant(e, new_user(e), s1) == 1000);
    assert(grant(e, new_user(e), s1) == 1000);
    assert(grant(e, new_user(e), s1) == 0);
    assert(int_of(e.app, "select count(*)::bigint as n from issuance_grants", no_args()) == 2);
    assert(int_of(e.app, "select coalesce(sum(remaining), -1)::bigint as n from issuance_budget", no_args()) == 0);
    assert_books_balance(e, "at the cap");
    drop_env(e);
}

fn grant_one(e: Env, account: str, season: str) -> int {
    return grant(e, account, season);
}

fn chunk_one(e: Env, account: str, season: str) -> int {
    let r = st_grant_chunk(e.store, season, [account]);
    guard let c = r else let x = err_of(r) { panic(x); }
    return c.granted;
}

fn test_should_grant_once_when_verification_and_rollover_race() {
    guard let e = ready() else { return; }
    let s1 = season_id(e, 1);
    let _run = st_grant_run(e.store, s1);
    for i in 0..20 {
        let u = new_user(e);
        let a = spawn grant_one(e, u, s1);
        let b = spawn chunk_one(e, u, s1);
        let _ra = join_wait(a);
        let _rb = join_wait(b);
        assert(int_of(e.app, "select count(*)::bigint as n from issuance_grants where account_id = $1::uuid", [pg.arg_text(u)]) == 1);
        assert(wallet(e, s1, u).free_units == 1000, "round " + to_str(i));
    }
    assert_books_balance(e, "after races");
    drop_env(e);
}

// ---- posting ----

gc struct HoldArg {
    owner: str,
    season: str,
    amount: int,
    key: str
}

fn hold_body(c: pg.Conn, a: HoldArg) -> result[str, str] {
    let r = hold(c, domain.user(a.owner), a.season, domain.sedi(), a.amount, "order", a.key, a.key, dl());
    guard let id = r else let x = err_of(r) {
        return err(domain.encode(x));
    }
    return ok(id);
}

gc struct ReleaseArg {
    hold: str,
    amount: int,
    key: str
}

fn release_body(c: pg.Conn, a: ReleaseArg) -> result[int, str] {
    let r = release(c, a.hold, a.amount, a.key, dl());
    guard let p = r else let x = err_of(r) {
        return err(domain.encode(x));
    }
    return ok(p.tx_id);
}

gc struct ConsumeArg {
    hold: str,
    amount: int,
    to: str,
    key: str
}

fn consume_body(c: pg.Conn, a: ConsumeArg) -> result[int, str] {
    let r = consume(c, a.hold, a.amount, "FILL",
                    [domain.free(domain.user(a.to), domain.sedi(), a.amount - 1), domain.free(domain.fees(), domain.sedi(), 1)],
                    a.key, dl());
    guard let p = r else let x = err_of(r) {
        return err(domain.encode(x));
    }
    return ok(p.tx_id);
}

fn fault(r: result[int, str]) -> str {
    guard let _v = r else let x = err_of(r) {
        return domain.fault_name(domain.decode(x).fault);
    }
    return "ok";
}

fn test_should_hold_release_and_consume_against_one_hold() {
    guard let e = ready() else { return; }
    let s1 = season_id(e, 1);
    let a = new_user(e);
    let b = new_user(e);
    assert(grant(e, a, s1) == 1000);
    let hr = zokor.transaction(e.app, HoldArg { owner: a, season: s1, amount: 300, key: "o1" }, hold_body, dl());
    guard let h = hr else let x = err_of(hr) { panic(x); }
    assert(wallet(e, s1, a).free_units == 700 && wallet(e, s1, a).held_units == 300);
    assert(fault(zokor.transaction(e.app, ReleaseArg { hold: h, amount: 100, key: "o1:r1" }, release_body, dl())) == "ok");
    assert(fault(zokor.transaction(e.app, ReleaseArg { hold: h, amount: 201, key: "o1:r2" }, release_body, dl())) == "HoldExceeded");
    assert(fault(zokor.transaction(e.app, ConsumeArg { hold: h, amount: 200, to: b, key: "o1:f1" }, consume_body, dl())) == "ok");
    assert(wallet(e, s1, a).free_units == 800 && wallet(e, s1, a).held_units == 0);
    assert(wallet(e, s1, b).free_units == 199);
    assert(text_of(e.app, "select status as t from holds where id = $1::uuid", [pg.arg_text(h)]) == "closed");
    assert(fault(zokor.transaction(e.app, ReleaseArg { hold: h, amount: 1, key: "o1:r3" }, release_body, dl())) == "HoldNotOpen");
    assert(int_of(e.app, "select held_after as n from ledger_entries e join ledger_transactions t on t.id = e.transaction_id " +
                         "where t.business_key = 'o1:f1' and e.bucket = 'held'", no_args()) == 0);
    assert_books_balance(e, "after hold lifecycle");
    drop_env(e);
}

fn test_should_refuse_an_overdraft_with_the_amounts() {
    guard let e = ready() else { return; }
    let s1 = season_id(e, 1);
    let a = new_user(e);
    assert(grant(e, a, s1) == 1000);
    let r = post_tx(e, domain.hold_tx(domain.user(a), s1, domain.sedi(), 1001, "order", "big", "hold:big", "{}"));
    guard let _p = r else let x = err_of(r) {
        assert(x.fault == domain.Fault.InsufficientFunds && x.needed == 1001 && x.available == 1000, inspect(x));
        assert(wallet(e, s1, a).free_units == 1000);
        drop_env(e);
        return;
    }
    panic("overdraft accepted");
}

fn test_should_refuse_a_second_post_in_one_transaction() {
    guard let e = ready() else { return; }
    let s1 = season_id(e, 1);
    let a = new_user(e);
    fund(e, s1, a, 50);
    let r = zokor.transaction(e.app, PostArg { txs: [adjust(s1, "twice", domain.user(a), domain.fees(), 5)], twice: true },
                              post_body, dl());
    guard let _p = r else let x = err_of(r) {
        assert(domain.decode(x).fault == domain.Fault.Malformed, x);
        drop_env(e);
        return;
    }
    panic("two posts in one transaction accepted");
}

fn test_should_refuse_a_missing_system_wallet() {
    guard let e = ready() else { return; }
    let s1 = season_id(e, 1);
    let a = new_user(e);
    fund(e, s1, a, 50);
    let m = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    let r = post_tx(e, adjust(s1, "nowhere", domain.user(a), domain.collateral(m), 5));
    guard let _p = r else let x = err_of(r) {
        assert(x.fault == domain.Fault.WalletNotFound, inspect(x));
        drop_env(e);
        return;
    }
    panic("posted to a missing system wallet");
}

fn post_same(e: Env, tx: domain.LedgerTx) -> str {
    let r = post_tx(e, tx);
    guard let p = r else let x = err_of(r) {
        return "err:" + domain.fault_name(x.fault);
    }
    return p.public_id;
}

fn test_should_post_one_transaction_for_fifty_identical_retries() {
    guard let e = ready() else { return; }
    let s1 = season_id(e, 1);
    let a = new_user(e);
    let b = new_user(e);
    fund(e, s1, a, 100);
    let tx = adjust(s1, "pay:1", domain.user(a), domain.user(b), 10);
    let hs: [join[str]] = [];
    for i in 0..50 {
        push(hs, spawn post_same(e, tx));
    }
    let first = "";
    for h in hs {
        let r = join_wait(h);
        guard let id = r else let x = err_of(r) { panic(x); }
        assert(!strings.has_prefix(id, "err:"), id);
        if len(first) == 0 {
            first = id;
        }
        assert(id == first, "two transactions for one key");
    }
    assert(int_of(e.app, "select count(*)::bigint as n from ledger_transactions where business_key = 'pay:1'", no_args()) == 1);
    assert(wallet(e, s1, b).free_units == 10);
    let changed = adjust(s1, "pay:1", domain.user(a), domain.user(b), 11);
    assert(post_same(e, changed) == "err:IdempotencyConflict");
    let relabelled = adjust(s1, "pay:1", domain.user(a), domain.user(b), 10);
    relabelled.metadata = "{\"note\":\"retry with new text\"}";
    assert(post_same(e, relabelled) == first);
    drop_env(e);
}

// ---- concurrency ----

fn hold_seven(e: Env, owner: str, season: str, i: int) -> str {
    let r = zokor.transaction(e.app, HoldArg { owner: owner, season: season, amount: 7, key: "spend:" + to_str(i) }, hold_body, dl());
    guard let _id = r else let x = err_of(r) {
        return domain.fault_name(domain.decode(x).fault);
    }
    return "ok";
}

fn test_should_allow_exactly_142_holds_of_seven_from_a_thousand() {
    guard let e = ready() else { return; }
    let s1 = season_id(e, 1);
    let a = new_user(e);
    assert(grant(e, a, s1) == 1000);
    let hs: [join[str]] = [];
    for i in 0..200 {
        push(hs, spawn hold_seven(e, a, s1, i));
    }
    let good = 0;
    let short = 0;
    for h in hs {
        let r = join_wait(h);
        guard let out = r else let x = err_of(r) { panic(x); }
        if out == "ok" {
            good += 1;
        } else if out == "InsufficientFunds" {
            short += 1;
        } else {
            panic("unexpected " + out);
        }
    }
    assert(good == 142 && short == 58, to_str(good) + " ok, " + to_str(short) + " short");
    let w = wallet(e, s1, a);
    assert(w.free_units == 6 && w.held_units == 994, inspect(w));
    assert_books_balance(e, "after double spend");
    drop_env(e);
}

// Deterministic picks: byte k of sha256("seed:i").
fn pick(seed: int, i: int, k: int, n: int) -> int {
    let h = crypto.sha256(to_bytes(to_str(seed) + ":" + to_str(i)));
    return ((h[k] as int) * 256 + (h[k + 1] as int)) % n;
}

fn transfer(e: Env, season: str, users: [str], i: int, seed: int) -> str {
    let from = pick(seed, i, 0, len(users));
    let to = pick(seed, i, 2, len(users) - 1);
    if to >= from {
        to += 1;
    }
    let amount = 1 + pick(seed, i, 4, 5);
    let r = post_tx(e, adjust(season, "x:" + to_str(i), domain.user(users[from]), domain.user(users[to]), amount));
    guard let _p = r else let y = err_of(r) {
        return domain.fault_name(y.fault) + " " + y.detail;
    }
    return "ok";
}


fn test_should_never_deadlock_on_crossing_transfers() {
    guard let e = ready() else { return; }
    let s1 = season_id(e, 1);
    let users: [str] = [];
    for i in 0..10 {
        let u = new_user(e);
        fund(e, s1, u, 1000);
        push(users, u);
    }
    let hs: [join[str]] = [];
    for i in 0..1000 {
        push(hs, spawn transfer(e, s1, users, i, 42));
    }
    let good = 0;
    let sample = "";
    for h in hs {
        let r = join_wait(h);
        guard let out = r else let x = err_of(r) { panic(x); }
        if out == "ok" {
            good += 1;
        } else {
            sample = out;
            assert(strings.has_prefix(out, "InsufficientFunds"), out);
        }
    }
    assert(good == 1000, to_str(good) + " transfers posted; " + sample);
    let total = 0;
    for u in users {
        total += wallet(e, s1, u).free_units;
    }
    assert(total == 10000, "total " + to_str(total));
    assert_books_balance(e, "after crossing transfers");
    drop_env(e);
}

fn test_should_halt_trading_when_a_cached_balance_is_corrupted() {
    guard let e = ready() else { return; }
    let s1 = season_id(e, 1);
    let a = new_user(e);
    assert(grant(e, a, s1) == 1000);
    assert_books_balance(e, "before corruption");
    run_args(e.owner, "update wallets set free_units = free_units + 1 where owner_id = $1", [pg.arg_text(a)]);
    let run = recon(e);
    assert((run.ok ?? true) == false, inspect(run));
    let failed = false;
    for ck in run.checks {
        if ck.name == "cached_balances" {
            failed = ck.status == "failed" && ck.count == 1;
        }
    }
    assert(failed, inspect(run.checks));
    let hr = st_halt_state(e.store);
    guard let h = hr else let x = err_of(hr) { panic(x); }
    assert(h.halted, inspect(h));
    assert(int_of(e.app, "select count(*)::bigint as n from outbox_events where type = 'reconciliation.failed'", no_args()) == 1);
    let op = new_operator(e);
    let cr = st_halt_clear(e.store, op, "fixed the wallet by hand");
    guard let _c = cr else let x = err_of(cr) { panic(x); }
    let after = st_halt_state(e.store);
    guard let h2 = after else let x = err_of(after) { panic(x); }
    assert(!h2.halted);
    assert(int_of(e.app, "select count(*)::bigint as n from audit_events where action = 'trading_halt.clear'", no_args()) == 1);
    drop_env(e);
}

fn no_args() -> [pg.Arg] {
    let none_args: [pg.Arg] = [];
    return none_args;
}
