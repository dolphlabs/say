import "encoding";
import "pg";
import "strings";
import "time";
import "zokor";
import "../domain" as domain;
import "../service" as service;

pub gc struct PostgresNotificationStore {
    pool: pg.Pool
}

fn pg_deadline() -> until {
    return until_of(time.mono() + 5000000000); // 5s timeout
}

gc struct UnreadCountRow {
    unread_count: int
}

gc struct NotificationSqlRow {
    id: str,
    kind: str,
    dedupe_key: str,
    title: str,
    body: str,
    link_url: str,
    data: str,
    created_at: str,
    updated_at: str,
    unread: bool
}

gc struct PrefSqlRow {
    kind: str,
    in_app: bool,
    email: bool
}

gc struct ClosingSoonSqlRow {
    market_id: str,
    question: str,
    close_at_wat: str
}

gc struct RecipientSqlRow {
    account_id: str,
    email: str,
    in_app: opt[bool],
    pref_email: opt[bool]
}

gc struct JobSqlRow {
    id: str,
    kind: str,
    subject: str,
    cursor: str,
    done: bool
}

fn st_get_notifications(
    s: PostgresNotificationStore,
    account_id: str,
    cursor: str,
    limit: int
) -> result[domain.NotificationPage, str] {
    let count_res: result[opt[UnreadCountRow], str] = zokor.query_one(s.pool,
        "select count(*)::int as unread_count from notifications " +
        "where account_id = $1::uuid and read_at is null",
        [pg.arg_text(account_id)], pg_deadline());

    guard let count_row = count_res else let e = err_of(count_res) {
        return err(e);
    }
    let unread_total = 0;
    if let c = count_row {
        unread_total = c.unread_count;
    }

    let rows_res: result[[NotificationSqlRow], str] = zokor.query_all(s.pool,
        "select id::text as id, kind, dedupe_key, title, body, link as link_url, data::text as data, " +
        "to_char(created_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') as created_at, " +
        "to_char(updated_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') as updated_at, " +
        "(read_at is null) as unread " +
        "from notifications " +
        "where account_id = $1::uuid " +
        "order by created_at desc, id desc limit $2",
        [pg.arg_text(account_id), pg.arg_int(limit)], pg_deadline());

    guard let rows = rows_res else let e = err_of(rows_res) {
        return err(e);
    }

    let items: [domain.NotificationItem] = [];
    let next_cursor = "";
    for r in rows {
        push(items, domain.NotificationItem {
            id: r.id,
            kind: r.kind,
            dedupe_key: r.dedupe_key,
            title: r.title,
            body: r.body,
            link_url: r.link_url,
            data: r.data,
            created_at: r.created_at,
            updated_at: r.updated_at,
            unread: r.unread
        });
        next_cursor = r.id;
    }

    if len(items) < limit {
        next_cursor = "";
    }

    return ok(domain.NotificationPage {
        items: items,
        unread_count: unread_total,
        next_cursor: next_cursor
    });
}

fn st_mark_read(
    s: PostgresNotificationStore,
    account_id: str,
    ids: [str],
    mark_all: bool
) -> result[int, str] {
    if mark_all {
        let r = pg.pool_query(s.pool,
            "update notifications set read_at = now() where account_id = $1::uuid and read_at is null",
            [pg.arg_text(account_id)], pg_deadline());
        guard let _ = r else let e = err_of(r) { return err(e); }
        return ok(1);
    }

    for id in ids {
        let r = pg.pool_query(s.pool,
            "update notifications set read_at = now() where account_id = $1::uuid and id = $2::uuid and read_at is null",
            [pg.arg_text(account_id), pg.arg_text(id)], pg_deadline());
        guard let _ = r else let e = err_of(r) { return err(e); }
    }
    return ok(len(ids));
}

