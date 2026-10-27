import "../domain" as domain;

pub gc struct JournalRows { entries: [domain.Entry], holds: [domain.HoldOp] }
pub gc struct JournalBatch { transactions: [domain.LedgerTx] }
pub gc struct JournalFailure { code: str, asset: str, needed: int, available: int, detail: str }

pub fn journal_rows() -> JournalRows {
    let entries: [domain.Entry]=[]; let holds: [domain.HoldOp]=[];
    return JournalRows { entries:entries,holds:holds };
}

pub fn journal_batch() -> JournalBatch {
    let transactions: [domain.LedgerTx]=[];
    return JournalBatch { transactions:transactions };
}

pub fn journal_entry(rows: JournalRows,owner_kind: str,owner_id: str,asset: str,bucket: str,delta: int,hold: str) {
    push(rows.entries,domain.Entry { owner:domain.Owner { kind:owner_kind,id:owner_id },asset_key:asset,bucket:bucket,delta:delta,hold:hold });
}

pub fn journal_hold(rows: JournalRows,op: str,id: str,owner_kind: str,owner_id: str,asset: str,amount: int) {
    push(rows.holds,domain.HoldOp { op:op,hold_id:id,owner:domain.Owner { kind:owner_kind,id:owner_id },asset_key:asset,amount:amount });
}

pub fn journal_append(batch: JournalBatch,rows: JournalRows,key: str,kind: str,season_id: str,market_id: str,ref_type: str,ref_id: str) {
    push(batch.transactions,domain.LedgerTx { business_key:key,kind:kind,season_id:season_id,market_id:market_id,
        ref_type:ref_type,ref_id:ref_id,metadata:"{}",entries:rows.entries,holds:rows.holds });
}

pub fn journal_reserve(batch: JournalBatch,owner_kind: str,account_id: str,season_id: str,asset: str,amount: int,order_id: str,key: str) {
    push(batch.transactions,domain.hold_tx(domain.Owner { kind:owner_kind,id:account_id },season_id,asset,amount,"order",order_id,key,"{}"));
}

pub fn journal_problem(batch: JournalBatch) -> opt[str] {
    for tx in batch.transactions { if let e=domain.validate(tx) { return some(domain.fault_name(e.fault)); } }
    return none;
}

pub fn journal_failure(error: domain.LedgerError) -> JournalFailure {
    let code="UNAVAILABLE";
    switch error.fault {
        case domain.Fault.InsufficientFunds { code="INSUFFICIENT_FUNDS"; if error.asset!="SEDI" { code="INSUFFICIENT_SHARES"; } }
        case domain.Fault.IdempotencyConflict { code="IDEMPOTENCY_CONFLICT"; }
        case domain.Fault.SeasonNotActive { code="SEASON_NOT_ACTIVE"; }
        case domain.Fault.Overflow { code="OVERFLOW"; }
        default {}
    }
    return JournalFailure { code:code,asset:error.asset,needed:error.needed,available:error.available,detail:error.detail };
}

pub fn journal_encode_error(error: domain.LedgerError) -> str { return domain.encode(error); }
pub fn journal_decode_error(error: str) -> JournalFailure { return journal_failure(domain.decode(error)); }
