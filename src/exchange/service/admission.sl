import "builder";
import "crypto";
import "encoding";
import "../domain" as core;

pub gc struct Failure { code: str, field: str, needed: int, available: int, asset: str, detail: str }
pub fn failed(code: str,field: str,detail: str) -> Failure {
    return Failure { code:code,field:field,needed:0,available:0,asset:"",detail:detail };
}
pub gc struct Intent {
    account_id: str,market_id: str,request_type: str,outcome: str,side: str,
    price: opt[int],qty: opt[int],tif: opt[str],spend: opt[int]
}
pub gc struct ViewLevel { yes_price: int,qty: int }
pub gc struct BookView {
    market_id: str,owner_epoch: int,committed_seq: int,book_seq: int,last_price: opt[int],pending_count: int,
    as_of: int,lease_until: int,health: str,mode: str,bids: [ViewLevel],asks: [ViewLevel]
}
pub gc struct PolicyView { policy: core.Policy,status: str,close_at: int,terms_version: int,slippage_ticks: int }
pub gc struct Normalized {
    limit: int,qty: int,tif: str,estimated_principal: opt[int],view_seq: opt[int],protection_limit: opt[int]
}

pub fn intent_shape(i: Intent) -> opt[Failure] {
    let scratch=core.byte_writer(36);
    if !core.canonical_uuid(i.account_id,scratch.data) { return some(failed("BAD_REQUEST","account_id","Invalid authenticated account.")); }
    if !core.canonical_uuid(i.market_id,scratch.data) { return some(failed("BAD_REQUEST","market_id","Use a market UUID.")); }
    if i.outcome!="YES" && i.outcome!="NO" { return some(failed("BAD_REQUEST","outcome","Choose YES or NO.")); }
    if i.side!="BUY" && i.side!="SELL" { return some(failed("BAD_REQUEST","side","Choose BUY or SELL.")); }
    if i.request_type!="limit" && i.request_type!="market" { return some(failed("BAD_REQUEST","type","Choose limit or market.")); }
    if i.request_type=="limit" {
        guard let price=i.price else { return some(failed("BAD_REQUEST","price","A limit price is required.")); }
        if price<1 || price>1000 { return some(failed("PRICE_OUT_OF_BAND","price","Use an integer price within the market band.")); }
        if let _spend=i.spend { return some(failed("BAD_REQUEST","spend","Limit orders specify price and quantity.")); }
        let tif=i.tif ?? "GTC";
        if tif!="GTC" && tif!="IOC" { return some(failed("BAD_REQUEST","tif","Choose GTC or IOC.")); }
    } else {
        if let _price=i.price { return some(failed("BAD_REQUEST","price","Market orders derive their protection price.")); }
        if let _tif=i.tif { return some(failed("BAD_REQUEST","tif","Market orders use IOC.")); }
        if i.side=="BUY" {
            if let _qty=i.qty { return some(failed("BAD_REQUEST","qty","A market buy specifies its maximum spend.")); }
            guard let spend=i.spend else { return some(failed("BAD_REQUEST","spend","A maximum spend is required.")); }
            if spend<=1 { return some(failed("BAD_REQUEST","spend","Spend must cover principal and the S 1 fee.")); }
            return none;
        }
        if let _spend=i.spend { return some(failed("BAD_REQUEST","spend","A market sell specifies quantity.")); }
    }
    guard let qty=i.qty else { return some(failed("BAD_REQUEST","qty","A quantity is required.")); }
    if qty<1 || qty>10000000 { return some(failed("QTY_TOO_LARGE","qty","Use a positive quantity within the market limit.")); }
    return none;
}

fn intent_part(b: builder.Str,value: str) { b.write_int(len(value)).write(":").write(value); }
fn intent_integer(b: builder.Str,value: int) { intent_part(b,to_str(value)); }

pub fn intent_hash(i: Intent) -> str {
    let b=builder.new_str();
    intent_part(b,"say.intent.v1"); intent_part(b,i.account_id); intent_part(b,i.market_id);
    intent_part(b,i.request_type); intent_part(b,i.outcome); intent_part(b,i.side);
    if i.request_type=="limit" {
        intent_integer(b,i.price ?? 0); intent_integer(b,i.qty ?? 0); intent_part(b,i.tif ?? "GTC");
    } else if i.side=="BUY" { intent_integer(b,i.spend ?? 0); }
    else { intent_integer(b,i.qty ?? 0); }
    return encoding.hex_encode(crypto.sha256(to_bytes(b.finish())));
}

