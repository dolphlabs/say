pub gc struct Request {
    id: str, kind: str, subject_type: str, subject_id: str, payload_hash: str,
    requested_by: str, approval_round: int, slot: int, status: str, version: int, expires_at: int
}