fn st_get_prefs(
    s: PostgresNotificationStore,
    account_id: str
) -> result[[domain.NotificationPref], str] {
    let rows_res: result[[PrefSqlRow], str] = zokor.query_all(s.pool,
        "select kind, in_app, email from notification_prefs where account_id = $1::uuid",
        [pg.arg_text(account_id)], pg_deadline());

    guard let rows = rows_res else let e = err_of(rows_res) {
        return err(e);
    }

    let overrides: map[str]PrefSqlRow = {};
    for r in rows {
        overrides[r.kind] = r;
    }

    let defaults = domain.default_notification_prefs();
    let out: [domain.NotificationPref] = [];
    for d in defaults {
        let in_app = d.in_app;
        let email = d.email;
        if has(overrides, d.kind) {
            let row = overrides[d.kind];
            in_app = row.in_app;
            email = row.email;
        }
        push(out, domain.NotificationPref {
            kind: d.kind,
            label: d.label,
            hint: d.hint,
            in_app: in_app,
            email: email
        });
    }

    return ok(out);
}

fn st_set_pref(
    s: PostgresNotificationStore,
    account_id: str,
    kind: str,
    in_app: bool,
    email: bool
) -> result[int, str] {
    let r = pg.pool_query(s.pool,
        "insert into notification_prefs (account_id, kind, in_app, email, updated_at) " +
        "values ($1::uuid, $2, $3, $4, now()) " +
        "on conflict (account_id, kind) do update set " +
        "in_app = excluded.in_app, email = excluded.email, updated_at = now()",
        [pg.arg_text(account_id), pg.arg_text(kind), pg.arg_bool(in_app), pg.arg_bool(email)],
        pg_deadline());

    guard let _ = r else let e = err_of(r) { return err(e); }
    return ok(1);
}

fn st_unsubscribe_email(
    s: PostgresNotificationStore,
    account_id: str,
    kind: str
) -> result[int, str] {
    let r = pg.pool_query(s.pool,
        "insert into notification_prefs (account_id, kind, in_app, email, updated_at) " +
        "values ($1::uuid, $2, true, false, now()) " +
        "on conflict (account_id, kind) do update set email = false, updated_at = now()",
        [pg.arg_text(account_id), pg.arg_text(kind)],
        pg_deadline());

    guard let _ = r else let e = err_of(r) { return err(e); }
    return ok(1);
}

fn st_find_closing_soon_markets(
    s: PostgresNotificationStore
) -> result[[service.ClosingSoonMarket], str] {
    let empty_args: [pg.Arg] = [];
    let rows_res: result[[ClosingSoonSqlRow], str] = zokor.query_all(s.pool,
        "select id::text as market_id, coalesce(question, '') as question, " +
        "to_char(close_at at time zone 'Africa/Lagos', 'HH24:MI') as close_at_wat " +
        "from markets " +
        "where status in ('OPEN', 'SUSPENDED') " +
        "and closing_soon_sent_at is null " +
        "and close_at > now() and close_at <= now() + interval '60 minutes'",
        empty_args, pg_deadline());

    guard let rows = rows_res else let e = err_of(rows_res) {
        return err(e);
    }

    let out: [service.ClosingSoonMarket] = [];
    for r in rows {
        push(out, service.ClosingSoonMarket {
            market_id: r.market_id,
            question: r.question,
            close_at_wat: r.close_at_wat
        });
    }
    return ok(out);
}

fn st_mark_closing_soon_sent(
    s: PostgresNotificationStore,
    market_id: str
) -> result[int, str] {
    let r = pg.pool_query(s.pool,
        "update markets set closing_soon_sent_at = now() where id = $1::uuid and closing_soon_sent_at is null",
        [pg.arg_text(market_id)], pg_deadline());

    guard let _ = r else let e = err_of(r) { return err(e); }
    return ok(1);
}

fn st_create_fanout_job(
    s: PostgresNotificationStore,
    kind: str,
    subject: str
) -> result[domain.FanoutJob, str] {
    let r: result[opt[JobSqlRow], str] = zokor.query_one(s.pool,
        "insert into fanout_jobs (kind, subject) values ($1, $2) " +
        "on conflict (kind, subject) do update set updated_at = now() " +
        "returning id::text as id, kind, subject, cursor, done",
        [pg.arg_text(kind), pg.arg_text(subject)], pg_deadline());

    guard let row_opt = r else let e = err_of(r) { return err(e); }
    guard let row = row_opt else { return err("CANNOT_CREATE_JOB"); }

    return ok(domain.FanoutJob {
        id: row.id,
        kind: row.kind,
        subject: row.subject,
        cursor: row.cursor,
        done: row.done
    });
}

