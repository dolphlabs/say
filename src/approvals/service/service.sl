pub gc struct ApprovalsService[C] {
    store: ApprovalStore[C]
}

pub fn new_service[C](s: ApprovalStore[C]) -> ApprovalsService[C] {
    return ApprovalsService[C] { store: s };
}

pub fn list_inbox[C](svc: ApprovalsService[C], status_filter: str, kind_filter: str) -> result[[ApprovalInboxItem], str] {
    let f = svc.store.list_inbox;
    return f(svc.store.context, status_filter, kind_filter);
}

pub fn load_by_id[C](svc: ApprovalsService[C], approval_id: str) -> result[opt[Request], str] {
    let f = svc.store.load_by_id;
    return f(svc.store.context, approval_id);
}

pub fn decide[C](svc: ApprovalsService[C], req: Request, actor: str, decision: str, note: str, now: int) -> result[bool, str] {
    let f = svc.store.decide;
    return f(svc.store.context, req, actor, decision, note, now);
}

pub fn request[C](svc: ApprovalsService[C], kind: str, subject_type: str, subject_id: str, hash: str, requester: str, round: int, slot: int, reason: str, now: int) -> result[str, str] {
    let f = svc.store.request;
    return f(svc.store.context, kind, subject_type, subject_id, hash, requester, round, slot, reason, now);
}
