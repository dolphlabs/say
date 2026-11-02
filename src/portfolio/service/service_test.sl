import "../domain" as domain;

gc struct FakeStoreCtx {
    balance: RawBalance,
    held_shares: [RawHeldShare],
    positions: [RawPosition],
    results: [RawResult]
}

fn fake_read_balance(ctx: FakeStoreCtx, account_id: str, season_ordinal: int) -> result[RawBalance, str] {
    return ok(ctx.balance);
}

fn fake_read_held_shares(ctx: FakeStoreCtx, account_id: str, season_ordinal: int) -> result[[RawHeldShare], str] {
    return ok(ctx.held_shares);
}

fn fake_read_positions(ctx: FakeStoreCtx, account_id: str, season_ordinal: int) -> result[[RawPosition], str] {
    return ok(ctx.positions);
}

fn fake_read_results(ctx: FakeStoreCtx, account_id: str, season_ordinal: int) -> result[[RawResult], str] {
    return ok(ctx.results);
}

fn test_portfolio_service_summary_and_positions() {
    let ctx = FakeStoreCtx {
        balance: RawBalance {
            season_ordinal: 1,
            season_status: "ACTIVE",
            ends_at: "2026-12-31T23:59:59Z",
            available: 427,
            held: 109,
            starting_grant: 1000,
            has_starting_grant: true
        },
        held_shares: [
            RawHeldShare { market_id: "mkt-1", outcome: "YES", qty: 4 }
        ],
        positions: [
            RawPosition {
                market_id: "mkt-1",
                slug: "enyimba-rivers",
                question: "Enyimba vs Rivers",
                category: "SPORTS",
                status: "OPEN",
                closes_at: "2026-12-31T23:59:59Z",
                redemption_units: 100,
                outcome: "YES",
                qty: 18,
                qty_free: 14,
                qty_in_orders: 4,
                cost_basis: 900,
                proposed_outcome: "",
                has_proposed_outcome: false
            }
        ],
        results: []
    };

    let store = PortfolioStore[FakeStoreCtx] {
        context: ctx,
        read_balance: fake_read_balance,
        read_held_shares: fake_read_held_shares,
        read_positions: fake_read_positions,
        read_results: fake_read_results
    };

    let svc = new_portfolio_service(store);
    let stats_map: map[str]MarketPriceStats = {
        "mkt-1": MarketPriceStats {
            last_price: 54,
            has_last_price: true,
            best_bid: 52,
            has_best_bid: true,
            best_ask: 56,
            has_best_ask: true
        }
    };

    let summary_res = get_summary(svc, "acc-1", 1, stats_map);
    guard let summary = summary_res else {
        panic("get_summary failed");
    }
    assert(summary.available == 427);
    assert(summary.held == 109);
    // 18 qty * 54 = 972 value
    assert(summary.positions_value == 972);
    // total = 427 + 109 + 972 = 1508
    assert(summary.total == 1508);
    assert(summary.season_pnl == 508);
    assert(len(summary.held_shares) == 1);
    assert(summary.held_shares[0].qty == 4);

    let pos_res = get_positions(svc, "acc-1", 1, stats_map);
    guard let positions = pos_res else {
        panic("get_positions failed");
    }
    assert(len(positions) == 1);
    assert(positions[0].mark.num == 54);
    assert(positions[0].mark.den == 1);
    assert(positions[0].qty_free == 14);
    assert(positions[0].qty_in_orders == 4);
    assert(positions[0].value == 972);
}
