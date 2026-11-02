pub struct BookTop {
    yes_bid: opt[int],
    yes_ask: opt[int]
}

pub struct Inventory {
    yes_qty: int,
    no_qty: int,
    cost_yes: int,
    cost_no: int
}

pub struct BotParams {
    base_spread_ticks: int,
    vol_ticks: int,
    skew_ticks: int,
    levels: int,
    base_size: int,
    max_net_shares: int,
    max_loss: int,
    season_max_drawdown: int,
    min_requote_ms: int,
    max_ops_per_sec: int,
    max_open_orders: int
}

pub fn default_params() -> BotParams {
    return BotParams {
        base_spread_ticks: 2,
        vol_ticks: 1,
        skew_ticks: 4,
        levels: 3,
        base_size: 10,
        max_net_shares: 400,
        max_loss: 50000,
        season_max_drawdown: 100000,
        min_requote_ms: 250,
        max_ops_per_sec: 10,
        max_open_orders: 20
    };
}

pub struct FillRecord {
    side: str,
    outcome: str,
    price: int,
    qty: int,
    filled_at_ms: int
}

pub struct QuoteInputs {
    V: int,
    min_price: int,
    max_price: int,
    tick: int,
    ref_price: int,
    ref_age_ms: int,
    book_top: BookTop,
    inventory: Inventory,
    cash_free: int,
    allocation: int,
    budget_used: int,
    params: BotParams,
    recent_fills: [FillRecord],
    market_status: str,
    trading_halted: bool,
    global_pause: bool,
    manual_pause: bool,
    season_drawdown: int,
    now_ms: int
}

pub struct DesiredOrder {
    outcome: str,
    side: str,
    price: int,
    qty: int
}

pub struct QuoteResult {
    status: str,
    status_label: str,
    status_reason: str,
    r_prime: int,
    spread_ticks: int,
    util: int,
    worst_case_loss: int,
    orders: [DesiredOrder]
}

fn clamp(val: int, low: int, high: int) -> int {
    if val < low {
        return low;
    }
    if val > high {
        return high;
    }
    return val;
}

fn div_ceil(num: int, den: int) -> int {
    if den == 0 {
        return 0;
    }
    return (num + den - 1) / den;
}

fn abs_int(x: int) -> int {
    if x < 0 {
        return -x;
    }
    return x;
}

pub fn status_to_label(status: str) -> str {
    if status == "QUOTING" {
        return "Quoting";
    }
    if status == "PULLED_STALE" {
        return "Pulled · old data";
    }
    if status == "PULLED_CAP" {
        return "Pulled · holding cap";
    }
    if status == "PULLED_DRAWDOWN" {
        return "Pulled · drawdown";
    }
    if status == "PULLED_MARKET" {
        return "Pulled · market halted";
    }
    if status == "PAUSED_MANUAL" {
        return "Paused by you";
    }
    if status == "PAUSED_ALL" {
        return "Paused · all bots";
    }
    return status;
}

pub fn calculate_worst_case_loss(inv: Inventory, V: int) -> int {
    let total_cost = inv.cost_yes + inv.cost_no;
    let val_if_yes = inv.yes_qty * V;
    let val_if_no = inv.no_qty * V;
    let loss_if_yes = total_cost - val_if_yes;
    let loss_if_no = total_cost - val_if_no;
    if loss_if_yes > loss_if_no {
        return loss_if_yes;
    }
    return loss_if_no;
}

