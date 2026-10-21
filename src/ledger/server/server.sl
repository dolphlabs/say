// zokor:public
import "http";
import "timez";
import "zokor";
import "../../platform/app" as app;
import "../../platform/auth" as auth;
import "../service" as ledger;

gc struct ClearHaltDto {
    reason: str
}

// /v1/seasons/* is public on purpose: the signup screens show the season
// clock before login. /v1/me/* needs a session; /v1/admin/* an operator.
pub fn mount(r: zokor.Router[app.App]) -> int {
    register_errors(r.errors);
    let seasons = r.group("/v1/seasons");
    seasons.get("/current", current);
    seasons.get("/:ordinal", by_ordinal);
    let me = r.group("/v1/me");
    me.before(auth.require_session);
    me.get("/balance", balance);
    me.get("/ledger", ledger_page);
    me.get("/summary", summary);
    let admin = r.group("/v1/admin");
    admin.before(auth.require_session);
    admin.before(auth.require_admin);
    admin.get("/reconciliation/latest", recon_latest);
    admin.post("/reconciliation/run", recon_run);
    let sup = r.group("/v1/admin");
    sup.before(auth.require_session);
    sup.before(auth.require_super_admin);
    sup.post("/trading-halt/clear", clear_halt);
    return 0;
}

fn season_json(v: ledger.SeasonView) -> zokor.Json {
    return zokor.jobj()
        .set_str("id", v.season.id)
        .set_int("ordinal", v.season.ordinal)
        .set_str("status", v.season.status)
        .set_str("starts_at", v.season.starts_at.rfc3339())
        .set_str("ends_at", v.season.ends_at.rfc3339())
        .set_int("day", v.day)
        .set_int("days_total", 14)
        .set_str("timezone", "Africa/Lagos")
        .set_str("server_time", v.server_time.rfc3339_milli());
}

fn current(c: zokor.Ctx[app.App]) -> http.Response {
    let r = ledger.current_season(c.state.ledger);
    guard let found = r else let f = err_of(r) {
        return failure(c, f);
    }
    guard let v = found else {
        return zokor.respond(c.errors, "SEASON_NOT_FOUND", c.request_id);
    }
    return zokor.no_store(zokor.ok_json(season_json(v).render()));
}

fn by_ordinal(c: zokor.Ctx[app.App]) -> http.Response {
    let r = ledger.season(c.state.ledger, c.param_int("ordinal", 0));
    guard let v = r else let f = err_of(r) {
        return failure(c, f);
    }
    let body = season_json(v).set_bool("finalized", v.finalized);
    if len(v.provisional_reason) > 0 {
        body.set_str("provisional_reason", v.provisional_reason);
    }
    return zokor.no_store(zokor.ok_json(body.render()));
}

fn balance_json(b: ledger.Balance) -> zokor.Json {
    let body = zokor.jobj()
        .set("season", zokor.jobj().set_int("ordinal", b.season_ordinal).set_str("status", b.season_status))
        .set_int("available", b.available)
        .set_int("held", b.held);
    if let g = b.starting_grant {
        body.set_int("starting_grant", g);
    } else {
        body.set("starting_grant", zokor.jnull());
    }
    return body;
}

fn balance(c: zokor.Ctx[app.App]) -> http.Response {
    let sel = ledger.season_selector(c.query("season"));
    guard let ordinal = sel else let f = err_of(sel) {
        return failure(c, f);
    }
    let r = ledger.balance(c.state.ledger, c.local("account_id"), ordinal);
    guard let b = r else let f = err_of(r) {
        return failure(c, f);
    }
    return zokor.no_store(zokor.ok_json(balance_json(b).render()));
}

fn opt_int(v: int) -> zokor.Json {
    if v < 0 {
        return zokor.jnull();
    }
    return zokor.jint(v);
}

fn meta_json(text: str) -> zokor.Json {
    let r = zokor.parse(text);
    if let j = r {
        return j;
    }
    return zokor.jobj();
}

