import "builder";
import "httpc";
import "json";
import "proc";
import "strings";
import "time";
import "zokor";
import "../../src/treasury/domain" as domain;

fn send_post(client: httpc.Client, url: str, token: str, body: str, idem_key: str) -> result[int, str] {
    let req = httpc.new_request("POST", url);
    req.headers["Authorization"] = "Bearer " + token;
    req.headers["Content-Type"] = "application/json";
    if len(idem_key) > 0 {
        req.headers["Idempotency-Key"] = idem_key;
    }
    req.body = builder.new_bytes().write_str(body).finish();
    let r = client.send(req, until_of(time.mono() + 3000000000));
    guard let resp = r else let e = err_of(r) {
        return err(e);
    }
    return ok(resp.status);
}

fn send_delete(client: httpc.Client, url: str, token: str) -> result[int, str] {
    let req = httpc.new_request("DELETE", url);
    req.headers["Authorization"] = "Bearer " + token;
    let r = client.send(req, until_of(time.mono() + 3000000000));
    guard let resp = r else let e = err_of(r) {
        return err(e);
    }
    return ok(resp.status);
}

let args = proc.args();
let api_url = "http://127.0.0.1:8080";
let api_key = "say_bot_sample_secret_key_12345678";
let bot_id = "00000000-0000-4000-a000-000000000100";
let market_id = "00000000-0000-4000-a000-000000000200";
let once_mode = false;

for i in 1..len(args) {
    if args[i] == "--api-url" && i + 1 < len(args) {
        api_url = args[i + 1];
    } else if args[i] == "--api-key" && i + 1 < len(args) {
        api_key = args[i + 1];
    } else if args[i] == "--bot-id" && i + 1 < len(args) {
        bot_id = args[i + 1];
    } else if args[i] == "--market-id" && i + 1 < len(args) {
        market_id = args[i + 1];
    } else if args[i] == "--once" {
        once_mode = true;
    }
}

let client = httpc.new_client();
let params = domain.default_params();
let inventory = domain.Inventory { yes_qty: 0, no_qty: 0, cost_yes: 0, cost_no: 0 };
let live_orders: [domain.LiveOrder] = [];

let last_heartbeat_at = time.mono();
let last_quote_at = 0;
let loops = 0;

println("[say-bots] Starting bot runner for bot " + bot_id + " on market " + market_id);

while true {
    let now_mono = time.mono();
    let now_ms = (now_mono / 1000000) as int;

    // 1. Quoting tick (throttled by params.min_requote_ms)
    if (now_ms - last_quote_at) >= params.min_requote_ms {
        let q_inputs = domain.QuoteInputs {
            V: 100,
            min_price: 1,
            max_price: 99,
            tick: 1,
            ref_price: 50,
            ref_age_ms: 100,
            book_top: domain.BookTop { yes_bid: none, yes_ask: none },
            inventory: inventory,
            cash_free: 50000,
            allocation: 50000,
            budget_used: inventory.cost_yes + inventory.cost_no,
            params: params,
            recent_fills: [],
            market_status: "OPEN",
            trading_halted: false,
            global_pause: false,
            manual_pause: false,
            season_drawdown: 0,
            now_ms: now_ms
        };

        let q_res = domain.quote(q_inputs);
        last_quote_at = now_ms;

        if q_res.status != "QUOTING" {
            // Hard stop fired -> pull all orders immediately
            if len(live_orders) > 0 {
                let del_url = api_url + "/v1/markets/" + market_id + "/orders?mine=true";
                let _ = send_delete(client, del_url, api_key);
                live_orders = [];
                println("[say-bots] Hard stop " + q_res.status + ": pulled all orders");
            }
        } else {
            let diff = domain.compute_order_diff(live_orders, q_res.orders);

            // Cancel replaced or removed orders
            for c_ord in diff.to_cancel {
                let del_url = api_url + "/v1/markets/" + market_id + "/orders/" + c_ord.id;
                let _ = send_delete(client, del_url, api_key);
            }

            // Place new desired orders
            let updated_live: [domain.LiveOrder] = [];
            for k in diff.to_keep {
                push(updated_live, k);
            }

            let lvl = 0;
            for p_ord in diff.to_place {
                let idem = domain.make_idempotency_key(bot_id, market_id, lvl, p_ord.price, p_ord.qty);
                let body = "{\"outcome\":\"" + p_ord.outcome + "\",\"side\":\"" + p_ord.side + "\",\"price\":" + to_str(p_ord.price) + ",\"qty\":" + to_str(p_ord.qty) + "}";
                let place_url = api_url + "/v1/markets/" + market_id + "/orders";
                let st = send_post(client, place_url, api_key, body, idem);
                if let _code = st {
                    push(updated_live, domain.LiveOrder {
                        id: idem,
                        outcome: p_ord.outcome,
                        side: p_ord.side,
                        price: p_ord.price,
                        qty: p_ord.qty
                    });
                }
                lvl += 1;
            }
            live_orders = updated_live;
        }
    }

    // 2. Heartbeat tick (every 2s)
    if (now_mono - last_heartbeat_at) >= 2000000000 {
        let hb_body = "{\"bot_id\":\"" + bot_id + "\",\"market_id\":\"" + market_id + "\",\"status\":\"QUOTING\",\"status_reason\":\"normal\",\"holding_yes\":" + to_str(inventory.yes_qty) + ",\"holding_no\":" + to_str(inventory.no_qty) + ",\"used\":" + to_str(inventory.cost_yes + inventory.cost_no) + ",\"spread_ticks\":3}";
        let hb_url = api_url + "/v1/internal/bots/heartbeat";
        let _ = send_post(client, hb_url, api_key, hb_body, "");
        last_heartbeat_at = now_mono;
    }

    loops += 1;
    if once_mode && loops >= 1 {
        println("[say-bots] Completed single-shot run cleanly.");
        break;
    }

    time.sleep(250000000); // 250ms
}
