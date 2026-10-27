import "timez";
import "zokor";
import "../domain" as domain;
import "../service" as markets;

gc struct RulesDto { yes_if: opt[str], no_if: opt[str], edge_cases: opt[str] }

gc struct Input {
    version: opt[int], reason: opt[str], rules: opt[RulesDto],
    question: opt[str],
    category_id: opt[str],
    season_id: opt[str],
    resolution_source_id: opt[str],
    open_at: opt[str],
    close_at: opt[str],
    resolve_by: opt[str],
    redemption_units: opt[int],
    min_price: opt[int],
    max_price: opt[int],
    tick: opt[int],
    max_order_qty: opt[int],
    fee_units: opt[int],
    min_order_notional: opt[int],
    liquidity_request: opt[int],
    featured_rank: opt[int],
    opening_price: opt[int],
}

gc struct SourceDto { name: str, url_pattern: str, kind: str }

fn patch_of(input: Input,raw: zokor.Json) -> result[domain.Patch,str] {
    let p=domain.empty_patch();
    p.question=input.question;
    if raw.has_key("question") && raw.get("question").is_null() { p.question=some(""); }
    p.category_id=input.category_id;
    if raw.has_key("category_id") && raw.get("category_id").is_null() { p.category_id=some(""); }
    p.season_id=input.season_id;
    if raw.has_key("season_id") && raw.get("season_id").is_null() { p.season_id=some(""); }
    p.resolution_source_id=input.resolution_source_id;
    if raw.has_key("resolution_source_id") && raw.get("resolution_source_id").is_null() { p.resolution_source_id=some(""); }
    if let text=input.open_at {
        let parsed=timez.parse_rfc3339(text);
        guard let at=parsed else { return err("open_at"); }
        p.open_at=some(at.unix_milli());
    }
    if raw.has_key("open_at") && raw.get("open_at").is_null() { p.open_at=some(0); }
    if let text=input.close_at {
        let parsed=timez.parse_rfc3339(text);
        guard let at=parsed else { return err("close_at"); }
        p.close_at=some(at.unix_milli());
    }
    if raw.has_key("close_at") && raw.get("close_at").is_null() { p.close_at=some(0); }
    if let text=input.resolve_by {
        let parsed=timez.parse_rfc3339(text);
        guard let at=parsed else { return err("resolve_by"); }
        p.resolve_by=some(at.unix_milli());
    }
    if raw.has_key("resolve_by") && raw.get("resolve_by").is_null() { p.resolve_by=some(0); }
    p.redemption_units=input.redemption_units;
    if raw.has_key("redemption_units") && raw.get("redemption_units").is_null() { p.redemption_units=some(0); }
    p.min_price=input.min_price;
    if raw.has_key("min_price") && raw.get("min_price").is_null() { p.min_price=some(0); }
    p.max_price=input.max_price;
    if raw.has_key("max_price") && raw.get("max_price").is_null() { p.max_price=some(0); }
    p.tick=input.tick;
    if raw.has_key("tick") && raw.get("tick").is_null() { p.tick=some(0); }
    p.max_order_qty=input.max_order_qty;
    if raw.has_key("max_order_qty") && raw.get("max_order_qty").is_null() { p.max_order_qty=some(0); }
    p.fee_units=input.fee_units;
    if raw.has_key("fee_units") && raw.get("fee_units").is_null() { p.fee_units=some(0); }
    p.min_order_notional=input.min_order_notional;
    if raw.has_key("min_order_notional") && raw.get("min_order_notional").is_null() { p.min_order_notional=some(0); }
    p.liquidity_request=input.liquidity_request;
    if raw.has_key("liquidity_request") && raw.get("liquidity_request").is_null() { p.liquidity_request=some(0); }
    p.featured_rank=input.featured_rank;
    if raw.has_key("featured_rank") && raw.get("featured_rank").is_null() { p.featured_rank=some(0); }
    p.opening_price=input.opening_price;
    if raw.has_key("opening_price") && raw.get("opening_price").is_null() { p.opening_price=some(0); }
    if let rules=input.rules { p.yes_if=rules.yes_if; p.no_if=rules.no_if; p.edge_cases=rules.edge_cases; }
    if raw.get("rules").has_key("yes_if") && raw.get("rules").get("yes_if").is_null() { p.yes_if=some(""); }
    if raw.get("rules").has_key("no_if") && raw.get("rules").get("no_if").is_null() { p.no_if=some(""); }
    if raw.get("rules").has_key("edge_cases") && raw.get("rules").get("edge_cases").is_null() { p.edge_cases=some(""); }
    if raw.has_key("rules") && raw.get("rules").is_null() { p.yes_if=some(""); p.no_if=some(""); p.edge_cases=some(""); }
    return ok(p);
}

fn at_json(ms: int) -> zokor.Json {
    if ms==0 { return zokor.jnull(); }
    return zokor.jstr(timez.unix(ms/1000).add((ms%1000)*1000000).rfc3339_milli());
}

fn market_json(m: domain.Market) -> zokor.Json {
    let j=zokor.jobj().set_str("id",m.id).set_str("slug",m.slug).set_str("question",m.question)
        .set_str("category_id",m.category_id).set_str("season_id",m.season_id).set_str("resolution_source_id",m.resolution_source_id)
        .set("rules",zokor.jobj().set_str("yes_if",m.yes_if).set_str("no_if",m.no_if).set_str("edge_cases",m.edge_cases))
        .set("open_at",at_json(m.open_at)).set("close_at",at_json(m.close_at)).set("resolve_by",at_json(m.resolve_by))
        .set_int("redemption_units",m.redemption_units).set_int("min_price",m.min_price).set_int("max_price",m.max_price)
        .set_int("tick",m.tick).set_int("max_order_qty",m.max_order_qty).set_int("fee_units",m.fee_units)
        .set_int("min_order_notional",m.min_order_notional).set_int("liquidity_request",m.liquidity_request)
        .set_int("featured_rank",m.featured_rank).set_int("opening_price",m.opening_price)
        .set_str("status",m.status).set_int("version",m.version).set_int("terms_version",m.terms_version)
        .set_str("terms_hash",m.terms_hash).set_str("created_by",m.created_by).set_str("submitted_by",m.submitted_by)
        .set_str("approved_by",m.approved_by).set("created_at",at_json(m.created_at)).set("opened_at",at_json(m.opened_at))
        .set("closed_at",at_json(m.closed_at)).set("suspended_at",at_json(m.suspended_at))
        .set_str("suspend_reason",m.suspend_reason).set_str("status_note",m.status_note);
    for field in ["question","category_id","season_id","resolution_source_id","submitted_by","approved_by","terms_hash"] {
        if j.get(field).str_or("")=="" { j.set(field,zokor.jnull()); }
    }
    for field in ["redemption_units","min_price","max_price","liquidity_request","featured_rank","opening_price"] {
        if j.get(field).int_or(0)==0 { j.set(field,zokor.jnull()); }
    }
    return j;
}
