import "http";
import "json";
import "time";
import "zokor";
import "../../platform/app" as app;
import "../../platform/auth" as auth;
import "../service" as exchange;

pub fn mount(r: zokor.Router[app.App]) -> int {
    register_errors(r.errors);
    let orders=r.group("/v1/markets/:id/orders");
    orders.before(auth.require_session);
    orders.post("",place_order);
    let order=r.group("/v1/orders");
    order.before(auth.require_session);
    order.get("/:id",get_order);
    order.delete("/:id",cancel_order);
    let mine=r.group("/v1/me/orders");
    mine.before(auth.require_session);
    mine.get("",my_orders);
    let book=r.group("/v1/markets/:id");
    // zokor:public
    book.get("/book",book_view);
    book.get("/trades",trades);
    book.get("/history",history);
    return 0;
}

fn cancel_order(c: zokor.Ctx[app.App]) -> http.Response {
    if !exchange.valid_uuid(c.param("id")) { return fail(c,"BAD_REQUEST"); }
    if let response=order_rate_limit(c) { return response; }
    let cancel_result=exchange.enqueue_cancel_owned(c.state.command_queue,c.param("id"),
        c.local("account_id"),app.new_uuid());
    guard let receipt=cancel_result else let e=err_of(cancel_result) {
        if e=="ORDER_NOT_FOUND" { return fail(c,"ORDER_NOT_FOUND"); }
        if e=="ORDER_NOT_OPEN" { return fail(c,"ORDER_NOT_OPEN"); }
        if e=="QUEUE_FULL" { return fail(c,"QUEUE_FULL"); }
        c.state.settings.server.logger.warn("exchange","cancel enqueue failed: "+e);
        return fail(c,"UNAVAILABLE");
    }
    if let order=app.await_order(c.state,c.local("account_id"),c.param("id"),true) {
        return zokor.no_store(zokor.ok_json(order_json(order).set_str("command_id",receipt.command_ref).render()));
    }
    return zokor.no_store(zokor.json_response(202,zokor.jobj()
        .set_str("order_id",c.param("id")).set_str("command_id",receipt.command_ref)
        .set_str("status","CANCEL_PENDING").set_bool("existing",receipt.existing).render()));
}

fn admission_response(c: zokor.Ctx[app.App],receipt: exchange.AdmissionReceipt) -> http.Response {
    if let order=app.await_order(c.state,c.local("account_id"),receipt.order_id,false) {
        return zokor.no_store(zokor.ok_json(order_json(order).set_str("command_id",receipt.command_ref)
            .set_bool("existing",receipt.existing).render()));
    }
    let status=202 as i32;
    if receipt.existing && receipt.status!="ADMITTED" { status=200; }
    return zokor.no_store(zokor.json_response(status,zokor.jobj()
        .set_str("order_id",receipt.order_id).set_str("command_id",receipt.command_ref)
        .set_str("status",receipt.status).set_bool("existing",receipt.existing).render()));
}

fn order_json(order: exchange.ReadOrder) -> zokor.Json {
    let fee=0;
    if order.fee_paid { fee=1; }
    let body=zokor.jobj().set_str("order_id",order.order_id).set_str("market_id",order.market_id)
        .set_str("status",order.status).set_str("outcome",order.outcome).set_str("side",order.side)
        .set_int("price",order.price).set_int("qty",order.qty).set_int("remaining",order.remaining)
        .set_int("filled",order.filled).set_int("cancelled",order.cancelled)
        .set_int("accepted_seq",order.accepted_seq).set_bool("fee_paid",order.fee_paid)
        .set_int("filled_qty",order.filled).set_int("principal",order.principal).set_int("fee_charged",fee)
        .set_str("created_at",order.created_at);
    if order.filled>0 { body.set_float("avg_price",(order.principal as float)/(order.filled as float)); }
    else { body.set("avg_price",zokor.jnull()); }
    if order.request_type=="market" { body.set_int("protection_limit",order.price); }
    return body;
}

