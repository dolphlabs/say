import "crypto";
import "encoding";
import "pg";
import "proc";
import "strings";
import "time";
import "zokor";
import "../domain" as domain;

pub fn test_treasury_store_helpers() {
    let _dl = pg_deadline();
    assert(true);
}


gc struct TestText { val: str }

fn open_test_pool(url: str) -> pg.Pool {
    let cfg: map[str]str = {};
    cfg["DATABASE_URL"] = url;
    let opened = zokor.pg_from_config(zokor.config_from_values(cfg));
    guard let pool = opened else let e = err_of(opened) { panic(e); }
    return pool;
}

fn run_test_sql(pool: pg.Pool, sql: str) {
    let args: [pg.Arg] = [];
    let query_result = pg.pool_query(pool, sql, args, until_of(time.mono() + 30000000000));
    guard let _ok = query_result else let e = err_of(query_result) { panic(e); }
}

fn read_test_value(pool: pg.Pool, sql: str) -> str {
    let args: [pg.Arg] = [];
    let query_result: result[[TestText], str] = zokor.query_all(pool, sql, args, until_of(time.mono() + 30000000000));
    guard let rows = query_result else let e = err_of(query_result) { panic(e); }
    assert(len(rows) == 1);
    return rows[0].val;
}

fn test_global_bot_pause_preserves_other_states_and_halt_reason() {
    let url = proc.getenv("TEST_DATABASE_URL") ?? "";
    let app_url = proc.getenv("TEST_APP_DATABASE_URL") ?? "";
    if len(url) == 0 || len(app_url) == 0 { println("skip treasury pause integration test (test database URLs not set)"); return; }
    let random = crypto.rand(5);
    guard let random_bytes = random else { panic("random database name unavailable"); }
    let name = "say_treasury_" + encoding.hex_encode(random_bytes);
    let base = open_test_pool(url);
    run_test_sql(base, "create database " + name);
    let pool = open_test_pool(strings.replace(url, "/say_test?", "/" + name + "?"));
    let migrations = zokor.load_migrations("migrations", zokor.migration_limits());
    guard let loaded = migrations else let e = err_of(migrations) { panic(e); }
    let applied = zokor.migrate(pool, loaded, until_of(time.mono() + 60000000000));
    guard let _done = applied else let e = err_of(applied) { panic(e); }
    run_test_sql(pool, "insert into accounts(id,username,status,kind) values ('00000000-0000-4000-8000-000000000001','test_operator','ACTIVE','USER'),('00000000-0000-4000-8000-000000000002','test_bot_one','ACTIVE','USER'),('00000000-0000-4000-8000-000000000003','test_bot_two','ACTIVE','USER')");
    run_test_sql(pool, "insert into seasons(id,ordinal,starts_at,ends_at,status) values ('00000000-0000-4000-8000-000000000004',999,'2026-01-01T00:00:00Z','2026-01-15T00:00:00Z','CLOSED')");
    run_test_sql(pool, "insert into markets(id,slug,status,created_by,tick) values ('00000000-0000-4000-8000-000000000005','test-market','DRAFT','00000000-0000-4000-8000-000000000001',1)");
    run_test_sql(pool, "insert into bot_markets(bot_id,market_id,season_id,status) values ('00000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000005','00000000-0000-4000-8000-000000000004','QUOTING'),('00000000-0000-4000-8000-000000000003','00000000-0000-4000-8000-000000000005','00000000-0000-4000-8000-000000000004','PAUSED_MANUAL')");
    run_test_sql(pool, "update trading_halt set halted=true, reason='ledger incident' where id=1");
    let app_pool = open_test_pool(strings.replace(app_url, "/say_test?", "/" + name + "?"));
    let store = make_postgres_treasury_store(app_pool);
    let paused = pg_set_all_paused(store, true, "operator pause");
    guard let _p = paused else let e = err_of(paused) { panic(e); }
    assert(read_test_value(pool, "select bots_paused::text as val from trading_halt where id=1") == "true");
    assert(read_test_value(pool, "select status as val from bot_markets where bot_id='00000000-0000-4000-8000-000000000002'") == "PAUSED_ALL");
    let resumed = pg_set_all_paused(store, false, "operator resume");
    guard let _r = resumed else let e = err_of(resumed) { panic(e); }
    assert(read_test_value(pool, "select status as val from bot_markets where bot_id='00000000-0000-4000-8000-000000000002'") == "QUOTING");
    assert(read_test_value(pool, "select status as val from bot_markets where bot_id='00000000-0000-4000-8000-000000000003'") == "PAUSED_MANUAL");
    assert(read_test_value(pool, "select reason as val from trading_halt where id=1") == "ledger incident");
    assert(read_test_value(pool, "select halted::text as val from trading_halt where id=1") == "true");
    run_test_sql(pool, "create function reject_bot_update() returns trigger language plpgsql as $$ begin raise exception 'injected failure'; end $$");
    run_test_sql(pool, "create trigger reject_bot_update before update on bot_markets for each row execute function reject_bot_update()");
    let failed = pg_set_all_paused(store, true, "failure test");
    if let _unexpected = failed { panic("pause should fail when bot update fails"); }
    assert(read_test_value(pool, "select bots_paused::text as val from trading_halt where id=1") == "false");
    zokor.pg_close(app_pool);
    zokor.pg_close(pool);
    run_test_sql(base, "drop database " + name + " with (force)");
    zokor.pg_close(base);
}

