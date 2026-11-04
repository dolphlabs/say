pub gc struct NotificationItem {
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

pub gc struct NotificationPref {
    kind: str,
    label: str,
    hint: str,
    in_app: bool,
    email: bool
}

pub gc struct NotificationPage {
    items: [NotificationItem],
    unread_count: int,
    next_cursor: str
}

pub gc struct FanoutJob {
    id: str,
    kind: str,
    subject: str,
    cursor: str,
    done: bool
}

pub gc struct UnsubscribeToken {
    account_id: str,
    kind: str,
    expires_at: int
}

// Market notices go to the people in that market; season notices go to everyone.
pub fn market_scoped(kind: str) -> bool {
    return kind == "closing_soon" || kind == "result_proposed" || kind == "market_settled";
}

pub fn email_max_attempts() -> int {
    return 10;
}

pub fn email_backoff_seconds(attempts: int) -> int {
    let d = 30;
    for i in 0..attempts {
        d = d * 2;
        if d >= 21600 {
            return 21600;
        }
    }
    return d;
}

pub fn unsubscribe_ttl_seconds() -> int {
    return 30 * 24 * 3600;
}
