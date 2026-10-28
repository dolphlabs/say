pub gc struct RequesterInfo {
    username: str,
    role: str
}

pub gc struct ApprovalInboxItem {
    id: str,
    kind: str,
    title: str,
    detail: str,
    requested_by: RequesterInfo,
    requester_account_id: str,
    requested_at: int,
    can_decide: bool,
    cannot_decide_reason: str,
    subject_link: str,
    payload_hash: str,
    status: str
}

pub gc struct Request {
    id: str, kind: str, subject_type: str, subject_id: str, payload_hash: str,
    requested_by: str, approval_round: int, slot: int, status: str, version: int, expires_at: int
}

pub gc struct ApprovalStore[C] {
    context: C,
    request: fn(C, str, str, str, str, str, int, int, str, int) -> result[str, str],
    load_by_id: fn(C, str) -> result[opt[Request], str],
    list_inbox: fn(C, str, str) -> result[[ApprovalInboxItem], str],
    decide: fn(C, Request, str, str, str, int) -> result[bool, str]
}
