import "pg";
import "time";
import "zokor";
import "../domain" as domain;
import "../service" as ports;

pub gc struct PostgresProfileStore {
    conn: pg.Pool
}

pub fn new_store(pool: pg.Pool) -> PostgresProfileStore {
    return PostgresProfileStore { conn: pool };
}

gc struct AccountLookupDbRow {
    id: str,
    username: str,
    avatar_color: str,
    status: str,
    created_at_ms: int,
    joined_season: str
}

gc struct UsernameHistoryDbRow {
    current_username: str
}

gc struct ProfileCallDbRow {
    slug: str,
    question: str,
    side: str,
    status: str,
    chance_pct: opt[int]
}

gc struct CurrentStatsDbRow {
    rank: int,
    of: int,
    profit: int,
    calls: int,
    right_count: int,
    settled: int
}

fn pr_dl() -> until {
    return until_of(time.mono() + 5000000000);
}

pub fn find_user(s: PostgresProfileStore, raw_username: str) -> result[ports.AccountLookup, str] {
    let r: result[[AccountLookupDbRow], str] = zokor.query_all(s.conn,
        "select id::text as id, username, coalesce(avatar_color, '#e91e63') as avatar_color, status, " +
        "(extract(epoch from a.created_at)*1000)::bigint as created_at_ms, " +
        "coalesce((select 'Season ' || lpad(s.ordinal::text, 2, '0') from seasons s " +
        "where s.starts_at <= greatest(a.created_at, (select min(starts_at) from seasons)) " +
        "order by s.starts_at desc limit 1), '') as joined_season " +
        "from accounts a where lower(a.username) = lower($1)",
        [pg.arg_text(raw_username)], pr_dl());
    guard let rows = r else let e = err_of(r) { return err(e); }
    if len(rows) > 0 {
        let row = rows[0];
        return ok(ports.AccountLookup {
            found: true,
            redirect_username: "",
            account_id: row.id,
            username: row.username,
            avatar_color: row.avatar_color,
            status: row.status,
            created_at_ms: row.created_at_ms,
            joined_season: row.joined_season
        });
    }

    let rh: result[[UsernameHistoryDbRow], str] = zokor.query_all(s.conn,
        "select a.username as current_username " +
        "from username_history uh " +
        "join accounts a on a.id = uh.account_id " +
        "join username_reservations ur on ur.account_id = uh.account_id and lower(ur.username) = lower(uh.old_username) " +
        "where lower(uh.old_username) = lower($1) and ur.reserved_until > now() " +
        "order by uh.changed_at desc limit 1",
        [pg.arg_text(raw_username)], pr_dl());
    guard let h_rows = rh else let e = err_of(rh) { return err(e); }
    if len(h_rows) > 0 {
        return ok(ports.AccountLookup {
            found: true,
            redirect_username: h_rows[0].current_username,
            account_id: "",
            username: "",
            avatar_color: "",
            status: "",
            created_at_ms: 0,
            joined_season: ""
        });
    }

    return ok(ports.AccountLookup {
        found: false,
        redirect_username: "",
        account_id: "",
        username: "",
        avatar_color: "",
        status: "",
        created_at_ms: 0,
        joined_season: ""
    });
}

pub fn load_profile_calls(s: PostgresProfileStore, account_id: str) -> result[[domain.CallItem], str] {
    let q = "select m.slug, m.question, p.outcome as side, " +
        "coalesce(pr.result, 'OPEN') as status, " +
        "case " +
        "  when p.outcome = 'YES' and ms.yes_bid is not null and ms.yes_ask is not null then round((ms.yes_bid + ms.yes_ask) * 50.0 / m.redemption_units)::int " +
        "  when p.outcome = 'NO' and ms.no_bid is not null and ms.no_ask is not null then round((ms.no_bid + ms.no_ask) * 50.0 / m.redemption_units)::int " +
        "  else null " +
        "end as chance_pct " +
        "from positions p " +
        "join markets m on m.id = p.market_id " +
        "left join market_stats ms on ms.market_id = m.id " +
        "left join position_results pr on pr.market_id = p.market_id and pr.account_id = p.account_id " +
        "and pr.season_id = p.season_id and pr.outcome = p.outcome " +
        "where p.account_id = $1::uuid and (p.qty > 0 or pr.id is not null) " +
        "order by p.updated_at desc limit 50";

    let r: result[[ProfileCallDbRow], str] = zokor.query_all(s.conn, q, [pg.arg_text(account_id)], pr_dl());
    guard let rows = r else let e = err_of(r) { return err(e); }

    let calls: [domain.CallItem] = [];
    for row in rows {
        push(calls, domain.CallItem {
            market: domain.MarketSummary {
                slug: row.slug,
                question: row.question
            },
            side: row.side,
            status: row.status,
            chance_pct: row.chance_pct
        });
    }
    return ok(calls);
}

pub fn load_current_stats(s: PostgresProfileStore, account_id: str) -> result[domain.CurrentSeasonStats, str] {
    let q = "select coalesce(ss.rank_profit, 0) as rank, " +
        "(select count(*) from accounts a where a.status = 'ACTIVE' and a.kind = 'USER' and a.leaderboard_eligible = true)::int as of, " +
        "coalesce(ss.profit, 0) as profit, " +
        "coalesce(ss.calls, 0) as calls, " +
        "coalesce(ss.wins, 0) as right_count, " +
        "coalesce(ss.wins + ss.losses, 0) as settled " +
        "from seasons cs " +
        "left join season_standings ss on ss.season_id = cs.id and ss.account_id = $1::uuid " +
        "where cs.status in ('ACTIVE', 'CLOSED') order by cs.ordinal desc limit 1";

    let r: result[[CurrentStatsDbRow], str] = zokor.query_all(s.conn, q, [pg.arg_text(account_id)], pr_dl());
    guard let rows = r else let e = err_of(r) { return err(e); }
    if len(rows) == 0 {
        return ok(domain.CurrentSeasonStats {
            rank: 0,
            of: 0,
            profit: 0,
            calls: 0,
            right: 0,
            settled: 0
        });
    }
    let row = rows[0];
    return ok(domain.CurrentSeasonStats {
        rank: row.rank,
        of: row.of,
        profit: row.profit,
        calls: row.calls,
        right: row.right_count,
        settled: row.settled
    });
}

pub fn profile_store(s: PostgresProfileStore) -> ports.ProfileStore[PostgresProfileStore] {
    return ports.ProfileStore[PostgresProfileStore] {
        context: s,
        find_user: find_user,
        load_profile_calls: load_profile_calls,
        load_current_stats: load_current_stats
    };
}
