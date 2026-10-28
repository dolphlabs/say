import "../domain" as domain;

gc struct FakeNotifStoreCtx {
    notifs: [domain.NotificationItem],
    prefs: [domain.NotificationPref],
    closing_markets: [ClosingSoonMarket]
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
    return ok(1);
}

fn fake_create_fanout_job(ctx: FakeNotifStoreCtx, kind: str, subj: str) -> result[domain.FanoutJob, str] {
    return ok(domain.FanoutJob {
        id: "job-1",
        kind: kind,
        subject: subj,
        cursor: "",
        done: false
    });
}

fn fake_find_job_recipients(ctx: FakeNotifStoreCtx, kind: str, subj: str, cur: str, lim: int) -> result[[NotificationRecipient], str] {
    let recips = [
        NotificationRecipient {
            account_id: "acc-1",
            email: "user1@say.fun",
            in_app: true,
            send_email: false
        }
    ];
    return ok(recips);
}

fn fake_write_notification_batch(ctx: FakeNotifStoreCtx, jid: str, notices: [NoticeToWrite], emails: [EmailToWrite], cur: str) -> result[int, str] {
    return ok(len(notices));
}

fn fake_complete_job(ctx: FakeNotifStoreCtx, jid: str) -> result[int, str] {
    return ok(1);
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
        ]
    };

    let store = NotificationStore[FakeNotifStoreCtx] {
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
        complete_job: fake_complete_job
    };

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