fn get_order(c: zokor.Ctx[app.App]) -> http.Response {
    let found=exchange.read_order(c.state.exchange_reads,c.local("account_id"),c.param("id"));
    guard let optional=found else let e=err_of(found) {
        if e=="INVALID_READ_REQUEST" { return fail(c,"BAD_REQUEST"); }
        c.state.settings.server.logger.warn("exchange","private order read failed: "+e);
        return fail(c,"UNAVAILABLE");
    }
    guard let order=optional else { return fail(c,"ORDER_NOT_FOUND"); }
    return zokor.no_store(zokor.ok_json(order_json(order).render()));
}

fn my_orders(c: zokor.Ctx[app.App]) -> http.Response {
    let status=c.query("status");
    if len(status)==0 { status="open"; }
    let limit=c.query_int("limit",50);
    if limit<1 || limit>100 || (status!="open" && status!="all") {
        return fail(c,"BAD_REQUEST");
    }
    let market_id=c.query("market_id");
    let after_id="";
    let cursor=c.query("cursor");
    if len(cursor)>0 {
        let decoded=zokor.decode_cursor(cursor);
        guard let values=decoded else { return fail(c,"BAD_REQUEST"); }
        if len(values)!=4 || values[0]!=c.local("account_id") ||
           values[1]!=market_id || values[2]!=status {
            return fail(c,"BAD_REQUEST");
        }
        after_id=values[3];
    }
    let read=exchange.read_orders(c.state.exchange_reads,c.local("account_id"),market_id,status,after_id,limit);
    guard let page=read else let e=err_of(read) {
        if e=="INVALID_READ_REQUEST" { return fail(c,"BAD_REQUEST"); }
        c.state.settings.server.logger.warn("exchange","private orders read failed: "+e);
        return fail(c,"UNAVAILABLE");
    }
    let items=zokor.jarr();
    for order in page.items { items.add(order_json(order)); }
    let body=zokor.jobj().set("items",items).set("next_cursor",zokor.jnull());
    if page.has_more && len(page.items)>0 {
        let last=page.items[len(page.items)-1];
        body.set_str("next_cursor",zokor.encode_cursor([
            c.local("account_id"),market_id,status,last.order_id
        ]));
    }
    return zokor.no_store(zokor.ok_json(body.render()));
}

fn public_market(c: zokor.Ctx[app.App]) -> result[bool,str] {
    return app.public_market_exists(c.state,c.param("id"));
}

fn trades(c: zokor.Ctx[app.App]) -> http.Response {
    let public=public_market(c);
    guard let visible=public else let e=err_of(public) {
        c.state.settings.server.logger.warn("exchange","public market lookup failed: "+e);
        return fail(c,"UNAVAILABLE");
    }
    if !visible { return fail(c,"NOT_FOUND"); }
    let limit=c.query_int("limit",50);
    if limit<1 || limit>100 { return fail(c,"BAD_REQUEST"); }
    let before_seq=0;
    let before_index=0;
    let cursor=c.query("cursor");
    if len(cursor)>0 {
        let decoded=zokor.decode_cursor(cursor);
        guard let values=decoded else { return fail(c,"BAD_REQUEST"); }
        if len(values)!=3 || values[0]!=c.param("id") {
            return fail(c,"BAD_REQUEST");
        }
        before_seq=to_int(values[1]) ?? -1;
        before_index=to_int(values[2]) ?? -1;
        if before_seq<1 || before_index<0 { return fail(c,"BAD_REQUEST"); }
    }
    let read=exchange.read_trades(c.state.exchange_reads,c.param("id"),before_seq,before_index,limit);
    guard let page=read else let e=err_of(read) {
        if e=="INVALID_READ_REQUEST" { return fail(c,"BAD_REQUEST"); }
        c.state.settings.server.logger.warn("exchange","public trades read failed: "+e);
        return fail(c,"UNAVAILABLE");
    }
    let items=zokor.jarr();
    for trade in page.items {
        items.add(zokor.jobj().set_int("execution_seq",trade.execution_seq)
            .set_int("fill_index",trade.fill_index).set_str("mode",trade.mode).set_int("qty",trade.qty)
            .set_int("yes_price",trade.yes_price).set_str("created_at",trade.created_at));
    }
    let body=zokor.jobj().set("items",items).set("next_cursor",zokor.jnull());
    if page.has_more && len(page.items)>0 {
        let last=page.items[len(page.items)-1];
        body.set_str("next_cursor",zokor.encode_cursor([
            c.param("id"),to_str(last.execution_seq),to_str(last.fill_index)
        ]));
    }
    return zokor.no_store(zokor.ok_json(body.render()));
}

