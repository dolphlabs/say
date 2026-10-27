import "../../ledger/service" as ledger;

pub fn journal_of(record: Record) -> ledger.JournalBatch {
    let batch=ledger.journal_batch();
    for posting in record.postings {
        let rows=ledger.journal_rows();
        for entry in posting.entries {
            ledger.journal_entry(rows,entry.owner.kind,entry.owner.id,entry.asset_key,entry.bucket,entry.delta,entry.hold);
        }
        for hold in posting.holds {
            ledger.journal_hold(rows,hold.op,hold.hold_id,hold.owner.kind,hold.owner.id,hold.asset_key,hold.amount);
        }
        ledger.journal_append(batch,rows,posting.business_key,posting.kind,posting.season_id,posting.market_id,posting.ref_type,posting.ref_id);
    }
    return batch;
}
