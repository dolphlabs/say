import "builder";
import "httpc";
import "proc";
import "strings";
import "time";
import "zokor";
import "../../src/treasury/domain" as domain;

gc struct Reply {
    status: int,
    body: zokor.Json
}

fn call(client: httpc.Client, method: str, url: str, token: str, body: str, idem_key: str) -> result[Reply, str] {
    let req = httpc.new_request(method, url);
    req.headers["Authorization"] = "Bearer " + token;
    if len(body) > 0 {
        req.headers["Content-Type"] = "application/json";
        req.body = builder.new_bytes().write_str(body).finish();
    }
    if len(idem_key) > 0 {
        req.headers["Idempotency-Key"] = idem_key;
    }
    let r = client.send(req, until_of(time.mono() + 3000000000));
    guard let resp = r else let e = err_of(r) {
        return err(method + " " + url + ": " + e);
    }
    let text = strings.from_bytes(resp.body, 0, len(resp.body));
    let parsed = zokor.parse(text);
    let j = zokor.jnull();
    if let p = parsed { j = p; }
    return ok(Reply { status: resp.status, body: j });
}

fn opt_int_at(j: zokor.Json) -> opt[int] {
    if j.is_number() { return some(j.int_or(0)); }
    let none_i: opt[int] = none;
    return none_i;
}

gc struct MarketView {
    status: str,
    redemption_units: int,
    min_price: int,
    max_price: int,
    tick: int,
    opening_price: int
}

fn read_market(client: httpc.Client, api: str, token: str, market_id: str) -> result[MarketView, str] {
    let r = call(client, "GET", api + "/v1/markets/" + market_id, token, "", "");
    guard let reply = r else let e = err_of(r) { return err(e); }
    if reply.status != 200 { return err("market " + to_str(reply.status)); }
    let m = reply.body;
    let band = m.get("price_band");
    return ok(MarketView {
        status: m.get("status").str_or(""),
        redemption_units: m.get("redemption_units").int_or(0),
        min_price: band.get("min").int_or(0),
        max_price: band.get("max").int_or(0),
        tick: band.get("tick").int_or(0),
        opening_price: m.get("opening_price").int_or(0)
    });
}

gc struct BookRead {
    fresh: bool,
    last_price: opt[int],
    best_bid: opt[int],
    best_ask: opt[int],
    as_of_ms: int
}

// A degraded or unreachable book is reported as not fresh, which the
// quoting rules turn into PULLED_STALE rather than quoting blind.
fn read_book(client: httpc.Client, api: str, token: str, market_id: str) -> BookRead {
    let none_i: opt[int] = none;
    let stale = BookRead { fresh: false, last_price: none_i, best_bid: none_i, best_ask: none_i, as_of_ms: 0 };
    let r = call(client, "GET", api + "/v1/markets/" + market_id + "/book", token, "", "");
    guard let reply = r else { return stale; }
    if reply.status != 200 { return stale; }
    let b = reply.body;
    let bid = none_i;
    let ask = none_i;
    if b.get("bids").size() > 0 { bid = opt_int_at(b.get("bids").at(0).get("yes_price")); }
    if b.get("asks").size() > 0 { ask = opt_int_at(b.get("asks").at(0).get("yes_price")); }
    return BookRead {
        fresh: true, last_price: opt_int_at(b.get("last_price")), best_bid: bid, best_ask: ask,
        as_of_ms: b.get("as_of").int_or(0)
    };
}

fn read_inventory(client: httpc.Client, api: str, token: str, market_id: str) -> result[domain.Inventory, str] {
    let r = call(client, "GET", api + "/v1/me/positions", token, "", "");
    guard let reply = r else let e = err_of(r) { return err(e); }
    if reply.status != 200 { return err("positions " + to_str(reply.status)); }
    let inv = domain.Inventory { yes_qty: 0, no_qty: 0, cost_yes: 0, cost_no: 0 };
    for item in reply.body.get("items").items_of() {
        if item.get("market").get("id").str_or("") != market_id { continue; }
        let qty = item.get("qty").int_or(0);
        let avg = item.get("avg_price");
        let cost = domain.holding_cost(qty, avg.get("numerator").int_or(0), avg.get("denominator").int_or(0));
        if item.get("outcome").str_or("") == "YES" {
            inv.yes_qty = qty;
            inv.cost_yes = cost;
        } else {
            inv.no_qty = qty;
            inv.cost_no = cost;
        }
    }
    return ok(inv);
}

fn read_cash(client: httpc.Client, api: str, token: str) -> result[int, str] {
    let r = call(client, "GET", api + "/v1/me/balance", token, "", "");
    guard let reply = r else let e = err_of(r) { return err(e); }
    if reply.status != 200 { return err("balance " + to_str(reply.status)); }
    return ok(reply.body.get("available").int_or(0));
}

