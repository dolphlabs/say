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