gc struct SummaryDb { base: pg.Pool, owner: pg.Pool, app: pg.Pool, name: str }

fn summary_db() -> opt[SummaryDb] {
    let url = proc.getenv("TEST_DATABASE_URL") ?? "";
    let app_url = proc.getenv("TEST_APP_DATABASE_URL") ?? "";
    if len(url) == 0 || len(app_url) == 0 { println("skip treasury summary integration test (test database URLs not set)"); return none; }
    let random = crypto.rand(5);
    guard let random_bytes = random else { panic("random database name unavailable"); }
    let name = "say_treasury_" + encoding.hex_encode(random_bytes);
    let base = open_test_pool(url);
    run_test_sql(base, "create database " + name);
    let owner = open_test_pool(strings.replace(url, "/say_test?", "/" + name + "?"));
    let migrations = zokor.load_migrations("migrations", zokor.migration_limits());
    guard let loaded = migrations else let e = err_of(migrations) { panic(e); }
    let applied = zokor.migrate(owner, loaded, until_of(time.mono() + 60000000000));
    guard let _done = applied else let e = err_of(applied) { panic(e); }
    let app = open_test_pool(strings.replace(app_url, "/say_test?", "/" + name + "?"));
    return some(SummaryDb { base: base, owner: owner, app: app, name: name });
}

fn close_summary_db(db: SummaryDb) {
    zokor.pg_close(db.app);
    zokor.pg_close(db.owner);
    run_test_sql(db.base, "drop database " + db.name + " with (force)");
    zokor.pg_close(db.base);
}

fn test_summary_fails_without_a_current_season() {
    guard let db = summary_db() else { return; }
    let r = pg_get_summary(make_postgres_treasury_store(db.app), "");
    if let _unexpected = r { panic("summary without a season should fail"); }
    assert(err_of(r) == "SEASON_NOT_FOUND", err_of(r));
    close_summary_db(db);
}

fn test_summary_reports_only_recorded_figures() {
    guard let db = summary_db() else { return; }
    let pool = db.owner;
    run_test_sql(pool, "insert into accounts(id,username,status,kind,email_verified_at) values ('00000000-0000-4000-8000-000000000001','test_operator','ACTIVE','USER',now()),('00000000-0000-4000-8000-000000000002','test_bot_one','ACTIVE','USER',null)");
    run_test_sql(pool, "insert into seasons(id,ordinal,starts_at,ends_at,status) values ('00000000-0000-4000-8000-000000000004',998,now() - interval '1 day',now() + interval '13 days','ACTIVE'),('00000000-0000-4000-8000-000000000006',999,now() + interval '13 days',now() + interval '27 days','SCHEDULED')");
    run_test_sql(pool, "insert into markets(id,slug,status,created_by,tick,season_id) values ('00000000-0000-4000-8000-000000000005','test-market','DRAFT','00000000-0000-4000-8000-000000000001',1,'00000000-0000-4000-8000-000000000004')");
    run_test_sql(pool, "insert into bot_markets(bot_id,market_id,season_id,allocated,status) values ('00000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000005','00000000-0000-4000-8000-000000000004',25000,'QUOTING')");
    run_test_sql(pool, "insert into issuance_policies(amount,season_cap,status,proposed_by) values (1000,5000000,'PROPOSED','00000000-0000-4000-8000-000000000001')");
    run_test_sql(pool, "insert into reconciliation_runs(scope,status,finished_at,ok) values ('full','done',now(),false)");
    run_test_sql(pool, "update trading_halt set halted=true, reason='collateral check failed' where id=1");
    let r = pg_get_summary(make_postgres_treasury_store(db.app), "");
    guard let s = r else let e = err_of(r) { panic(e); }
    assert(s.given_to_players == 0);
    assert(s.collateral_held == 0);
    assert(s.fees_collected == 0);
    assert(s.bot_budget.allocated == 25000);
    if let cap = s.bot_budget.cap { panic("no cap is recorded, got " + to_str(cap)); }
    guard let balanced = s.books_balanced else { panic("latest check result missing"); }
    assert(!balanced);
    guard let banner = s.incident_banner else { panic("halt reason missing"); }
    assert(banner == "collateral check failed");
    guard let grants = s.season_grants_next else { panic("proposed issuance policy missing"); }
    assert(grants.amount == 1000);
    assert(grants.approx_players == 1);
    assert(grants.approx_total == 1000);
    assert(len(grants.at) > 0);
    close_summary_db(db);
}