fn item_json(it: ledger.LedgerItem) -> zokor.Json {
    let shares = zokor.jarr();
    for m in it.shares {
        shares.add(zokor.jobj().set_str("asset", m.asset).set_int("delta", m.free_delta).set_int("held_delta", m.held_delta));
    }
    return zokor.jobj()
        .set_str("id", it.id)
        .set_str("at", it.at.rfc3339_milli())
        .set_str("kind", it.kind)
        .set_int("delta", it.delta)
        .set_int("held_delta", it.held_delta)
        .set("available_after", opt_int(it.available_after))
        .set("held_after", opt_int(it.held_after))
        .set("ref", zokor.jobj().set_str("type", it.ref_type).set_str("id", it.ref_id))
        .set("shares", shares)
        .set("meta", meta_json(it.meta));
}

fn ledger_page(c: zokor.Ctx[app.App]) -> http.Response {
    let sel = ledger.season_selector(c.query("season"));
    guard let ordinal = sel else let f = err_of(sel) {
        return failure(c, f);
    }
    let r = ledger.ledger_page(c.state.ledger, c.local("account_id"), ordinal, c.query("cursor"), c.query_int("limit", 50));
    guard let page = r else let f = err_of(r) {
        return failure(c, f);
    }
    let items = zokor.jarr();
    for it in page.items {
        items.add(item_json(it));
    }
    let body = zokor.jobj().set("items", items);
    if len(page.next_cursor) > 0 {
        body.set_str("next_cursor", page.next_cursor);
    } else {
        body.set("next_cursor", zokor.jnull());
    }
    return zokor.no_store(zokor.ok_json(body.render()));
}

fn summary(c: zokor.Ctx[app.App]) -> http.Response {
    let r = ledger.summary(c.state.ledger, c.local("account_id"));
    guard let s = r else let f = err_of(r) {
        return failure(c, f);
    }
    let body = zokor.jobj();
    if let v = s.season {
        body.set("season", season_json(v));
    } else {
        body.set("season", zokor.jnull());
    }
    if let b = s.balance {
        body.set("balance", balance_json(b));
    } else {
        body.set("balance", zokor.jnull());
    }
    return zokor.no_store(zokor.ok_json(body.render()));
}

fn recon_json(run: ledger.ReconRun) -> zokor.Json {
    let checks = zokor.jarr();
    for ck in run.checks {
        checks.add(zokor.jobj().set_str("name", ck.name).set_str("status", ck.status).set_int("count", ck.count)
            .set_str("detail", ck.detail));
    }
    let body = zokor.jobj().set_str("id", run.id).set_str("scope", run.scope).set_str("status", run.status)
        .set("checks", checks);
    if let good = run.ok {
        body.set_bool("ok", good);
    } else {
        body.set("ok", zokor.jnull());
    }
    if let at = run.finished_at {
        body.set_str("finished_at", at.rfc3339());
    }
    return body;
}

fn recon_latest(c: zokor.Ctx[app.App]) -> http.Response {
    let r = ledger.latest_recon(c.state.ledger);
    guard let found = r else let f = err_of(r) {
        return failure(c, f);
    }
    let hr = ledger.halt_state(c.state.ledger);
    guard let halt = hr else let f = err_of(hr) {
        return failure(c, f);
    }
    let body = zokor.jobj().set("trading_halted", zokor.jobj().set_bool("halted", halt.halted)
        .set_str("reason", halt.reason).set_str("changed_at", halt.changed_at.rfc3339()));
    if let run = found {
        body.set("run", recon_json(run));
    } else {
        body.set("run", zokor.jnull());
    }
    return zokor.no_store(zokor.ok_json(body.render()));
}

fn recon_run(c: zokor.Ctx[app.App]) -> http.Response {
    let r = ledger.request_recon(c.state.ledger, c.local("account_id"));
    guard let id = r else let f = err_of(r) {
        return failure(c, f);
    }
    return zokor.accepted(zokor.jobj().set_str("run_id", id).render());
}

fn clear_halt(c: zokor.Ctx[app.App]) -> http.Response {
    let dr: result[ClearHaltDto, http.Response] = zokor.dto(c);
    guard let body = dr else let bad = err_of(dr) {
        return bad;
    }
    let r = ledger.clear_halt(c.state.ledger, c.local("account_id"), body.reason);
    guard let _ok = r else let f = err_of(r) {
        return failure(c, f);
    }
    return zokor.no_content();
}