// The server's list is the truth: it reflects fills, cancels and orders
// left from a previous run, so nothing is tracked only in memory.
fn read_live_orders(client: httpc.Client, api: str, token: str, market_id: str) -> result[[domain.LiveOrder], str] {
    let r = call(client, "GET", api + "/v1/me/orders?status=open&limit=100&market_id=" + market_id, token, "", "");
    guard let reply = r else let e = err_of(r) { return err(e); }
    if reply.status != 200 { return err("orders " + to_str(reply.status)); }
    let out: [domain.LiveOrder] = [];
    for o in reply.body.get("items").items_of() {
        push(out, domain.LiveOrder {
            id: o.get("id").str_or(""),
            outcome: o.get("outcome").str_or(""),
            side: o.get("side").str_or(""),
            price: o.get("price").int_or(0),
            qty: o.get("remaining").int_or(0)
        });
    }
    return ok(out);
}

fn params_from(j: zokor.Json, fallback: domain.BotParams) -> domain.BotParams {
    return domain.BotParams {
        base_spread_ticks: j.get("base_spread_ticks").int_or(fallback.base_spread_ticks),
        vol_ticks: j.get("vol_ticks").int_or(fallback.vol_ticks),
        skew_ticks: j.get("skew_ticks").int_or(fallback.skew_ticks),
        levels: j.get("levels").int_or(fallback.levels),
        base_size: j.get("base_size").int_or(fallback.base_size),
        max_net_shares: j.get("max_net_shares").int_or(fallback.max_net_shares),
        max_loss: j.get("max_loss").int_or(fallback.max_loss),
        season_max_drawdown: j.get("season_max_drawdown").int_or(fallback.season_max_drawdown),
        min_requote_ms: j.get("min_requote_ms").int_or(fallback.min_requote_ms),
        max_ops_per_sec: j.get("max_ops_per_sec").int_or(fallback.max_ops_per_sec),
        max_open_orders: j.get("max_open_orders").int_or(fallback.max_open_orders)
    };
}

fn pull_all(client: httpc.Client, api: str, token: str, market_id: str, why: str) {
    let r = call(client, "DELETE", api + "/v1/markets/" + market_id + "/orders", token, "", "");
    if let reply = r {
        if reply.status >= 300 {
            println("[say-bots] pulling quotes (" + why + ") answered " + to_str(reply.status));
        }
    } else let e = err_of(r) {
        println("[say-bots] pulling quotes (" + why + ") failed: " + e);
    }
}

let args = proc.args();
let api_url = "http://127.0.0.1:8080";
let api_key = proc.getenv("SAY_BOT_API_KEY") ?? "";
let market_id = "";
let once_mode = false;

for i in 1..len(args) {
    if args[i] == "--api-url" && i + 1 < len(args) {
        api_url = args[i + 1];
    } else if args[i] == "--api-key" && i + 1 < len(args) {
        api_key = args[i + 1];
    } else if args[i] == "--market-id" && i + 1 < len(args) {
        market_id = args[i + 1];
    } else if args[i] == "--once" {
        once_mode = true;
    }
}

let ready = strings.has_prefix(api_key, "say_bot_") && len(market_id) == 36;
if !ready {
    println("usage: say-bots --market-id <uuid> [--api-url URL] [--api-key say_bot_...] [--once]");
    println("the key may also come from SAY_BOT_API_KEY");
}

let client = httpc.new_client();
let params = domain.default_params();
let allocation = 0;
let trading_halted = false;
let server_status = "QUOTING";
let reported_status = "QUOTING";
let reported_reason = "starting";
let inventory = domain.Inventory { yes_qty: 0, no_qty: 0, cost_yes: 0, cost_no: 0 };
let run_tag = to_str((time.wall() / 1000000) as int);
let placements = 0;

let heartbeat_ok_at = 0;
let last_heartbeat_at = 0;
let last_quote_at = 0;
let loops = 0;

if ready { println("[say-bots] starting on market " + market_id); }