fn history(c: zokor.Ctx[app.App]) -> http.Response {
    let public=public_market(c);
    guard let visible=public else let e=err_of(public) {
        c.state.settings.server.logger.warn("exchange","public market lookup failed: "+e);
        return fail(c,"UNAVAILABLE");
    }
    if !visible { return fail(c,"NOT_FOUND"); }
    let period=c.query("period");
    if len(period)==0 { period="1D"; }
    let range_seconds=0;
    if period=="1H" { range_seconds=3600; }
    else if period=="6H" { range_seconds=21600; }
    else if period=="1D" { range_seconds=86400; }
    else if period=="1W" { range_seconds=604800; }
    else if period=="ALL" { range_seconds=3153600000; }
    else { return fail(c,"BAD_REQUEST"); }
    let bucket_seconds=range_seconds/120;
    if bucket_seconds<60 { bucket_seconds=60; }
    bucket_seconds=(bucket_seconds/60)*60;
    let loaded=exchange.read_history(c.state.exchange_reads,c.param("id"),range_seconds,bucket_seconds);
    guard let candles=loaded else let e=err_of(loaded) {
        if e=="INVALID_READ_REQUEST" { return fail(c,"BAD_REQUEST"); }
        c.state.settings.server.logger.warn("exchange","public history read failed: "+e);
        return fail(c,"UNAVAILABLE");
    }
    let items=zokor.jarr();
    for candle in candles {
        items.add(zokor.jobj().set_str("bucket_at",candle.bucket_at)
            .set_int("open",candle.open).set_int("high",candle.high).set_int("low",candle.low)
            .set_int("close",candle.close).set_int("volume",candle.volume));
    }
    return zokor.no_store(zokor.ok_json(zokor.jobj().set_str("period",period).set("items",items).render()));
}

fn register_errors(r: zokor.Registry) {
    zokor.register(r,"BAD_REQUEST",400,"Check the order request.");
    zokor.register(r,"UNAUTHENTICATED",401,"Sign in to continue.");
    zokor.register(r,"NOT_FOUND",404,"The requested resource was not found.");
    zokor.register(r,"ORDER_NOT_FOUND",404,"The requested order was not found.");
    zokor.register(r,"IDEMPOTENCY_CONFLICT",409,"This idempotency key was already used for a different request.");
    zokor.register(r,"ORDER_NOT_OPEN",409,"This order cannot be cancelled.");
    zokor.register(r,"MARKET_NOT_OPEN",409,"This market is not open for trading.");
    zokor.register(r,"MARKET_SUSPENDED",409,"Trading is temporarily suspended.");
    zokor.register(r,"QUEUE_FULL",503,"This market is temporarily at capacity.");
    zokor.register(r,"TRADING_HALTED",503,"Trading is temporarily paused.");
    zokor.register(r,"SEASON_NOT_ACTIVE",409,"The season is not open for trading.");
    zokor.register(r,"INSUFFICIENT_FUNDS",409,"Your available balance cannot cover this order.");
    zokor.register(r,"INSUFFICIENT_SHARES",409,"Your available shares cannot cover this order.");
    zokor.register(r,"PRICE_OUT_OF_BAND",422,"The price is outside the market band.");
    zokor.register(r,"OFF_TICK",422,"The price is not on the market tick.");
    zokor.register(r,"QTY_TOO_LARGE",422,"The quantity exceeds the market limit.");
    zokor.register(r,"BELOW_MIN_NOTIONAL",422,"The order is below the minimum notional.");
    zokor.register(r,"NO_LIQUIDITY_IN_RANGE",409,"There is no executable liquidity in range.");
    zokor.register(r,"OVERFLOW",422,"The order amount is too large.");
    zokor.register(r,"MARKET_DEGRADED",503,"Market data or runtime is temporarily unavailable.");
    zokor.register(r,"UNAVAILABLE",503,"The service is temporarily unavailable.");
}

