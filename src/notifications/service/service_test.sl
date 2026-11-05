import "strings";
import "../domain" as domain;

gc struct FakeNotifStoreCtx {
    notifs: [domain.NotificationItem],
    prefs: [domain.NotificationPref],
    closing_markets: [ClosingSoonMarket],
    calls: [str],
    job_cursor: str,
    job_done: bool,
    recipients_failure: str,
    due: [DueEmail]
}

fn fake_ctx() -> FakeNotifStoreCtx {
    let calls: [str] = [];
    let due: [DueEmail] = [];
    return FakeNotifStoreCtx {
        notifs: [], prefs: domain.default_notification_prefs(),
        closing_markets: [ClosingSoonMarket { market_id: "mkt-1", question: "Enyimba vs Rivers", close_at_wat: "16:00" }],
        calls: calls, job_cursor: "", job_done: false, recipients_failure: "", due: due
    };
}

fn fake_get_notifications(ctx: FakeNotifStoreCtx, aid: str, cur: str, lim: int) -> result[domain.NotificationPage, str] {
    return ok(domain.NotificationPage {
        items: ctx.notifs,
        unread_count: len(ctx.notifs),
        next_cursor: ""
    });
}

fn fake_mark_read(ctx: FakeNotifStoreCtx, aid: str, ids: [str], all: bool) -> result[int, str] {
    return ok(len(ids));
}

fn fake_get_prefs(ctx: FakeNotifStoreCtx, aid: str) -> result[[domain.NotificationPref], str] {
    return ok(ctx.prefs);
}

fn fake_set_pref(ctx: FakeNotifStoreCtx, aid: str, kind: str, in_app: bool, email: bool) -> result[int, str] {
    return ok(1);
}

fn fake_unsubscribe_email(ctx: FakeNotifStoreCtx, aid: str, kind: str) -> result[int, str] {
    return ok(1);
}

fn fake_find_closing_soon_markets(ctx: FakeNotifStoreCtx) -> result[[ClosingSoonMarket], str] {
    return ok(ctx.closing_markets);
}

fn fake_mark_closing_soon_sent(ctx: FakeNotifStoreCtx, mid: str) -> result[int, str] {
    push(ctx.calls, "mark_sent " + mid);
    return ok(1);
}

fn fake_create_fanout_job(ctx: FakeNotifStoreCtx, kind: str, subj: str) -> result[domain.FanoutJob, str] {
    return ok(domain.FanoutJob {
        id: "job-1",
        kind: kind,
        subject: subj,
        cursor: ctx.job_cursor,
        done: ctx.job_done
    });
}

fn fake_find_job_recipients(ctx: FakeNotifStoreCtx, kind: str, subj: str, cur: str, lim: int) -> result[[NotificationRecipient], str] {
    push(ctx.calls, "recipients " + kind + " " + subj + " after=" + cur);
    if len(ctx.recipients_failure) > 0 { return err(ctx.recipients_failure); }
    let recips = [
        NotificationRecipient {
            account_id: "acc-1",
            email: "user1@say.fun",
            in_app: true,
            send_email: true
        }
    ];
    return ok(recips);
}

fn fake_write_notification_batch(ctx: FakeNotifStoreCtx, jid: str, notices: [NoticeToWrite], emails: [EmailToWrite], cur: str) -> result[int, str] {
    for e in emails {
        push(ctx.calls, "email " + e.dedupe_key + " " + e.link_url);
    }
    return ok(len(notices));
}

fn fake_complete_job(ctx: FakeNotifStoreCtx, jid: str) -> result[int, str] {
    push(ctx.calls, "complete " + jid);
    return ok(1);
}

fn fake_claim_emails(ctx: FakeNotifStoreCtx, limit: int, lease: int) -> result[[DueEmail], str] {
    let out = ctx.due;
    let none_due: [DueEmail] = [];
    ctx.due = none_due;
    return ok(out);
}

fn fake_email_sent(ctx: FakeNotifStoreCtx, id: str) -> result[bool, str] {
    push(ctx.calls, "sent " + id);
    return ok(true);
}

fn fake_email_retry(ctx: FakeNotifStoreCtx, id: str, why: str, delay: int) -> result[bool, str] {
    push(ctx.calls, "retry " + id + " in " + to_str(delay));
    return ok(true);
}

fn fake_notification_store(ctx: FakeNotifStoreCtx) -> NotificationStore[FakeNotifStoreCtx] {
    return NotificationStore[FakeNotifStoreCtx] {
        context: ctx,
        get_notifications: fake_get_notifications,
        mark_read: fake_mark_read,
        get_prefs: fake_get_prefs,
        set_pref: fake_set_pref,
        unsubscribe_email: fake_unsubscribe_email,
        find_closing_soon_markets: fake_find_closing_soon_markets,
        mark_closing_soon_sent: fake_mark_closing_soon_sent,
        create_fanout_job: fake_create_fanout_job,
        find_job_recipients: fake_find_job_recipients,
        write_notification_batch: fake_write_notification_batch,
        complete_job: fake_complete_job,
        claim_emails: fake_claim_emails,
        email_sent: fake_email_sent,
        email_retry: fake_email_retry
    };
}

gc struct FakeSender {
    sent: [NoticeMail],
    fail_to: str
}

fn fake_send(f: FakeSender, m: NoticeMail) -> result[bool, str] {
    if m.to == f.fail_to { return err("provider 503"); }
    push(f.sent, m);
    return ok(true);
}

