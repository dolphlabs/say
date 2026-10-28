import "pg";
import "zokor";
import "../domain" as domain;
import "../service/ports" as ports;

pub gc struct PostgresProfileStore {
    conn: pg.Pool
}

pub fn new_store(pool: pg.Pool) -> PostgresProfileStore {
    return PostgresProfileStore { conn: pool };
}

pub fn find_user(s: PostgresProfileStore, raw_username: str) -> result[ports.AccountLookup, str] {
    let r = zokor.pool_query_all(s.conn,
        "select id::text, username, coalesce(avatar_color, '#e91e63') as avatar_color, status, " +
        "(extract(epoch from created_at)*1000)::bigint as created_at_ms " +
        "from accounts where lower(username) = lower($1)",
        [pg.arg_text(raw_username)], until_max());
    guard let rows = r else let e = err_of(r) { return err(e); }
    if len(rows) > 0 {
        let row = rows[0];
        return ok(ports.AccountLookup {
            found: true,
            redirect_username: "",
            account_id: row.get_str("id"),
            username: row.get_str("username"),
            avatar_color: row.get_str("avatar_color"),
            status: row.get_str("status"),
            created_at_ms: row.get_int("created_at_ms")
        });
    }

    let rh = zokor.pool_query_all(s.conn,
        "select a.username as current_username " +
        "from username_history uh " +
        "join accounts a on a.id = uh.account_id " +
        "join username_reservations ur on ur.account_id = uh.account_id and lower(ur.username) = lower(uh.old_username) " +
        "where lower(uh.old_username) = lower($1) and ur.reserved_until > now() " +
        "order by uh.changed_at desc limit 1",
        [pg.arg_text(raw_username)], until_max());
    guard let h_rows = rh else let e = err_of(rh) { return err(e); }
    if len(h_rows) > 0 {
        return ok(ports.AccountLookup {
            found: true,
            redirect_username: h_rows[0].get_str("current_username"),
            account_id: "",
            username: "",
            avatar_color: "",
            status: "",
            created_at_ms: 0
        });
    }

    return ok(ports.AccountLookup {
        found: false,
        redirect_username: "",
        account_id: "",
        username: "",
        avatar_color: "",
        status: "",
        created_at_ms: 0
    });
}

pub fn load_profile_calls(s: PostgresProfileStore, account_id: str) -> result[[domain.CallItem], str] {
    let q = "select m.slug, m.question, p.outcome as side, " +
        "case " +
        "  when m.status in ('RESOLVED', 'FINALIZED') and pr.payout_units > pr.cost_units then 'WON' " +
        "  when m.status in ('RESOLVED', 'FINALIZED') and pr.payout_units < pr.cost_units then 'LOST' " +
        "  when m.status = 'VOIDED' then 'VOIDED' " +
        "  else 'OPEN' " +
        "end as status, " +
        "case " +
        "  when p.outcome = 'YES' and ms.yes_bid is not null and ms.yes_ask is not null then ((ms.yes_bid + ms.yes_ask) / 2)::int " +
        "  when p.outcome = 'NO' and ms.no_bid is not null and ms.no_ask is not null then ((ms.no_bid + ms.no_ask) / 2)::int " +
        "  else null " +
        "end as chance_pct " +
        "from positions p " +
        "join markets m on m.id = p.market_id " +
        "left join market_stats ms on ms.market_id = m.id " +
        "left join position_results pr on pr.market_id = p.market_id and pr.account_id = p.account_id " +
        "where p.account_id = $1::uuid and (p.total_shares > 0 or pr.id is not null) " +
        "order by p.updated_at desc limit 50";

    let r = zokor.pool_query_all(s.conn, q, [pg.arg_text(account_id)], until_max());
    guard let rows = r else let e = err_of(r) { return err(e); }

    let calls: [domain.CallItem] = [];
    for row in rows {
        let chance_int = row.get_int("chance_pct");
        let opt_chance: opt[int] = none;
        if chance_int > 0 {
            opt_chance = some(chance_int);
        }
        push(calls, domain.CallItem {
            market: domain.MarketSummary {
                slug: row.get_str("slug"),
                question: row.get_str("question")
            },
            side: row.get_str("side"),
            status: row.get_str("status"),
            chance_pct: opt_chance
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

    let r = zokor.pool_query_all(s.conn, q, [pg.arg_text(account_id)], until_max());
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
        rank: row.get_int("rank"),
        of: row.get_int("of"),
        profit: row.get_int("profit"),
        calls: row.get_int("calls"),
        right: row.get_int("right_count"),
        settled: row.get_int("settled")
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