fn bot_heartbeat(bot_id: str, status: str) -> domain.HeartbeatPayload {
    return domain.HeartbeatPayload {
        bot_id: bot_id, market_id: "00000000-0000-4000-8000-000000000005", status: status,
        status_reason: "bot says", holding_yes: 0, holding_no: 0, used: 40, spread_ticks: 3
    };
}

fn test_should_keep_an_operator_pause_whatever_a_heartbeat_reports() {
    guard let db = summary_db() else { return; }
    run_test_sql(db.owner, "insert into accounts(id,username,status,kind) values ('00000000-0000-4000-8000-000000000001','test_operator','ACTIVE','USER'),('00000000-0000-4000-8000-000000000002','test_bot_one','ACTIVE','USER'),('00000000-0000-4000-8000-000000000003','test_bot_two','ACTIVE','USER')");
    run_test_sql(db.owner, "insert into seasons(id,ordinal,starts_at,ends_at,status) values ('00000000-0000-4000-8000-000000000004',999,'2026-01-01T00:00:00Z','2026-01-15T00:00:00Z','CLOSED')");
    run_test_sql(db.owner, "insert into markets(id,slug,status,created_by,tick) values ('00000000-0000-4000-8000-000000000005','test-market','DRAFT','00000000-0000-4000-8000-000000000001',1)");
    run_test_sql(db.owner, "insert into bot_markets(bot_id,market_id,season_id,status,status_reason) values ('00000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000005','00000000-0000-4000-8000-000000000004','PAUSED_MANUAL','operator pause'),('00000000-0000-4000-8000-000000000003','00000000-0000-4000-8000-000000000005','00000000-0000-4000-8000-000000000004','PULLED_STALE','')");
    let store = make_postgres_treasury_store(db.app);

    let manual = pg_record_heartbeat(store, bot_heartbeat("00000000-0000-4000-8000-000000000002", "QUOTING"));
    guard let kept = manual else let e = err_of(manual) { panic(e); }
    assert(kept.status == "PAUSED_MANUAL", kept.status);
    assert(!kept.trading_halted);
    assert(read_test_value(db.owner, "select status_reason as val from bot_markets where bot_id='00000000-0000-4000-8000-000000000002'") == "operator pause");
    assert(read_test_value(db.owner, "select used::text as val from bot_markets where bot_id='00000000-0000-4000-8000-000000000002'") == "40");

    run_test_sql(db.owner, "update trading_halt set bots_paused=true where id=1");
    let global = pg_record_heartbeat(store, bot_heartbeat("00000000-0000-4000-8000-000000000003", "QUOTING"));
    guard let held = global else let e = err_of(global) { panic(e); }
    assert(held.status == "PAUSED_ALL", held.status);

    run_test_sql(db.owner, "update trading_halt set bots_paused=false where id=1");
    run_test_sql(db.owner, "update bot_markets set status='PULLED_STALE' where bot_id='00000000-0000-4000-8000-000000000003'");
    let free = pg_record_heartbeat(store, bot_heartbeat("00000000-0000-4000-8000-000000000003", "QUOTING"));
    guard let quoting = free else let e = err_of(free) { panic(e); }
    assert(quoting.status == "QUOTING", quoting.status);

    let stranger = pg_record_heartbeat(store, bot_heartbeat("00000000-0000-4000-8000-000000000001", "QUOTING"));
    if let _s = stranger { panic("a heartbeat for a bot with no row was accepted"); }
    else let e = err_of(stranger) { assert(e == "NOT_FOUND", e); }

    let missing = pg_set_status(store, "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000005", "PAUSED_MANUAL", "x");
    if let _s = missing { panic("pausing an unknown bot succeeded"); }
    else let e = err_of(missing) { assert(e == "NOT_FOUND", e); }
    close_summary_db(db);
}

