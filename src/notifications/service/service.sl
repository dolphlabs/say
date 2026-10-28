import "../domain" as domain;

pub gc struct NotificationService[C] {
    store: NotificationStore[C],
    secret: str
}

pub fn new_notification_service[C](store: NotificationStore[C], secret: str) -> NotificationService[C] {
    return NotificationService[C] {
        store: store,
        secret: secret
    };
}

pub fn get_notifications[C](
    s: NotificationService[C],
    account_id: str,
    cursor: str,
    limit: int
) -> result[domain.NotificationPage, str] {
    let lim = limit;
    if lim <= 0 || lim > 100 {
        lim = 20;
    }
    return (s.store.get_notifications)(s.store.context, account_id, cursor, lim);
}

pub fn mark_read[C](
    s: NotificationService[C],
    account_id: str,
    ids: [str],
    mark_all: bool
) -> result[int, str] {
    return (s.store.mark_read)(s.store.context, account_id, ids, mark_all);
}

pub fn get_prefs[C](
    s: NotificationService[C],
    account_id: str
) -> result[[domain.NotificationPref], str] {
    return (s.store.get_prefs)(s.store.context, account_id);
}

pub fn set_pref[C](
    s: NotificationService[C],
    account_id: str,
    kind: str,
    in_app: bool,
    email: bool
) -> result[int, str] {
    return (s.store.set_pref)(s.store.context, account_id, kind, in_app, email);
}

pub fn unsubscribe[C](
    s: NotificationService[C],
    token: str,
    now_s: int
) -> result[int, str] {
    let tok_res = domain.verify_unsubscribe_token(s.secret, token, now_s);
    guard let tok = tok_res else let e = err_of(tok_res) {
        return err(e);
    }
    return (s.store.unsubscribe_email)(s.store.context, tok.account_id, tok.kind);
}

pub fn poll_closing_soon[C](
    s: NotificationService[C]
) -> result[int, str] {
    let markets_res = (s.store.find_closing_soon_markets)(s.store.context);
    guard let markets = markets_res else let e = err_of(markets_res) {
        return err(e);
    }

    let count = 0;
    for m in markets {
        let mark_res = (s.store.mark_closing_soon_sent)(s.store.context, m.market_id);
        if let _ = mark_res {
            let notice = domain.closing_soon_template(m.question, m.close_at_wat);
            let job_res = (s.store.create_fanout_job)(s.store.context, "closing_soon", m.market_id);
            if let job = job_res {
                let _ = process_fanout(s, job.id, "closing_soon", m.market_id, notice.title, notice.body, notice.link_url);
            }
            count = count + 1;
        }
    }
    return ok(count);
}

pub fn process_fanout[C](
    s: NotificationService[C],
    job_id: str,
    kind: str,
    subject: str,
    title: str,
    body: str,
    link_url: str
) -> result[int, str] {
    let cursor = "";
    let batch_size = 1000;
    let total_notified = 0;

    while true {
        let recips_res = (s.store.find_job_recipients)(s.store.context, kind, subject, cursor, batch_size);
        guard let recips = recips_res else let e = err_of(recips_res) {
            return err(e);
        }

        if len(recips) == 0 {
            let _ = (s.store.complete_job)(s.store.context, job_id);
            break;
        }

        let notices: [NoticeToWrite] = [];
        let emails: [EmailToWrite] = [];
        let next_cursor = cursor;

        for r in recips {
            next_cursor = r.account_id;
            let dedupe_key = kind + ":" + subject;
            if r.in_app {
                push(notices, NoticeToWrite {
                    account_id: r.account_id,
                    kind: kind,
                    dedupe_key: dedupe_key,
                    title: title,
                    body: body,
                    link_url: link_url,
                    data_json: "{}"
                });
            }
            if r.send_email && len(r.email) > 0 {
                push(emails, EmailToWrite {
                    account_id: r.account_id,
                    kind: kind,
                    dedupe_key: dedupe_key + ":email",
                    recipient_email: r.email,
                    subject: title,
                    body_text: body,
                    body_html: "<p>" + body + "</p>"
                });
            }
        }

        let write_res = (s.store.write_notification_batch)(s.store.context, job_id, notices, emails, next_cursor);
        guard let written = write_res else let e = err_of(write_res) {
            return err(e);
        }
        total_notified = total_notified + written;
        cursor = next_cursor;

        if len(recips) < batch_size {
            let _ = (s.store.complete_job)(s.store.context, job_id);
            break;
        }
    }

    return ok(total_notified);
}
