
import "../domain" as domain;

pub gc struct PortfolioService[C] {
    store: PortfolioStore[C]
}

pub fn new_portfolio_service[C](store: PortfolioStore[C]) -> PortfolioService[C] {
    return PortfolioService[C] { store: store };
}

pub fn get_summary[C](
    s: PortfolioService[C],
    account_id: str,
    season_ordinal: int,
    stats_map: map[str]MarketPriceStats
) -> result[domain.SummaryView, str] {
    let bal_res = (s.store.read_balance)(s.store.context, account_id, season_ordinal);
    guard let bal = bal_res else let e = err_of(bal_res) {
        return err(e);
    }

    let held_shares_res = (s.store.read_held_shares)(s.store.context, account_id, season_ordinal);
    guard let raw_held_shares = held_shares_res else let e = err_of(held_shares_res) {
        return err(e);
    }

    let pos_res = (s.store.read_positions)(s.store.context, account_id, season_ordinal);
    guard let raw_positions = pos_res else let e = err_of(pos_res) {
        return err(e);
    }

    let positions_value = 0;
    for pos in raw_positions {
        let stats = MarketPriceStats {
            last_price: 0,
            has_last_price: false,
            best_bid: 0,
            has_best_bid: false,
            best_ask: 0,
            has_best_ask: false
        };
        if has(stats_map, pos.market_id) {
            stats = stats_map[pos.market_id];
        }

        let pv = domain.compute_position_valuation(
            pos.redemption_units,
            pos.outcome,
            pos.qty,
            pos.cost_basis,
            stats.last_price,
            stats.has_last_price,
            stats.best_bid,
            stats.has_best_bid,
            stats.best_ask,
            stats.has_best_ask
        );
        positions_value = positions_value + pv.value;
    }

    let sv = domain.compute_summary_valuation(
        bal.available,
        bal.held,
        positions_value,
        bal.starting_grant,
        bal.has_starting_grant
    );

    let held_shares: [domain.HeldShare] = [];
    for hs in raw_held_shares {
        push(held_shares, domain.HeldShare {
            market_id: hs.market_id,
            outcome: hs.outcome,
            qty: hs.qty
        });
    }

    return ok(domain.SummaryView {
        season: domain.SeasonInfo {
            ordinal: bal.season_ordinal,
            status: bal.season_status,
            ends_at: bal.ends_at
        },
        available: bal.available,
        held: bal.held,
        held_shares: held_shares,
        positions_value: positions_value,
        total: sv.total,
        season_pnl: sv.season_pnl,
        has_season_pnl: sv.has_season_pnl,
        starting_grant: bal.starting_grant,
        has_starting_grant: bal.has_starting_grant,
        rank_position: 0,
        rank_of: 0,
        has_rank: false
    });
}

pub fn get_positions[C](
    s: PortfolioService[C],
    account_id: str,
    season_ordinal: int,
    stats_map: map[str]MarketPriceStats
) -> result[[domain.PositionView], str] {
    let pos_res = (s.store.read_positions)(s.store.context, account_id, season_ordinal);
    guard let raw_positions = pos_res else let e = err_of(pos_res) {
        return err(e);
    }

    let items: [domain.PositionView] = [];
    for pos in raw_positions {
        let stats = MarketPriceStats {
            last_price: 0,
            has_last_price: false,
            best_bid: 0,
            has_best_bid: false,
            best_ask: 0,
            has_best_ask: false
        };
        if has(stats_map, pos.market_id) {
            stats = stats_map[pos.market_id];
        }

        let pv = domain.compute_position_valuation(
            pos.redemption_units,
            pos.outcome,
            pos.qty,
            pos.cost_basis,
            stats.last_price,
            stats.has_last_price,
            stats.best_bid,
            stats.has_best_bid,
            stats.best_ask,
            stats.has_best_ask
        );

        let g = domain.gcd(pos.cost_basis, pos.qty);
        if g <= 0 { g = 1; }
        let avg_price = domain.Rational {
            num: pos.cost_basis / g,
            den: pos.qty / g
        };

        push(items, domain.PositionView {
            market: domain.MarketInfo {
                id: pos.market_id,
                slug: pos.slug,
                question: pos.question,
                category: pos.category,
                status: pos.status,
                closes_at: pos.closes_at,
                redemption_units: pos.redemption_units
            },
            outcome: pos.outcome,
            qty: pos.qty,
            qty_free: pos.qty_free,
            qty_in_orders: pos.qty_in_orders,
            avg_price: avg_price,
            mark: pv.mark,
            mark_source: pv.mark_source,
            value: pv.value,
            unrealized_pnl: pv.unrealized_pnl,
            pnl_pct: pv.pnl_pct,
            has_pnl_pct: pv.has_pnl_pct,
            proposed_outcome: pos.proposed_outcome,
            has_proposed_outcome: pos.has_proposed_outcome
        });
    }

    return ok(items);
}

pub fn get_results[C](
    s: PortfolioService[C],
    account_id: str,
    season_ordinal: int
) -> result[[domain.ResultView], str] {
    let res = (s.store.read_results)(s.store.context, account_id, season_ordinal);
    guard let raw_results = res else let e = err_of(res) {
        return err(e);
    }

    let items: [domain.ResultView] = [];
    for r in raw_results {
        let g = domain.gcd(r.cost_basis, r.qty);
        if g <= 0 { g = 1; }
        let avg_price = domain.Rational {
            num: r.cost_basis / g,
            den: r.qty / g
        };

        push(items, domain.ResultView {
            market: domain.MarketInfo {
                id: r.market_id,
                slug: r.slug,
                question: r.question,
                category: r.category,
                status: r.status,
                closes_at: r.closes_at,
                redemption_units: r.redemption_units
            },
            outcome: r.outcome,
            qty: r.qty,
            avg_price: avg_price,
            result_outcome: r.result_outcome,
            paid_out: r.paid_out,
            pnl: r.pnl,
            settled_at: r.settled_at
        });
    }

    return ok(items);
}