fn st_find_job_recipients(
    s: PostgresNotificationStore,
    kind: str,
    subject: str,
    cursor: str,
    limit: int
) -> result[[service.NotificationRecipient], str] {
    // Bots hold API keys and never get notices; emails go only to verified
    // addresses. Market notices reach holders and open orders in that market.
    let rows_res: result[[RecipientSqlRow], str] = zokor.query_all(s.pool,
        "select a.id::text as account_id, " +
        "case when a.email_verified_at is not null then coalesce(a.email, '') else '' end as email, " +
        "p.in_app, p.email as pref_email " +
        "from accounts a " +
        "left join notification_prefs p on p.account_id = a.id and p.kind = $1 " +
        "where a.status = 'ACTIVE' and a.deleted_at is null and a.kind = 'USER' " +
        "and not exists (select 1 from bot_api_keys k where k.bot_id = a.id) " +
        "and ($2 = '' or a.id::text > $2) " +
        "and (not $4 or exists (select 1 from positions ps where ps.account_id = a.id and ps.market_id::text = $5 and ps.qty > 0) " +
        "or exists (select 1 from orders o where o.account_id = a.id and o.market_id::text = $5 and o.status in ('ADMITTED','OPEN','PARTIAL'))) " +
        "order by a.id::text asc limit $3",
        [pg.arg_text(kind), pg.arg_text(cursor), pg.arg_int(limit), pg.arg_bool(domain.market_scoped(kind)), pg.arg_text(subject)], pg_deadline());

    guard let rows = rows_res else let e = err_of(rows_res) {
        return err(e);
    }

    let out: [service.NotificationRecipient] = [];
    for r in rows {
        let in_app = true;
        let send_email = false;
        if kind == "market_settled" || kind == "season_started" {
            send_email = true;
        }
        if let ia = r.in_app { in_app = ia; }
        if let em = r.pref_email { send_email = em; }

        push(out, service.NotificationRecipient {
            account_id: r.account_id,
            email: r.email,
            in_app: in_app,
            send_email: send_email
        });
    }
    return ok(out);
}

fn st_write_notification_batch(
    s: PostgresNotificationStore,
    job_id: str,
    notices: [service.NoticeToWrite],
    emails: [service.EmailToWrite],
    next_cursor: str
) -> result[int, str] {
    for n in notices {
        let r = pg.pool_query(s.pool,
            "insert into notifications (account_id, kind, dedupe_key, title, body, link, data, created_at, updated_at, read_at) " +
            "values ($1::uuid, $2, $3, $4, $5, $6, $7::jsonb, now(), now(), null) " +
            "on conflict (account_id, dedupe_key) do update set " +
            "title = excluded.title, body = excluded.body, link = excluded.link, data = excluded.data, " +
            "updated_at = now(), read_at = null",
            [
                pg.arg_text(n.account_id), pg.arg_text(n.kind), pg.arg_text(n.dedupe_key),
                pg.arg_text(n.title), pg.arg_text(n.body), pg.arg_text(n.link_url), pg.arg_text(n.data_json)
            ],
            pg_deadline());
        guard let _ = r else let e = err_of(r) { return err(e); }
    }

    for em in emails {
        let r = pg.pool_query(s.pool,
            "insert into email_outbox (account_id, kind, dedupe_key, recipient_email, subject, body_text, body_html, link_url) " +
            "values ($1::uuid, $2, $3, $4, $5, $6, '', $7) " +
            "on conflict (dedupe_key) where dedupe_key is not null do nothing",
            [
                pg.arg_text(em.account_id), pg.arg_text(em.kind), pg.arg_text(em.dedupe_key),
                pg.arg_text(em.recipient_email), pg.arg_text(em.subject), pg.arg_text(em.body_text), pg.arg_text(em.link_url)
            ],
            pg_deadline());
        guard let _ = r else let e = err_of(r) { return err(e); }
    }

    let upd_cursor = pg.pool_query(s.pool,
        "update fanout_jobs set cursor = $2, updated_at = now() where id = $1::uuid",
        [pg.arg_text(job_id), pg.arg_text(next_cursor)], pg_deadline());
    guard let _ = upd_cursor else let e = err_of(upd_cursor) { return err(e); }

    return ok(len(notices));
}