pub fn normalize(i: Intent,p: PolicyView,view: BookView,now: int,max_age: int) -> result[Normalized,Failure] {
    if let error=intent_shape(i) { return err(error); }
    let policy=p.policy;
    if i.market_id!=policy.market_id || view.market_id!=i.market_id || max_age<1 || p.slippage_ticks<0 || p.slippage_ticks>1000 { return err(failed("MARKET_DEGRADED","market_id","Market policy is unavailable.")); }
    if p.status=="SUSPENDED" { return err(failed("MARKET_SUSPENDED","market_id","Trading is temporarily suspended.")); }
    if p.status!="OPEN" || now>=p.close_at { return err(failed("MARKET_NOT_OPEN","market_id","This market is not open for trading.")); }
    if view.health!="READY" || view.owner_epoch<1 || view.lease_until<=now || view.pending_count<0 { return err(failed("MARKET_DEGRADED","market_id","The market is recovering.")); }
    if i.request_type=="limit" {
        let price=i.price ?? 0; let qty=i.qty ?? 0;
        if price<policy.min_price || price>policy.max_price { return err(failed("PRICE_OUT_OF_BAND","price","Use a price inside this market's band.")); }
        if price%policy.tick!=0 { return err(failed("OFF_TICK","price","Use a price on this market's tick grid.")); }
        if qty>policy.max_order_qty { return err(failed("QTY_TOO_LARGE","qty","Quantity exceeds this market's maximum.")); }
        guard let notional=core.mul_units(price,qty) else { return err(failed("OVERFLOW","qty","The order amount is too large.")); }
        if notional<policy.min_order_notional { return err(failed("BELOW_MIN_NOTIONAL","qty","The order is below the minimum notional.")); }
        if let _hold=core.add_units(notional,1) {} else { return err(failed("OVERFLOW","qty","The order amount is too large.")); }
        return ok(Normalized { limit:price,qty:qty,tif:i.tif ?? "GTC",estimated_principal:none,view_seq:none,protection_limit:none });
    }
    if now<0 || view.as_of<0 || now-view.as_of>max_age || view.as_of-now>max_age { return err(failed("MARKET_DEGRADED","market_id","The quote is stale. Try again.")); }
    let levels=view.asks;
    if (i.side=="BUY" && i.outcome=="NO") || (i.side=="SELL" && i.outcome=="YES") { levels=view.bids; }
    if len(levels)==0 { return err(failed("NO_LIQUIDITY_IN_RANGE","market_id","There is no liquidity within the protection range.")); }
    let best=levels[0].yes_price; if i.outcome=="NO" { best=policy.V-best; }
    guard let slippage=core.mul_units(p.slippage_ticks,policy.tick) else { return err(failed("OVERFLOW","price","The protection amount is too large.")); }
    let limit=best+slippage; if limit>policy.max_price { limit=policy.max_price; }
    if i.side=="SELL" { limit=best-slippage; if limit<policy.min_price { limit=policy.min_price; } }
    if best<policy.min_price || best>policy.max_price || best%policy.tick!=0 || limit%policy.tick!=0 { return err(failed("MARKET_DEGRADED","market_id","The quote does not match the market grid.")); }
    if i.side=="SELL" {
        let qty=i.qty ?? 0;
        if qty>policy.max_order_qty { return err(failed("QTY_TOO_LARGE","qty","Quantity exceeds this market's maximum.")); }
        guard let notional=core.mul_units(limit,qty) else { return err(failed("OVERFLOW","qty","The order amount is too large.")); }
        if notional<policy.min_order_notional { return err(failed("BELOW_MIN_NOTIONAL","qty","The order is below the minimum notional.")); }
        return ok(Normalized { limit:limit,qty:qty,tif:"IOC",estimated_principal:none,view_seq:some(view.book_seq),protection_limit:some(limit) });
    }
    let budget=(i.spend ?? 0)-1;
    let hold_qty=budget/limit; if hold_qty>policy.max_order_qty { hold_qty=policy.max_order_qty; }
    let qty=0; let principal=0;
    for level in levels {
        let price=level.yes_price; if i.outcome=="NO" { price=policy.V-price; }
        if price>limit || qty==hold_qty { break; }
        if price<policy.min_price || price>policy.max_price || price%policy.tick!=0 || level.qty<=0 { return err(failed("MARKET_DEGRADED","market_id","The quote contains an invalid level.")); }
        let take=(budget-principal)/price;
        if take>level.qty { take=level.qty; } if take>hold_qty-qty { take=hold_qty-qty; }
        if take<=0 { break; }
        guard let cost=core.mul_units(price,take) else { return err(failed("OVERFLOW","spend","The estimated amount is too large.")); }
        qty+=take; principal+=cost;
    }
    if qty<=0 { return err(failed("NO_LIQUIDITY_IN_RANGE","spend","The spend cannot reserve an executable protected quantity.")); }
    guard let notional=core.mul_units(limit,qty) else { return err(failed("OVERFLOW","spend","The protected amount is too large.")); }
    if notional<policy.min_order_notional { return err(failed("BELOW_MIN_NOTIONAL","spend","The order is below the minimum notional.")); }
    return ok(Normalized { limit:limit,qty:qty,tif:"IOC",estimated_principal:some(principal),view_seq:some(view.book_seq),protection_limit:some(limit) });
}