fn topup_status(db: SummaryDb, id: str) -> str {
    let deadline = until_of(time.mono() + 30000000000);
    let r: result[[TestText], str] = zokor.query_all(db.owner,
        "select status || ':' || status_reason as val from bot_topups where id = $1::uuid", [pg.arg_text(id)], deadline);
    guard let rows = r else let e = err_of(r) { panic(e); }
    assert(len(rows) == 1);
    return rows[0].val;
}

fn approve_as(db: SummaryDb, approval_id: str, approver: str) {
    let deadline = until_of(time.mono() + 30000000000);
    let r = pg.pool_query(db.owner,
        "with d as (insert into approval_decisions(approval_id,decided_by,decision,note,decided_at) values ($1::uuid,$2::uuid,'approved','',now()) returning id) " +
        "update approval_state s set status='approved', decision_id=d.id, version=version+1 from d where s.approval_id=$1::uuid",
        [pg.arg_text(approval_id), pg.arg_text(approver)], deadline);
    guard let _ok = r else let e = err_of(r) { panic(e); }
}

fn funding_fixture(db: SummaryDb) -> PostgresTreasuryStore {
    run_test_sql(db.owner, "insert into accounts(id,username,status,kind) values ('00000000-0000-4000-8000-000000000001','op_one','ACTIVE','USER'),('00000000-0000-4000-8000-000000000002','op_two','ACTIVE','USER'),('00000000-0000-4000-8000-000000000003','op_three','ACTIVE','USER')");
    run_test_sql(db.owner, "insert into seasons(id,ordinal,starts_at,ends_at,status) values ('00000000-0000-4000-8000-000000000004',999,'2099-01-01T00:00:00Z','2099-01-15T00:00:00Z','ACTIVE')");
    run_test_sql(db.owner, "insert into wallets (season_id, owner_kind, owner_id, asset_key) select '00000000-0000-4000-8000-000000000004', 'system', o, 'SEDI' from unnest(array['system:issuance','system:fees','system:treasury']) as o");
    run_test_sql(db.owner, "alter table markets drop constraint markets_submitted_complete");
    run_test_sql(db.owner, "insert into markets(id,slug,status,created_by,tick,season_id) values ('00000000-0000-4000-8000-000000000005','fund-market','APPROVED','00000000-0000-4000-8000-000000000001',1,'00000000-0000-4000-8000-000000000004')");
    return make_postgres_treasury_store(db.app);
}

fn test_should_provision_a_bot_with_a_rotatable_key_and_a_paused_assignment() {
    guard let db = summary_db() else { return; }
    let store = funding_fixture(db);
    let made = pg_create_bot(store, "mm_test_01", "hash-one", "say_bot_aaaa");
    guard let bot = made else let e = err_of(made) { panic(e); }
    assert(read_test_value(db.owner, "select kind || ':' || leaderboard_eligible::text as val from accounts where username = 'mm_test_01'") == "BOT:false");
    assert(read_test_value(db.owner, "select beneficial_owner_group::text as val from accounts where username = 'mm_test_01'") == domain.house_group());
    let dup = pg_create_bot(store, "mm_test_01", "hash-two", "say_bot_bbbb");
    if let _d = dup { panic("a taken username made a second bot"); }

    let rotated = pg_issue_bot_key(store, bot, "hash-three", "say_bot_cccc");
    guard let _r = rotated else let e = err_of(rotated) { panic(e); }
    assert(read_test_value(db.owner, "select string_agg(key_hash, ',' order by created_at) as val from bot_api_keys where revoked_at is null") == "hash-three");
    let not_bot = pg_issue_bot_key(store, "00000000-0000-4000-8000-000000000001", "h", "say_bot_dddd");
    if let _n = not_bot { panic("issued a bot key to a player"); }

    let first = pg_assign_bot(store, bot, "00000000-0000-4000-8000-000000000005");
    guard let added = first else let e = err_of(first) { panic(e); }
    assert(added);
    assert(read_test_value(db.owner, "select status || ':' || allocated::text as val from bot_markets") == "PAUSED_MANUAL:0");
    let again = pg_assign_bot(store, bot, "00000000-0000-4000-8000-000000000005");
    guard let added_again = again else let e = err_of(again) { panic(e); }
    assert(!added_again);
    close_summary_db(db);
}

