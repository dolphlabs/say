import "pg";
import "time";
import "zokor";
import "../service" as service;

pub gc struct PostgresPortfolioStore {
    pool: pg.Pool
}

fn pg_deadline() -> until {
    return until_of(time.mono() + 5000000000); // 5s timeout
}

gc struct BalanceSqlRow {
    season_ordinal: int,
    season_status: str,
    ends_at: str,
    available: int,
    held: int,
    starting_grant: opt[int]
}

gc struct HeldShareSqlRow {
    market_id: str,
    outcome: str,
    qty: int
}

gc struct PositionSqlRow {
    market_id: str,
    slug: str,
    question: str,
    category: str,
    status: str,
    closes_at: str,
    redemption_units: int,
    outcome: str,
    qty: int,
    qty_free: int,
    qty_in_orders: int,
    cost_basis: int,
    proposed_outcome: str,
    has_proposed_outcome: bool
}

gc struct ResultSqlRow {
    market_id: str,
    slug: str,
    question: str,
    category: str,
    status: str,
    closes_at: str,
    redemption_units: int,
    outcome: str,
    qty: int,
    cost_basis: int,
    fees: int,
    paid_out: int,
    pnl: int,
    result_outcome: str,
    settled_at: str
}

fn st_read_balance(s: PostgresPortfolioStore, account_id: str, season_ordinal: int) -> result[service.RawBalance, str] {
    let r: result[opt[BalanceSqlRow], str] = zokor.query_one(s.pool,
        "select s.ordinal as season_ordinal, s.status as season_status, " +
        "to_char(s.ends_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') as ends_at, " +
        "coalesce(w.free_units, 0) as available, coalesce(w.held_units, 0) as held, " +
        "g.amount as starting_grant from seasons s " +
        "left join wallets w on w.season_id = s.id and w.owner_id = $1 and w.asset_key = 'SEDI' " +
        "left join issuance_grants g on g.season_id = s.id and g.account_id = $1::uuid " +
        "where (s.status = 'ACTIVE' and $2 = 0) or (s.ordinal = $2 and $2 > 0) " +
        "order by s.ordinal desc limit 1",
        [pg.arg_text(account_id), pg.arg_int(season_ordinal)], pg_deadline());

    guard let found = r else let e = err_of(r) {
        return err(e);
    }
    guard let row = found else {
        return err("SEASON_NOT_FOUND");
    }

    let has_grant = false;
    let grant_val = 0;
    if let g = row.starting_grant {
        has_grant = true;
        grant_val = g;
    }

    return ok(service.RawBalance {
        season_ordinal: row.season_ordinal,
        season_status: row.season_status,
        ends_at: row.ends_at,
        available: row.available,
        held: row.held,
        starting_grant: grant_val,
        has_starting_grant: has_grant
    });
}

fn st_read_held_shares(s: PostgresPortfolioStore, account_id: str, season_ordinal: int) -> result[[service.RawHeldShare], str] {
    let r: result[[HeldShareSqlRow], str] = zokor.query_all(s.pool,
        "select split_part(w.asset_key, ':', 2) as market_id, " +
        "split_part(w.asset_key, ':', 1) as outcome, " +
        "w.held_units as qty " +
        "from wallets w " +
        "join seasons s on s.id = w.season_id " +
        "where w.account_id = $1::uuid " +
        "and ((s.status = 'ACTIVE' and $2 = 0) or (s.ordinal = $2 and $2 > 0)) " +
        "and w.asset_key <> 'SEDI' and w.held_units > 0 " +
        "order by w.created_at asc",
        [pg.arg_text(account_id), pg.arg_int(season_ordinal)], pg_deadline());

    guard let rows = r else let e = err_of(r) {
        return err(e);
    }

    let out: [service.RawHeldShare] = [];
    for row in rows {
        push(out, service.RawHeldShare {
            market_id: row.market_id,
            outcome: row.outcome,
            qty: row.qty
        });
    }
    return ok(out);
}

