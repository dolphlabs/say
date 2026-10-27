import "../domain" as core;

fn quote_policy(v: int) -> PolicyView {
    return PolicyView { policy:core.Policy { market_id:"00000000-0000-4000-a000-000000000900",season_id:"00000000-0000-4000-a000-000000000901",
        V:v,min_price:1,max_price:v-1,tick:1,max_order_qty:1000,min_order_notional:2 },status:"OPEN",close_at:20000,terms_version:1,slippage_ticks:3 };
}
fn quote_view() -> BookView {
    let bids=[ViewLevel { yes_price:60,qty:20 }]; let asks=[ViewLevel { yes_price:70,qty:20 }];
    return BookView { market_id:quote_policy(100).policy.market_id,owner_epoch:1,committed_seq:20,book_seq:10,last_price:none,pending_count:0,
        as_of:1000,lease_until:20000,health:"READY",mode:"OPEN",bids:bids,asks:asks };
}
fn quote_intent() -> Intent {
    return Intent { account_id:"00000000-0000-4000-a000-000000000011",market_id:quote_policy(100).policy.market_id,
        request_type:"market",outcome:"YES",side:"BUY",price:none,qty:none,tif:none,spend:some(101) };
}
fn test_market_buy_cap_reservation_fits_budget_even_when_depth_is_cheaper() {
    let view=quote_view(); view.asks=[ViewLevel { yes_price:10,qty:100 }];
    let normalized=normalize(quote_intent(),quote_policy(100),view,1000,1000); guard let order=normalized else let f=err_of(normalized) { panic(f.code); }
    assert(order.limit==13 && order.qty==7 && order.qty*order.limit+1<=101 && (order.estimated_principal ?? 0)==70 && order.tif=="IOC");
}
fn test_no_buy_and_no_sell_use_opposite_yes_depth() {
    let request=quote_intent(); request.outcome="NO"; request.spend=some(1000);
    let view=quote_view();
    let buy=normalize(request,quote_policy(100),view,1000,1000); guard let b=buy else { panic("no buy"); }
    assert(b.limit==43 && b.qty==20 && (b.estimated_principal ?? 0)==800);
    request.side="SELL"; request.spend=none; request.qty=some(3);
    let sell=normalize(request,quote_policy(100),view,1000,1000); guard let s=sell else { panic("no sell"); }
    assert(s.limit==27 && s.qty==3 && s.tif=="IOC");
}
fn test_original_intent_hash_ignores_quote_changes_and_normalizes_default_tif() {
    let request=quote_intent(); let before=intent_hash(request);
    let view=quote_view(); view.asks=[ViewLevel { yes_price:10,qty:100 }];
    let first=normalize(request,quote_policy(100),view,1000,1000); guard let a=first else { panic("first"); }
    view.asks=[ViewLevel { yes_price:20,qty:100 }];
    let second=normalize(request,quote_policy(100),view,1000,1000); guard let b=second else { panic("second"); }
    assert(a.limit!=b.limit && intent_hash(request)==before);
    request.request_type="limit"; request.price=some(40); request.qty=some(2); request.spend=none;
    let defaulted=intent_hash(request); request.tif=some("GTC"); assert(intent_hash(request)==defaulted);
    request.qty=some(3); assert(intent_hash(request)!=defaulted);
}
fn test_market_order_shape_staleness_grid_and_close_fail_before_holds() {
    let request=quote_intent(); request.qty=some(1);
    guard let shape=intent_shape(request) else { panic("mixed market buy fields accepted"); }
    assert(shape.field=="qty"); request.qty=none;
    let stale=normalize(request,quote_policy(100),quote_view(),3000,1000);
    if let _bad=stale { panic("stale quote accepted"); } else let f=err_of(stale) { assert(f.code=="MARKET_DEGRADED"); }
    let closed=normalize(request,quote_policy(100),quote_view(),20000,1000);
    if let _bad=closed { panic("closed market accepted"); } else let f=err_of(closed) { assert(f.code=="MARKET_NOT_OPEN"); }
    let p=quote_policy(200); p.policy.min_price=2; p.policy.max_price=198; p.policy.tick=2;
    request.request_type="limit"; request.price=some(3); request.qty=some(2); request.spend=none;
    let tick=normalize(request,p,quote_view(),1000,1000);
    if let _bad=tick { panic("off-grid limit accepted"); } else let f=err_of(tick) { assert(f.code=="OFF_TICK"); }
}
