import "http";
import "zokor";
import "../../platform/app" as app;
import "../../platform/auth" as auth;
import "../domain" as domain;
import "../service" as portfolio;

pub fn mount(r: zokor.Router[app.App]) -> int {
    zokor.register(r.errors, "SEASON_NOT_FOUND", 404, "Season not found.");
    zokor.register(r.errors, "BAD_REQUEST", 400, "Check your request parameters.");
    zokor.register(r.errors, "UNAVAILABLE", 503, "Service temporarily unavailable.");

    let me = r.group("/v1/me");
    me.before(auth.require_session);
    me.get("/portfolio/summary", get_portfolio_summary);
    me.get("/positions", get_positions_handler);
    me.get("/results", get_results_handler);
    return 0;
}

fn parse_season_param(s: str) -> result[int, str] {
    if len(s) == 0 || s == "current" {
        return ok(0);
    }
    let parsed = to_int(s);
    guard let ord = parsed else {
        return err("BAD_REQUEST");
    }
    if ord < 1 {
        return err("BAD_REQUEST");
    }
    return ok(ord);
}

fn rational_json(r: domain.Rational) -> zokor.Json {
    return zokor.jobj().set_int("numerator", r.num).set_int("denominator", r.den);
}

fn summary_json(v: domain.SummaryView) -> zokor.Json {
    let season_obj = zokor.jobj()
        .set_int("ordinal", v.season.ordinal)
        .set_str("status", v.season.status)
        .set_str("ends_at", v.season.ends_at);

    let held_shares_arr = zokor.jarr();
    for hs in v.held_shares {
        held_shares_arr.add(zokor.jobj()
            .set_str("market_id", hs.market_id)
            .set_str("outcome", hs.outcome)
            .set_int("qty", hs.qty));
    }

    let body = zokor.jobj()
        .set("season", season_obj)
        .set_int("available", v.available)
        .set_int("held", v.held)
        .set("held_shares", held_shares_arr)
        .set_int("positions_value", v.positions_value)
        .set_int("total", v.total);

    if v.has_season_pnl {
        body.set_int("season_pnl", v.season_pnl);
    } else {
        body.set("season_pnl", zokor.jnull());
    }

    if v.has_starting_grant {
        body.set_int("starting_grant", v.starting_grant);
    } else {
        body.set("starting_grant", zokor.jnull());
    }

    if v.has_rank {
        body.set("rank", zokor.jobj().set_int("position", v.rank_position).set_int("of", v.rank_of));
    } else {
        body.set("rank", zokor.jnull());
    }

    return body;
}

fn position_json(p: domain.PositionView) -> zokor.Json {
    let mkt = zokor.jobj()
        .set_str("id", p.market.id)
        .set_str("slug", p.market.slug)
        .set_str("question", p.market.question)
        .set_str("category", p.market.category)
        .set_str("status", p.market.status)
        .set_str("closes_at", p.market.closes_at)
        .set_int("redemption_units", p.market.redemption_units);

    let item = zokor.jobj()
        .set("market", mkt)
        .set_str("outcome", p.outcome)
        .set_int("qty", p.qty)
        .set_int("qty_free", p.qty_free)
        .set_int("qty_in_orders", p.qty_in_orders)
        .set("avg_price", rational_json(p.avg_price))
        .set("mark", rational_json(p.mark))
        .set_str("mark_source", p.mark_source)
        .set_int("value", p.value)
        .set_int("unrealized_pnl", p.unrealized_pnl);

    if p.has_pnl_pct {
        item.set_int("pnl_pct", p.pnl_pct);
    } else {
        item.set("pnl_pct", zokor.jnull());
    }

    if p.has_proposed_outcome {
        item.set_str("proposed_outcome", p.proposed_outcome);
    }

    return item;
}

fn result_json(r: domain.ResultView) -> zokor.Json {
    let mkt = zokor.jobj()
        .set_str("id", r.market.id)
        .set_str("slug", r.market.slug)
        .set_str("question", r.market.question)
        .set_str("category", r.market.category)
        .set_str("status", r.market.status)
        .set_str("closes_at", r.market.closes_at)
        .set_int("redemption_units", r.market.redemption_units);

    return zokor.jobj()
        .set("market", mkt)
        .set_str("outcome", r.outcome)
        .set_int("qty", r.qty)
        .set("avg_price", rational_json(r.avg_price))
        .set_str("result", r.result_outcome)
        .set_int("paid_out", r.paid_out)
        .set_int("pnl", r.pnl)
        .set_str("settled_at", r.settled_at);
}

fn get_portfolio_summary(c: zokor.Ctx[app.App]) -> http.Response {
    let account_id = c.local("account_id");
    let ord_res = parse_season_param(c.query("season"));
    guard let ordinal = ord_res else {
        return zokor.respond(c.errors, "BAD_REQUEST", c.request_id);
    }

    let stats_map = app.get_portfolio_market_stats(c.state);
    let r = portfolio.get_summary(c.state.portfolio, account_id, ordinal, stats_map);
    guard let summary = r else let e = err_of(r) {
        if e == "SEASON_NOT_FOUND" {
            return zokor.respond(c.errors, "SEASON_NOT_FOUND", c.request_id);
        }
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    return zokor.no_store(zokor.ok_json(summary_json(summary).render()));
}

fn get_positions_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let account_id = c.local("account_id");
    let ord_res = parse_season_param(c.query("season"));
    guard let ordinal = ord_res else {
        return zokor.respond(c.errors, "BAD_REQUEST", c.request_id);
    }

    let stats_map = app.get_portfolio_market_stats(c.state);
    let r = portfolio.get_positions(c.state.portfolio, account_id, ordinal, stats_map);
    guard let positions = r else let e = err_of(r) {
        if e == "SEASON_NOT_FOUND" {
            return zokor.respond(c.errors, "SEASON_NOT_FOUND", c.request_id);
        }
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    let arr = zokor.jarr();
    for p in positions {
        arr.add(position_json(p));
    }
    return zokor.no_store(zokor.ok_json(zokor.jobj().set("items", arr).render()));
}

fn get_results_handler(c: zokor.Ctx[app.App]) -> http.Response {
    let account_id = c.local("account_id");
    let ord_res = parse_season_param(c.query("season"));
    guard let ordinal = ord_res else {
        return zokor.respond(c.errors, "BAD_REQUEST", c.request_id);
    }

    let r = portfolio.get_results(c.state.portfolio, account_id, ordinal);
    guard let results = r else let e = err_of(r) {
        if e == "SEASON_NOT_FOUND" {
            return zokor.respond(c.errors, "SEASON_NOT_FOUND", c.request_id);
        }
        return zokor.respond(c.errors, "UNAVAILABLE", c.request_id);
    }

    let arr = zokor.jarr();
    for res in results {
        arr.add(result_json(res));
    }
    return zokor.no_store(zokor.ok_json(zokor.jobj().set("items", arr).render()));
}