while ready && !proc.shutdown_requested() {
    if loops > 0 {
        if once_mode {
            println("[say-bots] completed single-shot run");
            break;
        }
        time.sleep(250000000);
    }
    loops += 1;
    let now_ms = (time.mono() / 1000000) as int;
    let wall_ms = (time.wall() / 1000000) as int;

    if last_heartbeat_at == 0 || now_ms - last_heartbeat_at >= 2000 {
        last_heartbeat_at = now_ms;
        let hb_body = zokor.jobj().set_str("market_id", market_id).set_str("status", reported_status)
            .set_str("status_reason", reported_reason).set_int("holding_yes", inventory.yes_qty)
            .set_int("holding_no", inventory.no_qty).set_int("used", inventory.cost_yes + inventory.cost_no)
            .set_int("spread_ticks", params.base_spread_ticks).render();
        let hb = call(client, "POST", api_url + "/v1/internal/bots/heartbeat", api_key, hb_body, "");
        if let reply = hb {
            if reply.status == 200 {
                let d = reply.body;
                let st = d.get("status").str_or("PAUSED_MANUAL");
                if st != server_status { println("[say-bots] server status " + st); }
                server_status = st;
                allocation = d.get("allocated").int_or(0);
                trading_halted = d.get("trading_halted").bool_or(true);
                params = params_from(d.get("params"), params);
                heartbeat_ok_at = now_ms;
            } else {
                println("[say-bots] heartbeat answered " + to_str(reply.status));
            }
        } else let e = err_of(hb) {
            println("[say-bots] heartbeat failed: " + e);
        }
    }

    let requote_ms = params.min_requote_ms;
    if requote_ms < 1000 { requote_ms = 1000; }
    if last_quote_at == 0 || now_ms - last_quote_at >= requote_ms {
        last_quote_at = now_ms;
        let mr = read_market(client, api_url, api_key, market_id);
        let ir = read_inventory(client, api_url, api_key, market_id);
        let cr = read_cash(client, api_url, api_key);
        let lr = read_live_orders(client, api_url, api_key, market_id);
        let book = read_book(client, api_url, api_key, market_id);

        // Without a recent answer from the server, the bot cannot know about
        // a pause, so it stops quoting until it hears again.
        let server_known = heartbeat_ok_at > 0 && now_ms - heartbeat_ok_at <= 10000;
        guard let market = mr else let e = err_of(mr) {
            println("[say-bots] " + e);
            pull_all(client, api_url, api_key, market_id, "market unreadable");
            continue;
        }
        guard let inv = ir else let e = err_of(ir) {
            println("[say-bots] " + e);
            pull_all(client, api_url, api_key, market_id, "positions unreadable");
            continue;
        }
        guard let cash = cr else let e = err_of(cr) {
            println("[say-bots] " + e);
            pull_all(client, api_url, api_key, market_id, "balance unreadable");
            continue;
        }
        guard let live = lr else let e = err_of(lr) {
            println("[say-bots] " + e);
            pull_all(client, api_url, api_key, market_id, "orders unreadable");
            continue;
        }
        inventory = inv;

        let ref_age = 1000000000;
        if book.fresh && book.as_of_ms > 0 { ref_age = wall_ms - book.as_of_ms; }
        let market_status = market.status;
        if !server_known { market_status = "UNKNOWN"; }
        let no_fills: [domain.FillRecord] = [];
        let q = domain.quote(domain.QuoteInputs {
            V: market.redemption_units,
            min_price: market.min_price,
            max_price: market.max_price,
            tick: market.tick,
            ref_price: domain.reference_price(book.last_price, book.best_bid, book.best_ask, market.opening_price),
            ref_age_ms: ref_age,
            book_top: domain.BookTop { yes_bid: book.best_bid, yes_ask: book.best_ask },
            inventory: inventory,
            cash_free: cash,
            allocation: allocation,
            budget_used: inventory.cost_yes + inventory.cost_no,
            params: params,
            recent_fills: no_fills,
            market_status: market_status,
            trading_halted: trading_halted,
            global_pause: server_status == "PAUSED_ALL",
            manual_pause: server_status == "PAUSED_MANUAL",
            season_drawdown: 0,
            now_ms: wall_ms
        });

        if domain.bot_reportable_status(q.status) {
            reported_status = q.status;
            reported_reason = q.status_reason;
        }

        if q.status != "QUOTING" {
            if len(live) > 0 {
                pull_all(client, api_url, api_key, market_id, q.status);
                println("[say-bots] " + q.status + " (" + q.status_reason + "): pulled " + to_str(len(live)) + " order(s)");
            }
        } else {
            let diff = domain.compute_order_diff(live, q.orders);
            for c_ord in diff.to_cancel {
                let cr2 = call(client, "DELETE", api_url + "/v1/orders/" + c_ord.id, api_key, "", "");
                if let reply = cr2 {
                    if reply.status >= 300 { println("[say-bots] cancel " + c_ord.id + " answered " + to_str(reply.status)); }
                } else let e = err_of(cr2) {
                    println("[say-bots] cancel " + c_ord.id + " failed: " + e);
                }
            }
            for p_ord in diff.to_place {
                placements += 1;
                // Unique per placement, so a later order at the same price is
                // a new order rather than a replay of a filled one.
                let idem = domain.make_idempotency_key(market_id + "@" + run_tag, market_id, placements, p_ord.price, p_ord.qty);
                let body = zokor.jobj().set_str("outcome", p_ord.outcome).set_str("side", p_ord.side)
                    .set_int("price", p_ord.price).set_int("qty", p_ord.qty).render();
                let pr = call(client, "POST", api_url + "/v1/markets/" + market_id + "/orders", api_key, body, idem);
                if let reply = pr {
                    if reply.status >= 300 {
                        println("[say-bots] place " + p_ord.side + " " + p_ord.outcome + " @" + to_str(p_ord.price) +
                            " answered " + to_str(reply.status) + " " + reply.body.get("error").get("code").str_or(""));
                    }
                } else let e = err_of(pr) {
                    println("[say-bots] place failed: " + e);
                }
            }
        }
    }

}

// A stopped bot must not leave quotes resting that nobody manages.
if ready && !once_mode {
    pull_all(client, api_url, api_key, market_id, "shutting down");
}
