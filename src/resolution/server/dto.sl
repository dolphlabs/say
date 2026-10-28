gc struct AddEvidenceDto {
    url: str,
    note: opt[str]
}

gc struct ProposeDto {
    outcome: str,
    reason: str,
    evidence_ids: [str],
    version: int
}

gc struct HoldDto {
    reason: str,
    version: int
}

gc struct DecideDisputeDto {
    decision: str,
    note: str
}

gc struct FinalizeDto {
    outcome: str,
    void_reason: opt[str],
    reason: str,
    version: int
}

gc struct CreateDisputeDto {
    reason: str,
    link_url: opt[str]
}
