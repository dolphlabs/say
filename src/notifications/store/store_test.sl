import "crypto";
import "encoding";
import "pg";
import "proc";
import "strings";
import "time";
import "zokor";
import "../service" as service;

fn test_notifications_store_factory() {
    let pool_res = pg.new_pool("postgres://say:say@127.0.0.1:55432/say_test?sslmode=disable", 1);
    guard let pool = pool_res else {
        panic("pool creation failed");
    }
    let store = make_postgres_notification_store(pool);
    assert(true);
}

gc struct NotifDb { base: pg.Pool, owner: pg.Pool, app: pg.Pool, name: str }

gc struct NotifText { val: str }

fn notif_pool(url: str) -> pg.Pool {
    let cfg: map[str]str = {};
    cfg["DATABASE_URL"] = url;
    let opened = zokor.pg_from_config(zokor.config_from_values(cfg));
    guard let pool = opened else let e = err_of(opened) { panic(e); }
    return pool;
}

fn notif_sql(pool: pg.Pool, sql: str) {
    let args: [pg.Arg] = [];
    let r = pg.pool_query(pool, sql, args, until_of(time.mono() + 30000000000));
    guard let _ok = r else let e = err_of(r) { panic(e); }
}

fn notif_value(pool: pg.Pool, sql: str) -> str {
    let args: [pg.Arg] = [];
    let r: result[[NotifText], str] = zokor.query_all(pool, sql, args, until_of(time.mono() + 30000000000));
    guard let rows = r else let e = err_of(r) { panic(e); }
    assert(len(rows) == 1);
    return rows[0].val;
}

fn notif_db() -> opt[NotifDb] {
    let url = proc.getenv("TEST_DATABASE_URL") ?? "";
    let app_url = proc.getenv("TEST_APP_DATABASE_URL") ?? "";
    if len(url) == 0 || len(app_url) == 0 { println("skip notifications integration test (test database URLs not set)"); return none; }
    let random = crypto.rand(5);
    guard let random_bytes = random else { panic("random database name unavailable"); }
    let name = "say_notif_" + encoding.hex_encode(random_bytes);
    let base = notif_pool(url);
    notif_sql(base, "create database " + name);
    let owner = notif_pool(strings.replace(url, "/say_test?", "/" + name + "?"));
    let migrations = zokor.load_migrations("migrations", zokor.migration_limits());
    guard let loaded = migrations else let e = err_of(migrations) { panic(e); }
    let applied = zokor.migrate(owner, loaded, until_of(time.mono() + 60000000000));
    guard let _done = applied else let e = err_of(applied) { panic(e); }
    let app = notif_pool(strings.replace(app_url, "/say_test?", "/" + name + "?"));
    return some(NotifDb { base: base, owner: owner, app: app, name: name });
}

fn close_notif_db(db: NotifDb) {
    zokor.pg_close(db.app);
    zokor.pg_close(db.owner);
    notif_sql(db.base, "drop database " + db.name + " with (force)");
    zokor.pg_close(db.base);
}

// holder: verified, holds YES. unverified: holds YES, no verified email.
// bystander: no position. bot: holds YES but has an API key.
fn seed_market(db: NotifDb) {
    notif_sql(db.owner, "insert into accounts(id,username,email,email_verified_at,status,kind) values " +
        "('00000000-0000-4000-8000-000000000001','holder','holder@say.test',now(),'ACTIVE','USER')," +
        "('00000000-0000-4000-8000-000000000002','unverified','unverified@say.test',null,'ACTIVE','USER')," +
        "('00000000-0000-4000-8000-000000000003','bystander','bystander@say.test',now(),'ACTIVE','USER')," +
        "('00000000-0000-4000-8000-000000000004','house_bot','bot@say.test',now(),'ACTIVE','USER')");
    notif_sql(db.owner, "insert into bot_api_keys(bot_id,key_hash,key_prefix) values ('00000000-0000-4000-8000-000000000004','h','say_bot_')");
    notif_sql(db.owner, "insert into seasons(id,ordinal,starts_at,ends_at,status) values ('00000000-0000-4000-8000-000000000010',999,'2026-01-01T00:00:00Z','2026-01-15T00:00:00Z','CLOSED')");
    notif_sql(db.owner, "insert into markets(id,slug,status,created_by,tick) values ('00000000-0000-4000-8000-000000000020','notif-market','DRAFT','00000000-0000-4000-8000-000000000001',1)");
    notif_sql(db.owner, "insert into positions(account_id,market_id,season_id,outcome,qty) values " +
        "('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000020','00000000-0000-4000-8000-000000000010','YES',5)," +
        "('00000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000020','00000000-0000-4000-8000-000000000010','YES',5)," +
        "('00000000-0000-4000-8000-000000000004','00000000-0000-4000-8000-000000000020','00000000-0000-4000-8000-000000000010','YES',5)");
}

