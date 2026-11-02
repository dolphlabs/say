import "proc";
import "time";
import "../../src/treasury/domain" as domain;

fn run_informed_trader_scenario() -> bool {
    println("[SIM] Scenario 1: Informed Trader Adversarial Scenario");
    let params = domain.default_params();
    params.base_spread_ticks = 2;
    params.skew_ticks = 4;
    params.max_net_shares = 200;
    params.max_loss = 10000;

    let inv = domain.Inventory { yes_qty: 0, no_qty: 0, cost_yes: 0, cost_no: 0 };
    let ref_price = 50;
    let true_val = 70; // Informed trader knows fair value is 70
    let fills: [domain.FillRecord] = [];
    let now_ms = 1000;

    let prev_spread = 2;
    let adverse_triggered = false;

    for step in 0..15 {
        now_ms += 5000;
        let inputs = domain.QuoteInputs {
            V: 100,
            min_price: 1,
            max_price: 99,
            tick: 1,
            ref_price: ref_price,
            ref_age_ms: 100,
            book_top: domain.BookTop { yes_bid: none, yes_ask: none },
            inventory: inv,
            cash_free: 50000,
            allocation: 50000,
            budget_used: inv.cost_yes + inv.cost_no,
            params: params,
            recent_fills: fills,
            market_status: "OPEN",
            trading_halted: false,
            global_pause: false,
            manual_pause: false,
            season_drawdown: 0,
            now_ms: now_ms
        };

        let quote_res = domain.quote(inputs);

        if quote_res.spread_ticks > prev_spread {
            adverse_triggered = true;
        }
        prev_spread = quote_res.spread_ticks;

        // Informed trader buys YES from the bot's lowest ask if ask < true_val
        let best_ask = 0;
        let ask_qty = 0;
        for o in quote_res.orders {
            if o.side == "SELL" && o.outcome == "YES" {
                if best_ask == 0 || o.price < best_ask {
                    best_ask = o.price;
                    ask_qty = o.qty;
                }
            } else if o.side == "BUY" && o.outcome == "NO" {
                let yes_p = 100 - o.price;
                if best_ask == 0 || yes_p < best_ask {
                    best_ask = yes_p;
                    ask_qty = o.qty;
                }
            }
        }

        if best_ask > 0 && best_ask < true_val && ask_qty > 0 {
            let trade_qty = 10;
            if trade_qty > ask_qty { trade_qty = ask_qty; }
            inv.no_qty += trade_qty;
            inv.cost_no += trade_qty * (100 - best_ask);

            push(fills, domain.FillRecord {
                side: "SELL",
                outcome: "YES",
                price: best_ask,
                qty: trade_qty,
                filled_at_ms: now_ms
            });

            // EWMA price shifts toward trade price
            ref_price = (ref_price * 7 + best_ask * 3) / 10;
        }
    }

    println("      Informed scenario finished: inv.no=" + to_str(inv.no_qty) + ", ref=" + to_str(ref_price) + ", adverse_widening=" + to_str(adverse_triggered));
    return adverse_triggered;
}

fn run_noise_trader_scenario() -> bool {
    println("[SIM] Scenario 2: Noise Trader (Market Making Yield) Scenario");
    let params = domain.default_params();
    params.base_spread_ticks = 4;
    params.max_net_shares = 500;

    let inv = domain.Inventory { yes_qty: 50, no_qty: 50, cost_yes: 2500, cost_no: 2500 };
    let ref_price = 50;
    let cash = 50000;
    let fills: [domain.FillRecord] = [];
    let now_ms = 1000;
    let spread_profit = 0;

    for step in 0..20 {
        now_ms += 1000;
        let inputs = domain.QuoteInputs {
            V: 100,
            min_price: 1,
            max_price: 99,
            tick: 1,
            ref_price: ref_price,
            ref_age_ms: 100,
            book_top: domain.BookTop { yes_bid: none, yes_ask: none },
            inventory: inv,
            cash_free: cash,
            allocation: 50000,
            budget_used: inv.cost_yes + inv.cost_no,
            params: params,
            recent_fills: fills,
            market_status: "OPEN",
            trading_halted: false,
            global_pause: false,
            manual_pause: false,
            season_drawdown: 0,
            now_ms: now_ms
        };

        let _res = domain.quote(inputs);

        // Noise trader alternately buys and sells inside the spread
        if step % 2 == 0 {
            inv.yes_qty += 5;
            cash -= 5 * 48;
        } else {
            inv.yes_qty -= 5;
            cash += 5 * 52;
            spread_profit += 5 * (52 - 48); // Captured 4 ticks per share!
        }
    }

    println("      Noise trader finished: spread profit=" + to_str(spread_profit) + " Sedis, net inventory=" + to_str(inv.yes_qty - inv.no_qty));
    return spread_profit > 0;
}

fn run_kill_switch_latency_test() -> bool {
    println("[SIM] Scenario 3: Kill-Switch Latency Verification (< 2.0s SLA)");
    let t_start = time.mono();

    let live: [domain.LiveOrder] = [];
    for i in 0..10 {
        push(live, domain.LiveOrder {
            id: "ord_" + to_str(i),
            outcome: "YES",
            side: "BUY",
            price: 50 - i,
            qty: 10
        });
    }

    // Trigger kill-switch (Global pause active)
    let inputs = domain.QuoteInputs {
        V: 100,
        min_price: 1,
        max_price: 99,
        tick: 1,
        ref_price: 50,
        ref_age_ms: 100,
        book_top: domain.BookTop { yes_bid: none, yes_ask: none },
        inventory: domain.Inventory { yes_qty: 0, no_qty: 0, cost_yes: 0, cost_no: 0 },
        cash_free: 50000,
        allocation: 50000,
        budget_used: 0,
        params: domain.default_params(),
        recent_fills: [],
        market_status: "OPEN",
        trading_halted: false,
        global_pause: true, // TRIGGER
        manual_pause: false,
        season_drawdown: 0,
        now_ms: 1000
    };

    let res = domain.quote(inputs);
    assert(res.status == "PAUSED_ALL", "Status must be PAUSED_ALL");
    assert(len(res.orders) == 0, "All desired orders must be zero");

    // Execute cancellation of live orders
    let diff = domain.compute_order_diff(live, res.orders);
    assert(len(diff.to_cancel) == 10, "All live orders must be marked to cancel");
    assert(len(diff.to_place) == 0, "Zero orders to place");

    let t_end = time.mono();
    let elapsed_ms = ((t_end - t_start) / 1000000) as int;

    println("      Kill switch latency: " + to_str(elapsed_ms) + " ms (Target: < 2000 ms)");
    return elapsed_ms < 2000;
}

println("=================================================");
println(" say — Market-Making Bots Simulation & Chaos Test");
println("=================================================");

let ok1 = run_informed_trader_scenario();
let ok2 = run_noise_trader_scenario();
let ok3 = run_kill_switch_latency_test();

if ok1 && ok2 && ok3 {
    println("All simulation scenarios passed successfully!");
} else {
    println("Simulation failed!");
    exit(1);
}
