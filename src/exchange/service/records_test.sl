import "../domain" as core;
import "json";
import "../../ledger/service" as ledger;

fn test_decided_replay_matches_original_without_matching() {
    let p = core.Policy { market_id: "00000000-0000-4000-a000-000000000900", season_id: "00000000-0000-4000-a000-000000000901",
        V: 100, min_price: 1, max_price: 99, tick: 1, max_order_qty: 1000, min_order_notional: 2 };
    let created = core.new_book(p, 8, 0); guard let b = created else { panic("book"); }
    let initial = core.snapshot(&b); let w = core.new_workspace(&b, 8);
    let cmd = core.Command { kind: "Snapshot", seq: 1, ref: p.market_id, order: core.empty_order(), order_id: "", account_id: "", system: true, reason: "" };
    assert(core.plan(&b, cmd, &mut w) == "");
    let converted = record(&b, &mut w); guard let r = converted else { panic("record"); }
    let encoded = json.encode(r); let decoded: result[Record, str] = json.decode(encoded); guard let rr = decoded else { panic("codec"); }
    assert(core.apply(&mut b, &mut w) == "");
    let restored = core.restore(initial, 3); guard let copy = restored else { panic("restore"); }
    let scratch = core.new_workspace(&copy, 4);
    assert(prepare_replay(&copy, rr, &mut scratch) == "");
    assert(core.apply(&mut copy, &mut scratch) == "");
    assert(json.encode(core.snapshot(&copy)) == json.encode(core.snapshot(&b)));
    assert(prepare_replay(&copy, rr, &mut scratch) == "STALE_TRANSITION");
}

fn test_authoritative_rejection_record_replays_without_current_gate_reads() {
    let p=core.Policy { market_id:"00000000-0000-4000-a000-000000000900",season_id:"00000000-0000-4000-a000-000000000901",
        V:100,min_price:1,max_price:99,tick:1,max_order_qty:1000,min_order_notional:2 };
    let created=core.new_book(p,4,0); guard let b=created else { panic("book"); }
    let before=core.snapshot(&b); let w=core.new_workspace(&b,4);
    let o=core.empty_order(); o.id="00000000-0000-4000-a000-000000000001"; o.account_id="00000000-0000-4000-a000-000000000011";
    o.owner_kind="user"; o.outcome="YES"; o.side="BUY"; o.limit=70; o.qty=2; o.remaining=2; o.tif="GTC"; o.accepted_seq=1;
    o.sedi_hold_id="00000000-0000-4000-a000-000000000012"; o.sedi_original=141;
    let cmd=core.Command { kind:"RejectPlace",seq:1,ref:o.id,order:o,order_id:"",account_id:"",system:true,reason:"TRADING_HALTED" };
    assert(core.plan(&b,cmd,&mut w)=="");
    let materialized=record(&b,&mut w); guard let r=materialized else { panic("record"); }
    assert(r.decision=="TRADING_HALTED" && len(r.fills)==0 && len(r.postings)==1);
    let batch=journal_of(r); if let error=ledger.journal_problem(batch) { panic(error); }
    assert(len(batch.transactions)==1 && batch.transactions[0].entries[0].delta == -141);
    assert(core.apply(&mut b,&mut w)=="");
    let restored=core.restore(before,7); guard let copy=restored else { panic("restore"); }
    let replay=core.new_workspace(&copy,7);
    assert(prepare_replay(&copy,r,&mut replay)=="");
    assert(core.apply(&mut copy,&mut replay)=="");
    assert(json.encode(core.snapshot(&copy))==json.encode(core.snapshot(&b)));
}