pub fn quote(inputs: QuoteInputs) -> QuoteResult {
    let w_loss = calculate_worst_case_loss(inputs.inventory, inputs.V);

    // Hard Stop 1: Global Pause
    if inputs.global_pause {
        return QuoteResult {
            status: "PAUSED_ALL",
            status_label: status_to_label("PAUSED_ALL"),
            status_reason: "global pause active",
            r_prime: inputs.ref_price,
            spread_ticks: 0,
            util: 0,
            worst_case_loss: w_loss,
            orders: []
        };
    }

    // Hard Stop 2: Manual Pause
    if inputs.manual_pause {
        return QuoteResult {
            status: "PAUSED_MANUAL",
            status_label: status_to_label("PAUSED_MANUAL"),
            status_reason: "manual pause active",
            r_prime: inputs.ref_price,
            spread_ticks: 0,
            util: 0,
            worst_case_loss: w_loss,
            orders: []
        };
    }

    // Hard Stop 3: Market Status or Circuit Breaker
    if inputs.market_status != "OPEN" || inputs.trading_halted {
        return QuoteResult {
            status: "PULLED_MARKET",
            status_label: status_to_label("PULLED_MARKET"),
            status_reason: "market not open or trading halted",
            r_prime: inputs.ref_price,
            spread_ticks: 0,
            util: 0,
            worst_case_loss: w_loss,
            orders: []
        };
    }

    // Hard Stop 4: Stale Reference Data (> 30s)
    if inputs.ref_age_ms > 30000 {
        return QuoteResult {
            status: "PULLED_STALE",
            status_label: status_to_label("PULLED_STALE"),
            status_reason: "reference price older than 30s",
            r_prime: inputs.ref_price,
            spread_ticks: 0,
            util: 0,
            worst_case_loss: w_loss,
            orders: []
        };
    }

    // Hard Stop 5: Season Drawdown
    if inputs.season_drawdown > inputs.params.season_max_drawdown {
        return QuoteResult {
            status: "PULLED_DRAWDOWN",
            status_label: status_to_label("PULLED_DRAWDOWN"),
            status_reason: "season drawdown exceeded cap",
            r_prime: inputs.ref_price,
            spread_ticks: 0,
            util: 0,
            worst_case_loss: w_loss,
            orders: []
        };
    }

    // Step 2: Inventory Skew (r')
    let net = inputs.inventory.yes_qty - inputs.inventory.no_qty;
    let abs_net = abs_int(net);
    let max_shares = inputs.params.max_net_shares;
    if max_shares <= 0 {
        max_shares = 1;
    }
    let util_bps = (abs_net * 10000) / max_shares;
    if util_bps > 10000 {
        util_bps = 10000;
    }

    let shift_ticks = 0;
    if abs_net > 0 && inputs.params.skew_ticks > 0 {
        let raw_shift = inputs.params.skew_ticks * abs_net;
        shift_ticks = div_ceil(raw_shift, max_shares);
    }
    let shift = shift_ticks * inputs.tick;
    let r_prime = inputs.ref_price;
    if net > 0 {
        r_prime = clamp(inputs.ref_price - shift, inputs.min_price + 1, inputs.max_price - 1);
    } else if net < 0 {
        r_prime = clamp(inputs.ref_price + shift, inputs.min_price + 1, inputs.max_price - 1);
    }

    // Step 3: Spread Calculation
    let util_bump = util_bps / 2500; // +1 tick per 25% utilization
    let base_spread = inputs.params.base_spread_ticks + inputs.params.vol_ticks + util_bump;
    if base_spread < 1 {
        base_spread = 1;
    }

    // Adverse selection check: >= 4 fills on same side in last 60s
    let buy_fills_60s = 0;
    let sell_fills_60s = 0;
    for f in inputs.recent_fills {
        if inputs.now_ms - f.filled_at_ms <= 60000 {
            if f.side == "BUY" {
                buy_fills_60s += 1;
            } else if f.side == "SELL" {
                sell_fills_60s += 1;
            }
        }
    }
    let bid_spread_adj = 0;
    let ask_spread_adj = 0;
    if buy_fills_60s >= 4 {
        bid_spread_adj += 2;
    }
    if sell_fills_60s >= 4 {
        ask_spread_adj += 2;
    }

    let half_spread = div_ceil(base_spread, 2) * inputs.tick;
    let bid0 = clamp(r_prime - half_spread - (bid_spread_adj * inputs.tick), inputs.min_price, inputs.max_price - 1);
    let ask0 = clamp(r_prime + half_spread + (ask_spread_adj * inputs.tick), inputs.min_price + 1, inputs.max_price);

    if bid0 >= ask0 {
        ask0 = bid0 + inputs.tick;
    }

    // Step 5: Order Layering & Sizing
    let levels = inputs.params.levels;
    if levels < 1 {
        levels = 1;
    }
    if levels > 10 {
        levels = 10;
    }

    let mults = [100, 60, 35, 20, 15, 10, 10, 5, 5, 5];
    let budget_scaling_num = 100;
    if inputs.allocation > 0 {
        let pct_used = (inputs.budget_used * 100) / inputs.allocation;
        if pct_used > 70 {
            if pct_used >= 100 {
                budget_scaling_num = 0;
            } else {
                budget_scaling_num = ((100 - pct_used) * 100) / 30;
            }
        }
    }

    let base_size = inputs.params.base_size;
    let bid_orders: [DesiredOrder] = [];
    let ask_orders: [DesiredOrder] = [];

    // Check worst-case loss condition:
    // If w_loss > params.max_loss, only emit orders that reduce worst_case_loss
    let allow_bids = true;
    let allow_asks = true;
    let is_pulled_cap = false;

    if w_loss > inputs.params.max_loss {
        is_pulled_cap = true;
        // If holding excess YES, buying YES increases risk, so suppress bids.
        // Selling YES or buying NO reduces risk.
        if net > 0 {
            allow_bids = false;
        } else if net < 0 {
            allow_asks = false;
        } else {
            allow_bids = false;
            allow_asks = false;
        }
    }

    // Native share conversion track: available shares to sell
    let rem_yes_shares = inputs.inventory.yes_qty;
    let rem_no_shares = inputs.inventory.no_qty;
    let rem_cash = inputs.cash_free;

    for i in 0..levels {
        let m = mults[i];
        let raw_qty = (base_size * m) / 100;
        let lvl_qty = (raw_qty * budget_scaling_num) / 100;
        if lvl_qty <= 0 {
            continue;
        }

        // Bids (YES terms)
        if allow_bids {
            let bid_price = bid0 - (i * inputs.tick);
            if bid_price >= inputs.min_price {
                // If we hold NO shares, sell NO shares at (V - bid_price)
                if rem_no_shares >= lvl_qty {
                    push(bid_orders, DesiredOrder {
                        outcome: "NO",
                        side: "SELL",
                        price: inputs.V - bid_price,
                        qty: lvl_qty
                    });
                    rem_no_shares -= lvl_qty;
                } else if rem_no_shares > 0 {
                    let sell_qty = rem_no_shares;
                    let buy_qty = lvl_qty - sell_qty;
                    push(bid_orders, DesiredOrder {
                        outcome: "NO",
                        side: "SELL",
                        price: inputs.V - bid_price,
                        qty: sell_qty
                    });
                    rem_no_shares = 0;
                    let cost = buy_qty * bid_price;
                    if rem_cash >= cost {
                        push(bid_orders, DesiredOrder {
                            outcome: "YES",
                            side: "BUY",
                            price: bid_price,
                            qty: buy_qty
                        });
                        rem_cash -= cost;
                    }
                } else {
                    let cost = lvl_qty * bid_price;
                    if rem_cash >= cost {
                        push(bid_orders, DesiredOrder {
                            outcome: "YES",
                            side: "BUY",
                            price: bid_price,
                            qty: lvl_qty
                        });
                        rem_cash -= cost;
                    }
                }
            }
        }

        // Asks (YES terms)
        if allow_asks {
            let ask_price = ask0 + (i * inputs.tick);
            if ask_price <= inputs.max_price {
                // If we hold YES shares, sell YES shares at ask_price
                if rem_yes_shares >= lvl_qty {
                    push(ask_orders, DesiredOrder {
                        outcome: "YES",
                        side: "SELL",
                        price: ask_price,
                        qty: lvl_qty
                    });
                    rem_yes_shares -= lvl_qty;
                } else if rem_yes_shares > 0 {
                    let sell_qty = rem_yes_shares;
                    let buy_qty = lvl_qty - sell_qty;
                    push(ask_orders, DesiredOrder {
                        outcome: "YES",
                        side: "SELL",
                        price: ask_price,
                        qty: sell_qty
                    });
                    rem_yes_shares = 0;
                    let cost = buy_qty * (inputs.V - ask_price);
                    if rem_cash >= cost {
                        push(ask_orders, DesiredOrder {
                            outcome: "NO",
                            side: "BUY",
                            price: inputs.V - ask_price,
                            qty: buy_qty
                        });
                        rem_cash -= cost;
                    }
                } else {
                    let cost = lvl_qty * (inputs.V - ask_price);
                    if rem_cash >= cost {
                        push(ask_orders, DesiredOrder {
                            outcome: "NO",
                            side: "BUY",
                            price: inputs.V - ask_price,
                            qty: lvl_qty
                        });
                        rem_cash -= cost;
                    }
                }
            }
        }
    }

    let final_orders: [DesiredOrder] = [];
    for o in bid_orders {
        push(final_orders, o);
    }
    for o in ask_orders {
        push(final_orders, o);
    }

    let final_status = "QUOTING";
    let final_reason = "normal quoting";
    if is_pulled_cap {
        final_status = "PULLED_CAP";
        final_reason = "worst-case loss exceeds limit; quoting risk-reducing side only";
        if len(final_orders) == 0 {
            final_reason = "worst-case loss exceeds limit; all quotes pulled";
        }
    }

    return QuoteResult {
        status: final_status,
        status_label: status_to_label(final_status),
        status_reason: final_reason,
        r_prime: r_prime,
        spread_ticks: base_spread,
        util: util_bps,
        worst_case_loss: w_loss,
        orders: final_orders
    };
}