fn st_complete_job(
    s: PostgresNotificationStore,
    job_id: str
) -> result[int, str] {
    let r = pg.pool_query(s.pool,
        "update fanout_jobs set done = true, updated_at = now() where id = $1::uuid",
        [pg.arg_text(job_id)], pg_deadline());
    guard let _ = r else let e = err_of(r) { return err(e); }
    return ok(1);
}

gc struct DueEmailRow {
    id: str,
    account_id: str,
    kind: str,
    username: str,
    email: str,
    subject: str,
    body_text: str,
    link_url: str,
    attempts: int
}

// Emails whose account has since gone, lost its verified address or turned
// that email off are closed rather than sent.
fn st_claim_emails(s: PostgresNotificationStore, limit: int, lease: int) -> result[[service.DueEmail], str] {
    let none_args: [pg.Arg] = [];
    let skip = pg.pool_query(s.pool,
        "update email_outbox o set sent_at = now(), last_error = 'skipped: recipient no longer reachable' " +
        "where o.sent_at is null and o.next_attempt_at <= now() and (" +
        "not exists (select 1 from accounts a where a.id = o.account_id and a.status = 'ACTIVE' " +
        "and a.deleted_at is null and a.email_verified_at is not null and coalesce(a.email, '') <> '') " +
        "or exists (select 1 from notification_prefs p where p.account_id = o.account_id and p.kind = o.kind and not p.email))",
        none_args, pg_deadline());
    guard let _skipped = skip else let e = err_of(skip) {
        return err(e);
    }
    let rows: result[[DueEmailRow], str] = zokor.query_all(s.pool,
        "update email_outbox o set next_attempt_at = now() + make_interval(secs => $2), attempts = o.attempts + 1 " +
        "from accounts a where a.id = o.account_id and o.id in (" +
        "select e.id from email_outbox e where e.sent_at is null and e.next_attempt_at <= now() and e.attempts < $3 " +
        "order by e.next_attempt_at limit $1 for update skip locked) " +
        "returning o.id::text as id, o.account_id::text as account_id, o.kind, a.username, coalesce(a.email, '') as email, " +
        "o.subject, o.body_text, o.link_url, o.attempts",
        [pg.arg_int(limit), pg.arg_int(lease), pg.arg_int(domain.email_max_attempts())], pg_deadline());
    guard let found = rows else let e = err_of(rows) {
        return err(e);
    }
    let out: [service.DueEmail] = [];
    for r in found {
        push(out, service.DueEmail {
            id: r.id, account_id: r.account_id, kind: r.kind, username: r.username, email: r.email,
            subject: r.subject, body_text: r.body_text, link_url: r.link_url, attempts: r.attempts
        });
    }
    return ok(out);
}

fn st_email_sent(s: PostgresNotificationStore, id: str) -> result[bool, str] {
    let r = pg.pool_query(s.pool,
        "update email_outbox set sent_at = now(), last_error = null where id = $1::uuid",
        [pg.arg_text(id)], pg_deadline());
    guard let _r = r else let e = err_of(r) { return err(e); }
    return ok(true);
}

fn st_email_retry(s: PostgresNotificationStore, id: str, why: str, delay: int) -> result[bool, str] {
    let r = pg.pool_query(s.pool,
        "update email_outbox set next_attempt_at = now() + make_interval(secs => $3), last_error = left($2, 500) where id = $1::uuid",
        [pg.arg_text(id), pg.arg_text(why), pg.arg_int(delay)], pg_deadline());
    guard let _r = r else let e = err_of(r) { return err(e); }
    return ok(true);
}

pub fn make_postgres_notification_store(pool: pg.Pool) -> service.NotificationStore[PostgresNotificationStore] {
    let s = PostgresNotificationStore { pool: pool };
    return service.NotificationStore[PostgresNotificationStore] {
        context: s,
        get_notifications: st_get_notifications,
        mark_read: st_mark_read,
        get_prefs: st_get_prefs,
        set_pref: st_set_pref,
        unsubscribe_email: st_unsubscribe_email,
        find_closing_soon_markets: st_find_closing_soon_markets,
        mark_closing_soon_sent: st_mark_closing_soon_sent,
        create_fanout_job: st_create_fanout_job,
        find_job_recipients: st_find_job_recipients,
        write_notification_batch: st_write_notification_batch,
        complete_job: st_complete_job,
        claim_emails: st_claim_emails,
        email_sent: st_email_sent,
        email_retry: st_email_retry
    };
}