fn test_should_move_bot_money_only_after_approval_and_within_the_season_budget() {
    guard let db = summary_db() else { return; }
    let store = funding_fixture(db);
    let made = pg_create_bot(store, "mm_test_02", "hash-x", "say_bot_xxxx");
    guard let bot = made else let e = err_of(made) { panic(e); }
    let market = "00000000-0000-4000-8000-000000000005";
    let assigned = pg_assign_bot(store, bot, market);
    guard let _a = assigned else let e = err_of(assigned) { panic(e); }

    let early = pg_request_topup(store, bot, market, 400, "00000000-0000-4000-8000-000000000001", "seed liquidity");
    guard let t1 = early else let e = err_of(early) { panic(e); }
    let idle = pg_apply_funding(store);
    guard let r0 = idle else let e = err_of(idle) { panic(e); }
    assert(r0.applied == 0 && r0.rejected == 0, "an unapproved top-up was applied");

    approve_as(db, t1.approval_ids[0], "00000000-0000-4000-8000-000000000002");
    let no_budget = pg_apply_funding(store);
    guard let r1 = no_budget else let e = err_of(no_budget) { panic(e); }
    assert(r1.rejected == 1, to_str(r1.rejected));
    assert(topup_status(db, t1.id) == "REJECTED:no approved bot budget for this season", topup_status(db, t1.id));

    let budget = pg_request_season_budget(store, "00000000-0000-4000-8000-000000000004", 1000, "00000000-0000-4000-8000-000000000001", "launch");
    guard let b = budget else let e = err_of(budget) { panic(e); }
    assert(len(b.approval_ids) == 2);
    approve_as(db, b.approval_ids[0], "00000000-0000-4000-8000-000000000002");
    let half = pg_apply_funding(store);
    guard let _h = half else let e = err_of(half) { panic(e); }
    assert(read_test_value(db.owner, "select status as val from bot_season_budgets") == "PENDING");
    approve_as(db, b.approval_ids[1], "00000000-0000-4000-8000-000000000003");

    let t2r = pg_request_topup(store, bot, market, 700, "00000000-0000-4000-8000-000000000001", "seed liquidity");
    guard let t2 = t2r else let e = err_of(t2r) { panic(e); }
    let t3r = pg_request_topup(store, bot, market, 400, "00000000-0000-4000-8000-000000000001", "more");
    guard let t3 = t3r else let e = err_of(t3r) { panic(e); }
    approve_as(db, t2.approval_ids[0], "00000000-0000-4000-8000-000000000002");
    approve_as(db, t3.approval_ids[0], "00000000-0000-4000-8000-000000000002");

    let applied = pg_apply_funding(store);
    guard let r2 = applied else let e = err_of(applied) { panic(e); }
    assert(len(r2.problems) == 0, r2.problems[0]);
    assert(r2.applied == 2, to_str(r2.applied));
    assert(r2.rejected == 1, to_str(r2.rejected));
    assert(read_test_value(db.owner, "select status as val from bot_season_budgets") == "APPLIED");
    assert(read_test_value(db.owner, "select allocated::text as val from bot_markets") == "700");
    assert(strings.has_prefix(topup_status(db, t3.id), "REJECTED:would exceed the season bot budget of 1000"), topup_status(db, t3.id));
    assert(read_test_value(db.owner, "select count(*)::text as val from ledger_transactions where kind = 'BOT_FUNDING'") == "1");
    assert(read_test_value(db.owner, "select coalesce(sum(e.delta),0)::text as val from ledger_entries e join wallets w on w.id = e.wallet_id where w.owner_kind = 'bot' and w.asset_key = 'SEDI'") == "700");

    let replay = pg_apply_funding(store);
    guard let r3 = replay else let e = err_of(replay) { panic(e); }
    assert(r3.applied == 0 && r3.rejected == 0);
    assert(read_test_value(db.owner, "select allocated::text as val from bot_markets") == "700");

    let summary = pg_get_summary(store, "");
    guard let sum = summary else let e = err_of(summary) { panic(e); }
    assert((sum.bot_budget.cap ?? 0) == 1000);
    close_summary_db(db);
}