fn test_notifications_service_lifecycle() {
    let ctx = FakeNotifStoreCtx {
        notifs: [
            domain.NotificationItem {
                id: "notif-1",
                kind: "order_filled",
                dedupe_key: "order_filled:ord-1",
                title: "Order filled",
                body: "6 Enyimba Yes @ S 54.",
                link_url: "/portfolio",
                data: "{}",
                created_at: "2026-10-28T12:00:00Z",
                updated_at: "2026-10-28T12:00:00Z",
                unread: true
            }
        ],
        prefs: domain.default_notification_prefs(),
        closing_markets: [
            ClosingSoonMarket {
                market_id: "mkt-1",
                question: "Enyimba vs Rivers",
                close_at_wat: "16:00"
            }
        ],
        calls: [],
        job_cursor: "",
        job_done: false,
        recipients_failure: "",
        due: []
    };

    let store = fake_notification_store(ctx);

    let secret = "service-test-secret";
    let svc = new_notification_service(store, secret);

    let page_res = get_notifications(svc, "acc-1", "", 20);
    guard let page = page_res else { panic("get_notifications failed"); }
    assert(len(page.items) == 1);
    assert(page.unread_count == 1);

    let read_res = mark_read(svc, "acc-1", ["notif-1"], false);
    guard let read_count = read_res else { panic("mark_read failed"); }
    assert(read_count == 1);

    let prefs_res = get_prefs(svc, "acc-1");
    guard let prefs = prefs_res else { panic("get_prefs failed"); }
    assert(len(prefs) == 8);

    // Test unsubscribe with valid token
    let token = domain.sign_unsubscribe_token(secret, "acc-1", "market_settled", 2000000000);
    let unsub_res = unsubscribe(svc, token, 1700000000);
    guard let unsub_ok = unsub_res else { panic("unsubscribe failed"); }
    assert(unsub_ok == 1);

    // Test closing soon poll
    let poll_res = poll_closing_soon(svc);
    guard let poll_count = poll_res else { panic("poll_closing_soon failed"); }
    assert(poll_count == 1);
}

fn test_should_mark_a_market_sent_only_after_its_fan_out_succeeds() {
    let ctx = fake_ctx();
    ctx.recipients_failure = "relation does not exist";
    let svc = new_notification_service(fake_notification_store(ctx), "s");
    let failed = poll_closing_soon(svc);
    if let _n = failed { panic("a failed fan-out was reported as sent"); }
    for c in ctx.calls { assert(!strings.has_prefix(c, "mark_sent"), c); }

    ctx.recipients_failure = "";
    let again = poll_closing_soon(svc);
    guard let n = again else let e = err_of(again) { panic(e); }
    assert(n == 1);
    assert(ctx.calls[len(ctx.calls) - 1] == "mark_sent mkt-1", ctx.calls[len(ctx.calls) - 1]);
}

fn test_should_resume_a_fan_out_from_its_saved_cursor_and_link_to_the_market() {
    let ctx = fake_ctx();
    ctx.job_cursor = "acc-0";
    let svc = new_notification_service(fake_notification_store(ctx), "s");
    let r = poll_closing_soon(svc);
    guard let _n = r else let e = err_of(r) { panic(e); }
    assert(ctx.calls[0] == "recipients closing_soon mkt-1 after=acc-0", ctx.calls[0]);
    assert(ctx.calls[1] == "email closing_soon:mkt-1:email /markets/mkt-1", ctx.calls[1]);
}

fn test_should_skip_a_fan_out_that_already_finished() {
    let ctx = fake_ctx();
    ctx.job_done = true;
    let svc = new_notification_service(fake_notification_store(ctx), "s");
    let r = poll_closing_soon(svc);
    guard let _n = r else let e = err_of(r) { panic(e); }
    assert(ctx.calls[0] == "mark_sent mkt-1", ctx.calls[0]);
}

fn due(id: str, to: str, attempts: int) -> DueEmail {
    return DueEmail {
        id: id, account_id: "00000000-0000-4000-8000-000000000001", kind: "closing_soon", username: "ada",
        email: to, subject: "Market closing soon", body_text: "Q closes at 16:00.", link_url: "/markets/m", attempts: attempts
    };
}

fn test_should_send_due_emails_with_a_working_unsubscribe_token_and_retry_failures() {
    let ctx = fake_ctx();
    ctx.due = [due("e1", "ada@say.test", 1), due("e2", "down@say.test", 3)];
    let sender = FakeSender { sent: [], fail_to: "down@say.test" };
    let svc = new_notification_service(fake_notification_store(ctx), "secret-1");
    let now_s = 1800000000;
    let r = deliver_emails(svc, NoticeSender[FakeSender] { context: sender, send: fake_send }, now_s);
    guard let report = r else let e = err_of(r) { panic(e); }
    assert(report.sent == 1);
    assert(len(report.problems) == 1, report.problems[0]);
    assert(len(sender.sent) == 1);
    let tok = domain.verify_unsubscribe_token("secret-1", sender.sent[0].unsubscribe_token, now_s + 86400);
    guard let t = tok else let e = err_of(tok) { panic(e); }
    assert(t.kind == "closing_soon");
    assert(t.account_id == "00000000-0000-4000-8000-000000000001");
    assert(ctx.calls[0] == "sent e1", ctx.calls[0]);
    assert(ctx.calls[1] == "retry e2 in " + to_str(domain.email_backoff_seconds(3)), ctx.calls[1]);
}