fn st_read_positions(s: PostgresPortfolioStore, account_id: str, season_ordinal: int) -> result[[service.RawPosition], str] {
    let r: result[[PositionSqlRow], str] = zokor.query_all(s.pool,
        "select p.market_id::text as market_id, coalesce(m.slug, '') as slug, " +
        "coalesce(m.question, '') as question, coalesce(c.name, 'GENERAL') as category, " +
        "m.status, to_char(coalesce(m.close_at, now()), 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') as closes_at, " +
        "coalesce(m.redemption_units, 100) as redemption_units, " +
        "p.outcome, p.qty, " +
        "coalesce(w.free_units, p.qty) as qty_free, " +
        "coalesce(w.held_units, 0) as qty_in_orders, " +
        "p.cost_basis, " +
        "coalesce(m.proposed_outcome, '') as proposed_outcome, " +
        "(m.proposed_outcome is not null) as has_proposed_outcome " +
        "from positions p " +
        "join markets m on m.id = p.market_id " +
        "left join categories c on c.id = m.category_id " +
        "join seasons s on s.id = p.season_id " +
        "left join wallets w on w.season_id = p.season_id and w.account_id = p.account_id " +
        "     and w.asset_key = (p.outcome || ':' || p.market_id::text) " +
        "where p.account_id = $1::uuid " +
        "and ((s.status = 'ACTIVE' and $2 = 0) or (s.ordinal = $2 and $2 > 0)) " +
        "and p.qty > 0 " +
        "order by p.updated_at desc",
        [pg.arg_text(account_id), pg.arg_int(season_ordinal)], pg_deadline());

    guard let rows = r else let e = err_of(r) {
        return err(e);
    }

    let out: [service.RawPosition] = [];
    for row in rows {
        push(out, service.RawPosition {
            market_id: row.market_id,
            slug: row.slug,
            question: row.question,
            category: row.category,
            status: row.status,
            closes_at: row.closes_at,
            redemption_units: row.redemption_units,
            outcome: row.outcome,
            qty: row.qty,
            qty_free: row.qty_free,
            qty_in_orders: row.qty_in_orders,
            cost_basis: row.cost_basis,
            proposed_outcome: row.proposed_outcome,
            has_proposed_outcome: row.has_proposed_outcome
        });
    }
    return ok(out);
}

fn st_read_results(s: PostgresPortfolioStore, account_id: str, season_ordinal: int) -> result[[service.RawResult], str] {
    let r: result[[ResultSqlRow], str] = zokor.query_all(s.pool,
        "select pr.market_id::text as market_id, coalesce(m.slug, '') as slug, " +
        "coalesce(m.question, '') as question, coalesce(c.name, 'GENERAL') as category, " +
        "m.status, to_char(coalesce(m.close_at, now()), 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') as closes_at, " +
        "coalesce(m.redemption_units, 100) as redemption_units, " +
        "pr.outcome, pr.qty, pr.cost_basis, pr.fees, pr.paid_out, pr.pnl, " +
        "pr.result as result_outcome, " +
        "to_char(pr.settled_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') as settled_at " +
        "from position_results pr " +
        "join markets m on m.id = pr.market_id " +
        "left join categories c on c.id = m.category_id " +
        "join seasons s on s.id = pr.season_id " +
        "where pr.account_id = $1::uuid " +
        "and ((s.status = 'ACTIVE' and $2 = 0) or (s.ordinal = $2 and $2 > 0)) " +
        "order by pr.settled_at desc",
        [pg.arg_text(account_id), pg.arg_int(season_ordinal)], pg_deadline());

    guard let rows = r else let e = err_of(r) {
        return err(e);
    }

    let out: [service.RawResult] = [];
    for row in rows {
        push(out, service.RawResult {
            market_id: row.market_id,
            slug: row.slug,
            question: row.question,
            category: row.category,
            status: row.status,
            closes_at: row.closes_at,
            redemption_units: row.redemption_units,
            outcome: row.outcome,
            qty: row.qty,
            cost_basis: row.cost_basis,
            fees: row.fees,
            paid_out: row.paid_out,
            pnl: row.pnl,
            result_outcome: row.result_outcome,
            settled_at: row.settled_at
        });
    }
    return ok(out);
}

pub fn make_postgres_portfolio_store(pool: pg.Pool) -> service.PortfolioStore[PostgresPortfolioStore] {
    let s = PostgresPortfolioStore { pool: pool };
    return service.PortfolioStore[PostgresPortfolioStore] {
        context: s,
        read_balance: st_read_balance,
        read_held_shares: st_read_held_shares,
        read_positions: st_read_positions,
        read_results: st_read_results
    };
}