fn fail(c: zokor.Ctx[app.App],code: str) -> http.Response {
    let allowed=["BAD_REQUEST","UNAUTHENTICATED","NOT_FOUND","ORDER_NOT_FOUND","IDEMPOTENCY_CONFLICT",
        "ORDER_NOT_OPEN","MARKET_NOT_OPEN","MARKET_SUSPENDED","QUEUE_FULL","PRICE_OUT_OF_BAND","OFF_TICK",
        "QTY_TOO_LARGE","BELOW_MIN_NOTIONAL","NO_LIQUIDITY_IN_RANGE","OVERFLOW","MARKET_DEGRADED","UNAVAILABLE",
        "TRADING_HALTED","SEASON_NOT_ACTIVE","INSUFFICIENT_FUNDS","INSUFFICIENT_SHARES","RATE_LIMITED"];
    for known in allowed {
        if known==code {
            if code=="QUEUE_FULL" { return zokor.respond_fields(c.errors,code,[zokor.field("retry_after","1")],c.request_id); }
            return zokor.respond(c.errors,code,c.request_id);
        }
    }
    c.state.settings.server.logger.error("exchange","unmapped request failure: "+code);
    return zokor.respond(c.errors,"UNAVAILABLE",c.request_id);
}

fn order_rate_limit(c: zokor.Ctx[app.App]) -> opt[http.Response] {
    if app.order_rate_limited(c.state,c.local("account_id")) { return some(fail(c,"RATE_LIMITED")); }
    let empty:opt[http.Response]=none;
    return empty;
}

fn validation_failure(c: zokor.Ctx[app.App],failure: exchange.Failure) -> http.Response {
    return zokor.respond_fields(c.errors,failure.code,[zokor.field(failure.field,failure.detail)],c.request_id);
}

