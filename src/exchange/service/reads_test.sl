gc struct ReadFake { calls: int }

fn read_fake_order(f: ReadFake,_account: str,_order: str) -> result[opt[ReadOrder],str] {
    f.calls+=1;
    let empty:opt[ReadOrder]=none;
    return ok(empty);
}

fn read_fake_orders(f: ReadFake,_account: str,_market: str,_status: str,_cursor: str,
                    _limit: int) -> result[ReadOrdersPage,str] {
    f.calls+=1;
    return ok(ReadOrdersPage { items:[],has_more:false });
}

fn read_fake_trades(f: ReadFake,_market: str,_seq: int,_index: int,_limit: int) -> result[ReadTradesPage,str] {
    f.calls+=1;
    return ok(ReadTradesPage { items:[],has_more:false });
}

fn read_fake_history(f: ReadFake,_market: str,_range: int,_bucket: int) -> result[[ReadCandle],str] {
    f.calls+=1;
    return ok([]);
}

fn read_fake_open_markets(f: ReadFake,_account: str) -> result[[str],str] {
    f.calls+=1;
    return ok(["00000000-0000-4000-a000-000000000002"]);
}

fn read_fake_store(f: ReadFake) -> ReadStore[ReadFake] {
    return ReadStore[ReadFake] {
        context:f,order:read_fake_order,orders:read_fake_orders,
        trades:read_fake_trades,history:read_fake_history,open_markets:read_fake_open_markets
    };
}

fn test_private_reads_validate_identity_and_pagination_bounds() {
    let fake=ReadFake { calls:0 };
    let store=read_fake_store(fake);
    let invalid_order=read_order(store,"not-an-id","also-invalid");
    if let _read=invalid_order { panic("invalid order identity accepted"); }
    else let e=err_of(invalid_order) { assert(e=="INVALID_READ_REQUEST"); }
    let invalid_page=read_orders(store,"00000000-0000-4000-a000-000000000001","",
        "open","",101);
    if let _page=invalid_page { panic("oversized order page accepted"); }
    else let e=err_of(invalid_page) { assert(e=="INVALID_READ_REQUEST"); }
    assert(fake.calls==0);
}

fn test_public_reads_validate_market_and_range() {
    let fake=ReadFake { calls:0 };
    let store=read_fake_store(fake);
    let bad_trades=read_trades(store,"invalid-market",0,0,50);
    if let _page=bad_trades { panic("invalid trades market accepted"); }
    else let e=err_of(bad_trades) { assert(e=="INVALID_READ_REQUEST"); }
    let bad_history=read_history(store,"00000000-0000-4000-a000-000000000001",30,60);
    if let _page=bad_history { panic("invalid history range accepted"); }
    else let e=err_of(bad_history) { assert(e=="INVALID_READ_REQUEST"); }
    assert(fake.calls==0);
}

fn test_should_reject_an_invalid_account_when_reading_open_markets() {
    let fake=ReadFake { calls:0 };
    let store=read_fake_store(fake);
    let bad=read_open_markets(store,"not-an-id");
    if let _m=bad { panic("invalid account accepted"); }
    else let e=err_of(bad) { assert(e=="INVALID_READ_REQUEST"); }
    assert(fake.calls==0);
    let good=read_open_markets(store,"00000000-0000-4000-a000-000000000001");
    guard let markets=good else { panic("valid account refused"); }
    assert(len(markets)==1);
    assert(fake.calls==1);
}
