import "pg";
import "time";
import "zokor";
import "../domain" as domain;
import "../service" as ports;

pub gc struct PostgresStandingsStore {
    conn: pg.Pool
}

pub fn new_store(pool: pg.Pool) -> PostgresStandingsStore {
    return PostgresStandingsStore { conn: pool };
}

gc struct SeasonInfoSqlRow {
    id: str,
    ordinal: int,
    status: str,
    starts_at: int,
    ends_at: int,
    players: int,
    unfinalized_markets: int
}

gc struct StandingsSqlRow {
    account_id: str,
    username: str,
    avatar_color: str,
    profit: int,
    calls: int,
    wins: int,
    losses: int,
    profit_reached_at: int,
    rank_profit: int,
    rank_win: opt[int],
    rank_calls: int,
    leaderboard_eligible: bool
}

fn st_dl() -> until {
    return until_of(time.mono() + 5000000000);
}

pub fn get_current_season(s: PostgresStandingsStore) -> result[opt[domain.SeasonInfo], str] {
    let empty_args: [pg.Arg] = [];
    let r: result[[SeasonInfoSqlRow], str] = zokor.query_all(s.conn,
        "select s.id::text as id, s.ordinal, s.status, " +
        "(extract(epoch from s.starts_at)*1000)::bigint as starts_at, " +
        "(extract(epoch from s.ends_at)*1000)::bigint as ends_at, " +
        "(select count(*) from accounts a where a.status = 'ACTIVE' and a.kind = 'USER' and a.leaderboard_eligible = true)::int as players, " +
        "(select count(*) from markets m where m.season_id = s.id and m.status not in ('FINALIZED', 'VOIDED'))::int as unfinalized_markets " +
        "from seasons s where s.status in ('ACTIVE', 'CLOSED', 'FINALIZED') order by s.ordinal desc limit 1",
        empty_args, st_dl());
    guard let rows = r else let e = err_of(r) { return err(e); }
    if len(rows) == 0 {
        let none_val: opt[domain.SeasonInfo] = none;
        return ok(none_val);
    }
    let row = rows[0];
    let ordinal = row.ordinal;
    let status = row.status;
    let starts_at = row.starts_at;
    let ends_at = row.ends_at;
    let players = row.players;
    let unfinalized = row.unfinalized_markets;
    let provisional = (status == "CLOSED" || status == "CLOSING") && unfinalized > 0;
    let reason = "";
    if provisional {
        reason = to_str(unfinalized) + " markets still settling";
    }
    return ok(some(domain.SeasonInfo {
        ordinal: ordinal,
        status: status,
        starts_at: starts_at,
        ends_at: ends_at,
        players: players,
        provisional: provisional,
        provisional_reason: reason
    }));
}

pub fn load_standings_rows(s: PostgresStandingsStore, season_ordinal: int, sort_by: str, limit_n: int) -> result[[domain.StandingsRow], str] {
    let q = "select ss.account_id::text as account_id, a.username, coalesce(a.avatar_color, '#e91e63') as avatar_color, " +
        "ss.profit, ss.calls, ss.wins, ss.losses, " +
        "(extract(epoch from ss.profit_reached_at)*1000)::bigint as profit_reached_at, " +
        "ss.rank_profit, ss.rank_win, ss.rank_calls, a.leaderboard_eligible " +
        "from season_standings ss " +
        "join accounts a on a.id = ss.account_id " +
        "join seasons s on s.id = ss.season_id " +
        "where s.ordinal = $1 and a.status = 'ACTIVE' and a.leaderboard_eligible = true " +
        "order by ss.profit desc, ss.profit_reached_at asc, ss.account_id asc limit $2";
    if sort_by == "win_rate" {
        q = "select ss.account_id::text as account_id, a.username, coalesce(a.avatar_color, '#e91e63') as avatar_color, " +
            "ss.profit, ss.calls, ss.wins, ss.losses, " +
            "(extract(epoch from ss.profit_reached_at)*1000)::bigint as profit_reached_at, " +
            "ss.rank_profit, ss.rank_win, ss.rank_calls, a.leaderboard_eligible " +
            "from season_standings ss " +
            "join accounts a on a.id = ss.account_id " +
            "join seasons s on s.id = ss.season_id " +
            "where s.ordinal = $1 and a.status = 'ACTIVE' and a.leaderboard_eligible = true " +
            "and ss.rank_win is not null order by ss.rank_win asc, ss.profit desc limit $2";
    } else if sort_by == "calls" {
        q = "select ss.account_id::text as account_id, a.username, coalesce(a.avatar_color, '#e91e63') as avatar_color, " +
            "ss.profit, ss.calls, ss.wins, ss.losses, " +
            "(extract(epoch from ss.profit_reached_at)*1000)::bigint as profit_reached_at, " +
            "ss.rank_profit, ss.rank_win, ss.rank_calls, a.leaderboard_eligible " +
            "from season_standings ss " +
            "join accounts a on a.id = ss.account_id " +
            "join seasons s on s.id = ss.season_id " +
            "where s.ordinal = $1 and a.status = 'ACTIVE' and a.leaderboard_eligible = true " +
            "order by ss.rank_calls asc, ss.profit desc limit $2";
    }

    let r: result[[StandingsSqlRow], str] = zokor.query_all(s.conn, q, [pg.arg_int(season_ordinal), pg.arg_int(limit_n)], st_dl());
    guard let rows = r else let e = err_of(r) { return err(e); }

    let out: [domain.StandingsRow] = [];
    for row in rows {
        push(out, domain.StandingsRow {
            account_id: row.account_id,
            username: row.username,
            avatar_color: row.avatar_color,
            profit: row.profit,
            calls: row.calls,
            wins: row.wins,
            losses: row.losses,
            profit_reached_at: row.profit_reached_at,
            rank_profit: row.rank_profit,
            rank_win: row.rank_win,
            rank_calls: row.rank_calls,
            win_rate: domain.calculate_win_rate(row.wins, row.losses),
            leaderboard_eligible: row.leaderboard_eligible
        });
    }
    return ok(out);
}

