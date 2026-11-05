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

// A market is marked sent only once its fan-out has finished, so a failed
// round is picked up again by the next poll and resumes where it stopped.
pub fn poll_closing_soon[C](
    s: NotificationService[C]
) -> result[int, str] {
    let markets_res = (s.store.find_closing_soon_markets)(s.store.context);
    guard let markets = markets_res else let e = err_of(markets_res) {
        return err(e);
    }

    let count = 0;
    let failed = 0;
    let first = "";
    for m in markets {
        let notice = domain.closing_soon_template(m.question, m.close_at_wat);
        let fan = fan_out(s, "closing_soon", m.market_id, notice.title, notice.body, "/markets/" + m.market_id);
        guard let _n = fan else let e = err_of(fan) {
            failed += 1;
            if len(first) == 0 { first = m.market_id + ": " + e; }
            continue;
        }
        let mark_res = (s.store.mark_closing_soon_sent)(s.store.context, m.market_id);
        guard let _m = mark_res else let e = err_of(mark_res) {
            failed += 1;
            if len(first) == 0 { first = m.market_id + ": " + e; }
            continue;
        }
        count += 1;
    }
    if failed > 0 {
        return err("closing_soon: " + to_str(failed) + " market(s) failed, first " + first);
    }
    return ok(count);
}

// Creates the job for (kind, subject), or resumes the one already there.
pub fn fan_out[C](
    s: NotificationService[C],
    kind: str,
    subject: str,
    title: str,
    body: str,
    link_url: str
) -> result[int, str] {
    let job_res = (s.store.create_fanout_job)(s.store.context, kind, subject);
    guard let job = job_res else let e = err_of(job_res) {
        return err(e);
    }
    if job.done {
        return ok(0);
    }
    return process_fanout(s, job.id, kind, subject, job.cursor, title, body, link_url);
}

pub fn process_fanout[C](
    s: NotificationService[C],
    job_id: str,
    kind: str,
    subject: str,
    start_cursor: str,
    title: str,
    body: str,
    link_url: str
) -> result[int, str] {
    let cursor = start_cursor;
    let batch_size = 1000;
    let total_notified = 0;

    while true {
        let recips_res = (s.store.find_job_recipients)(s.store.context, kind, subject, cursor, batch_size);
        guard let recips = recips_res else let e = err_of(recips_res) {
            return err(e);
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
                    link_url: link_url
                });
            }
        }

        if len(recips) > 0 {
            let write_res = (s.store.write_notification_batch)(s.store.context, job_id, notices, emails, next_cursor);
            guard let written = write_res else let e = err_of(write_res) {
                return err(e);
            }
            total_notified = total_notified + written;
            cursor = next_cursor;
        }

        if len(recips) < batch_size {
            let done = (s.store.complete_job)(s.store.context, job_id);
            guard let _d = done else let e = err_of(done) {
                return err(e);
            }
            break;
        }
    }

    return ok(total_notified);
}

pub gc struct DeliveryReport {
    sent: int,
    problems: [str]
}

// Rows are claimed with a lease, so two nodes never send the same email
// while either is still inside it; a failed send is retried with backoff
// until email_max_attempts.
pub fn deliver_emails[C, M](s: NotificationService[C], m: NoticeSender[M], now_s: int) -> result[DeliveryReport, str] {
    let claimed = (s.store.claim_emails)(s.store.context, 20, 120);
    guard let due = claimed else let e = err_of(claimed) {
        return err(e);
    }
    let problems: [str] = [];
    let sent = 0;
    for d in due {
        let token = domain.sign_unsubscribe_token(s.secret, d.account_id, d.kind, now_s + domain.unsubscribe_ttl_seconds());
        let outcome = (m.send)(m.context, NoticeMail {
            to: d.email, username: d.username, subject: d.subject, body: d.body_text,
            link_url: d.link_url, unsubscribe_token: token
        });
        if let _ok = outcome {
            let done = (s.store.email_sent)(s.store.context, d.id);
            if let _d = done {
                sent += 1;
            } else let e = err_of(done) {
                push(problems, "email " + d.id + " sent but not marked: " + e);
            }
        } else let e = err_of(outcome) {
            let retry = (s.store.email_retry)(s.store.context, d.id, e, domain.email_backoff_seconds(d.attempts));
            push(problems, "email " + d.id + " attempt " + to_str(d.attempts) + " failed: " + e);
            if let _r = retry {
            } else let re = err_of(retry) {
                push(problems, "email " + d.id + " retry not recorded: " + re);
            }
        }
    }
    return ok(DeliveryReport { sent: sent, problems: problems });
}