fn place_order(c: zokor.Ctx[app.App]) -> http.Response {
    if let response=order_rate_limit(c) { return response; }
    let raw_result=c.json_body();
    guard let raw=raw_result else { return fail(c,"BAD_REQUEST"); }
    let market_id=c.param("id");
    let intent=exchange.Intent {
        account_id:c.local("account_id"),market_id:market_id,
        request_type:raw.get("type").str_or("limit"),outcome:raw.get("outcome").str_or(""),
        side:raw.get("side").str_or(""),price:none,qty:none,tif:none,spend:none
    };
    if !raw.get("price").is_null() { intent.price=some(raw.get("price").int_or(-1)); }
    if !raw.get("qty").is_null() { intent.qty=some(raw.get("qty").int_or(-1)); }
    if !raw.get("tif").is_null() { intent.tif=some(raw.get("tif").str_or("")); }
    if !raw.get("spend").is_null() { intent.spend=some(raw.get("spend").int_or(-1)); }
    if let shape=exchange.intent_shape(intent) { return validation_failure(c,shape); }
    let key=c.header("idempotency-key");
    if !exchange.valid_uuid(key) {
        return zokor.respond_fields(c.errors,"BAD_REQUEST",[zokor.field("Idempotency-Key","Use a UUID idempotency key.")],c.request_id);
    }
    let intent_hash=exchange.intent_hash(intent);
    let lookup=exchange.lookup_idempotency(c.state.order_admission,intent.account_id,key,intent_hash);
    guard let previous=lookup else let e=err_of(lookup) {
        if e=="IDEMPOTENCY_CONFLICT" { return fail(c,e); }
        c.state.settings.server.logger.warn("exchange","idempotency lookup failed: "+e);
        return fail(c,"UNAVAILABLE");
    }
    if let receipt=previous { return admission_response(c,receipt); }
    let policy_result=app.exchange_policy(c.state,market_id);
    guard let policy=policy_result else let e=err_of(policy_result) {
        c.state.settings.server.logger.warn("exchange","market policy lookup failed: "+e);
        if e=="MARKET_NOT_FOUND" { return fail(c,"NOT_FOUND"); }
        return fail(c,"UNAVAILABLE");
    }
    let view_result=app.runtime_view(c.state,market_id);
    guard let optional_view=view_result else let e=err_of(view_result) {
        c.state.settings.server.logger.error("exchange","local book view unavailable: "+e);
        return fail(c,"MARKET_DEGRADED");
    }
    guard let view=optional_view else { return fail(c,"MARKET_DEGRADED"); }
    let normalized_result=exchange.normalize(intent,policy,view,time.wall()/1000000,c.state.settings.exchange.view_freshness_ms);
    guard let normalized=normalized_result else let e=err_of(normalized_result) { return validation_failure(c,e); }
    let request_result=exchange.prepare_admission(intent,normalized,"user","",app.new_uuid(),app.new_uuid(),key,0);
    guard let request=request_result else let e=err_of(request_result) { return fail(c,e); }
    let admitted=exchange.admit_order(c.state.order_admission,request);
    guard let receipt=admitted else let e=err_of(admitted) {
        let journal_error=exchange.admission_failure(e);
        if journal_error.code=="INSUFFICIENT_FUNDS" || journal_error.code=="INSUFFICIENT_SHARES" {
            return zokor.respond_fields(c.errors,journal_error.code,[
                zokor.field("available",to_str(journal_error.available)),
                zokor.field("needed",to_str(journal_error.needed)),zokor.field("asset",journal_error.asset)
            ],c.request_id);
        }
        if e=="MARKET_NOT_OPEN" || e=="MARKET_SUSPENDED" || e=="IDEMPOTENCY_CONFLICT" ||
           e=="MARKET_DEGRADED" || e=="QUEUE_FULL" || e=="ACCOUNT_DISABLED" ||
           e=="TRADING_HALTED" || e=="SEASON_NOT_ACTIVE" {
            if e=="ACCOUNT_DISABLED" { return fail(c,"UNAUTHENTICATED"); }
            return fail(c,e);
        }
        c.state.settings.server.logger.warn("exchange","order admission failed: "+e);
        return fail(c,"UNAVAILABLE");
    }
    return admission_response(c,receipt);
}

fn book_view(c: zokor.Ctx[app.App]) -> http.Response {
    let public=app.public_market_exists(c.state,c.param("id"));
    guard let is_public=public else let e=err_of(public) {
        c.state.settings.server.logger.warn("exchange","public market lookup failed: "+e);
        return fail(c,"UNAVAILABLE");
    }
    if !is_public { return fail(c,"NOT_FOUND"); }
    let result_view=app.runtime_view(c.state,c.param("id"));
    guard let optional_view=result_view else let e=err_of(result_view) {
        c.state.settings.server.logger.error("exchange","book view decode failed: "+e);
        return fail(c,"UNAVAILABLE");
    }
    guard let view=optional_view else { return fail(c,"MARKET_DEGRADED"); }
    if view.health!="READY" || view.lease_until<=time.wall()/1000000 {
        return fail(c,"MARKET_DEGRADED");
    }
    return zokor.no_store(zokor.ok_json(json.encode(view)));
}