pub fn recompute_season_standings(s: PostgresStandingsStore, now_ms: int) -> result[int, str] {
    let q = "with current_season as ( " +
        "  select id, ordinal from seasons where status in ('ACTIVE', 'CLOSED') order by ordinal desc limit 1 " +
        "), " +
        "eligible_accounts as ( " +
        "  select a.id, a.username, a.created_at " +
        "  from accounts a " +
        "  where a.status = 'ACTIVE' and a.kind = 'USER' and a.leaderboard_eligible = true " +
        "    and not exists (select 1 from account_roles ar where ar.account_id = a.id and ar.role in ('curator','treasury','resolver','admin','super_admin')) " +
        "), " +
        "cash_totals as ( " +
        "  select w.account_id, coalesce(w.available_units + w.held_units, 0)::bigint as cash " +
        "  from wallets w where w.asset = 'SEDI' " +
        "), " +
        "user_calls as ( " +
        "  select p.account_id, count(distinct p.market_id)::int as calls " +
        "  from positions p group by p.account_id " +
        "), " +
        "user_results as ( " +
        "  select pr.account_id, " +
        "    count(case when pr.payout_units > pr.cost_units then 1 end)::int as wins, " +
        "    count(case when pr.payout_units < pr.cost_units then 1 end)::int as losses " +
        "  from position_results pr group by pr.account_id " +
        "), " +
        "calculated as ( " +
        "  select ea.id as account_id, cs.id as season_id, " +
        "    coalesce(ct.cash, 0) - 1000 as profit, " +
        "    coalesce(uc.calls, 0) as calls, " +
        "    coalesce(ur.wins, 0) as wins, " +
        "    coalesce(ur.losses, 0) as losses " +
        "  from eligible_accounts ea " +
        "  cross join current_season cs " +
        "  left join cash_totals ct on ct.account_id = ea.id " +
        "  left join user_calls uc on uc.account_id = ea.id " +
        "  left join user_results ur on ur.account_id = ea.id " +
        "), " +
        "ranked as ( " +
        "  select c.*, " +
        "    row_number() over (partition by c.season_id order by c.profit desc, ea.created_at asc, c.account_id asc)::int as r_profit, " +
        "    case when (c.wins + c.losses) >= 5 then " +
        "      row_number() over (partition by c.season_id order by (c.wins::numeric / (c.wins + c.losses)::numeric) desc, c.profit desc)::int " +
        "    else null end as r_win, " +
        "    row_number() over (partition by c.season_id order by c.calls desc, c.profit desc)::int as r_calls " +
        "  from calculated c " +
        "  join accounts ea on ea.id = c.account_id " +
        ") " +
        "insert into season_standings(season_id, account_id, profit, calls, wins, losses, profit_reached_at, rank_profit, rank_win, rank_calls, computed_at) " +
        "select season_id, account_id, profit, calls, wins, losses, to_timestamp($1/1000.0), r_profit, r_win, r_calls, to_timestamp($1/1000.0) " +
        "from ranked " +
        "on conflict (season_id, account_id) do update set " +
        "  profit = excluded.profit, " +
        "  calls = excluded.calls, " +
        "  wins = excluded.wins, " +
        "  losses = excluded.losses, " +
        "  profit_reached_at = case when season_standings.profit = excluded.profit then season_standings.profit_reached_at else excluded.profit_reached_at end, " +
        "  rank_profit = excluded.rank_profit, " +
        "  rank_win = excluded.rank_win, " +
        "  rank_calls = excluded.rank_calls, " +
        "  computed_at = excluded.computed_at";

    let r = pg.pool_query(s.conn, q, [pg.arg_int(now_ms)], st_dl());
    guard let _n = r else let e = err_of(r) { return err(e); }
    return ok(1);
}

pub fn freeze_final_standings(s: PostgresStandingsStore, season_id: str, now_ms: int) -> result[bool, str] {
    let q = "insert into season_final_standings(season_id, account_id, username_at_time, profit, calls, wins, losses, profit_reached_at, rank_profit, rank_win, rank_calls, frozen_at) " +
        "select ss.season_id, ss.account_id, a.username, ss.profit, ss.calls, ss.wins, ss.losses, ss.profit_reached_at, ss.rank_profit, ss.rank_win, ss.rank_calls, to_timestamp($2/1000.0) " +
        "from season_standings ss " +
        "join accounts a on a.id = ss.account_id " +
        "where ss.season_id = $1::uuid " +
        "on conflict (season_id, account_id) do nothing";
    let r = pg.pool_query(s.conn, q, [pg.arg_text(season_id), pg.arg_int(now_ms)], st_dl());
    guard let _n = r else let e = err_of(r) { return err(e); }
    return ok(true);
}

pub fn standings_store(s: PostgresStandingsStore) -> ports.StandingsStore[PostgresStandingsStore] {
    return ports.StandingsStore[PostgresStandingsStore] {
        context: s,
        get_current_season: get_current_season,
        load_standings_rows: load_standings_rows,
        recompute_season_standings: recompute_season_standings,
        freeze_final_standings: freeze_final_standings
    };
}
