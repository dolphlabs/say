import "../domain" as domain;

pub gc struct ClosingSoonMarket {
    market_id: str,
    question: str,
    close_at_wat: str
}

pub gc struct NotificationRecipient {
    account_id: str,
    email: str,
    in_app: bool,
    send_email: bool
}

pub gc struct NoticeToWrite {
    account_id: str,
    kind: str,
    dedupe_key: str,
    title: str,
    body: str,
    link_url: str,
    data_json: str
}

pub gc struct EmailToWrite {
    account_id: str,
    kind: str,
    dedupe_key: str,
    recipient_email: str,
    subject: str,
    body_text: str,
    body_html: str
}

pub gc struct NotificationStore[C] {
    context: C,
    get_notifications: fn(C, str, str, int) -> result[domain.NotificationPage, str],
    mark_read: fn(C, str, [str], bool) -> result[int, str],
    get_prefs: fn(C, str) -> result[[domain.NotificationPref], str],
    set_pref: fn(C, str, str, bool, bool) -> result[int, str],
    unsubscribe_email: fn(C, str, str) -> result[int, str],
    find_closing_soon_markets: fn(C) -> result[[ClosingSoonMarket], str],
    mark_closing_soon_sent: fn(C, str) -> result[int, str],
    create_fanout_job: fn(C, str, str) -> result[domain.FanoutJob, str],
    find_job_recipients: fn(C, str, str, str, int) -> result[[NotificationRecipient], str],
    write_notification_batch: fn(C, str, [NoticeToWrite], [EmailToWrite], str) -> result[int, str],
    complete_job: fn(C, str) -> result[int, str]
}
