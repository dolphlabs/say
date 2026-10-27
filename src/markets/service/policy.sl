pub gc struct MarketPolicy {
    market_id: str, season_id: str, redemption_units: int, min_price: int, max_price: int, tick: int,
    max_order_qty: int, fee_units: int, min_order_notional: int, close_at: int, terms_version: int
}

pub fn policy[C](s: Markets[C],market_id: str) -> result[MarketPolicy,Failed] {
    let r=get(s,market_id,"");
    guard let m=r else let f=err_of(r) { return err(f); }
    let key=m.id+":"+to_str(m.terms_version);
    mutex_lock(s.lock);
    if has(s.policies,key) { let saved=s.policies[key]; mutex_unlock(s.lock); return ok(saved); }
    let p=MarketPolicy { market_id:m.id,season_id:m.season_id,redemption_units:m.redemption_units,
        min_price:m.min_price,max_price:m.max_price,tick:m.tick,max_order_qty:m.max_order_qty,
        fee_units:m.fee_units,min_order_notional:m.min_order_notional,close_at:m.close_at,terms_version:m.terms_version };
    s.policies[key]=p;
    mutex_unlock(s.lock);
    return ok(p);
}