fn test_should_notify_only_people_in_the_market_and_email_only_verified_addresses() {
    guard let db = notif_db() else { return; }
    seed_market(db);
    let store = make_postgres_notification_store(db.app);
    let r = (store.find_job_recipients)(store.context, "closing_soon", "00000000-0000-4000-8000-000000000020", "", 100);
    guard let recips = r else let e = err_of(r) { panic(e); }
    assert(len(recips) == 2, to_str(len(recips)));
    assert(recips[0].account_id == "00000000-0000-4000-8000-000000000001");
    assert(recips[0].email == "holder@say.test");
    assert(recips[1].account_id == "00000000-0000-4000-8000-000000000002");
    assert(recips[1].email == "");

    let season = (store.find_job_recipients)(store.context, "season_started", "00000000-0000-4000-8000-000000000010", "", 100);
    guard let everyone = season else let e = err_of(season) { panic(e); }
    assert(len(everyone) == 3, to_str(len(everyone)));
    close_notif_db(db);
}

fn test_should_resume_one_fan_out_job_per_kind_and_subject() {
    guard let db = notif_db() else { return; }
    let store = make_postgres_notification_store(db.app);
    let first = (store.create_fanout_job)(store.context, "closing_soon", "m-1");
    guard let a = first else let e = err_of(first) { panic(e); }
    let deadline = until_of(time.mono() + 30000000000);
    let moved = pg.pool_query(db.owner, "update fanout_jobs set cursor = 'acc-5' where id = $1::uuid", [pg.arg_text(a.id)], deadline);
    guard let _m = moved else let e = err_of(moved) { panic(e); }
    let again = (store.create_fanout_job)(store.context, "closing_soon", "m-1");
    guard let b = again else let e = err_of(again) { panic(e); }
    assert(a.id == b.id);
    assert(b.cursor == "acc-5", b.cursor);
    close_notif_db(db);
}

fn test_should_claim_emails_once_and_close_ones_whose_recipient_is_gone_or_opted_out() {
    guard let db = notif_db() else { return; }
    seed_market(db);
    let store = make_postgres_notification_store(db.app);
    let emails = [
        service.EmailToWrite { account_id: "00000000-0000-4000-8000-000000000001", kind: "closing_soon", dedupe_key: "k1", recipient_email: "old@say.test", subject: "S", body_text: "B", link_url: "/markets/m" },
        service.EmailToWrite { account_id: "00000000-0000-4000-8000-000000000002", kind: "closing_soon", dedupe_key: "k2", recipient_email: "unverified@say.test", subject: "S", body_text: "B", link_url: "" },
        service.EmailToWrite { account_id: "00000000-0000-4000-8000-000000000003", kind: "closing_soon", dedupe_key: "k3", recipient_email: "bystander@say.test", subject: "S", body_text: "B", link_url: "" }
    ];
    let none_notices: [service.NoticeToWrite] = [];
    let job = (store.create_fanout_job)(store.context, "closing_soon", "m");
    guard let j = job else let e = err_of(job) { panic(e); }
    let written = (store.write_notification_batch)(store.context, j.id, none_notices, emails, "");
    guard let _w = written else let e = err_of(written) { panic(e); }
    let dup = (store.write_notification_batch)(store.context, j.id, none_notices, emails, "");
    guard let _d = dup else let e = err_of(dup) { panic(e); }
    assert(notif_value(db.owner, "select count(*)::text as val from email_outbox") == "3");
    notif_sql(db.owner, "insert into notification_prefs(account_id,kind,in_app,email) values ('00000000-0000-4000-8000-000000000003','closing_soon',true,false)");

    let claimed = (store.claim_emails)(store.context, 20, 120);
    guard let due = claimed else let e = err_of(claimed) { panic(e); }
    assert(len(due) == 1, to_str(len(due)));
    assert(due[0].email == "holder@say.test", due[0].email);
    assert(due[0].username == "holder");
    assert(due[0].link_url == "/markets/m");
    assert(due[0].attempts == 1);
    assert(notif_value(db.owner, "select count(*)::text as val from email_outbox where sent_at is not null and last_error like 'skipped:%'") == "2");

    let twice = (store.claim_emails)(store.context, 20, 120);
    guard let none_due = twice else let e = err_of(twice) { panic(e); }
    assert(len(none_due) == 0, "a leased email was claimed again");

    let retried = (store.email_retry)(store.context, due[0].id, "provider 503", 0);
    guard let _r = retried else let e = err_of(retried) { panic(e); }
    let back = (store.claim_emails)(store.context, 20, 120);
    guard let again = back else let e = err_of(back) { panic(e); }
    assert(len(again) == 1);
    assert(again[0].attempts == 2);
    let sent = (store.email_sent)(store.context, again[0].id);
    guard let _s = sent else let e = err_of(sent) { panic(e); }
    assert(notif_value(db.owner, "select count(*)::text as val from email_outbox where sent_at is null") == "0");
    close_notif_db(db);
}
