import "pg";
import "time";
import "timez";
import "zokor";
import "../domain" as domain;
import "../service" as service;

pub fn no_grant() -> opt[domain.Grant] {
    let g: opt[domain.Grant] = none;
    return g;
}

pub gc struct Postgres {
    pool: pg.Pool,
    timeout: int
}

pub fn on_postgres(pool: pg.Pool, timeout_ns: int) -> service.SeasonStore[Postgres] {
    return service.SeasonStore[Postgres] {
        context: Postgres { pool: pool, timeout: timeout_ns },
        current: pg_current
    };
}

gc struct SeasonRow {
    id: str,
    ordinal: int,
    starts_at: timez.Time,
    ends_at: timez.Time,
    status: str
}

fn to_season(r: SeasonRow) -> domain.Season {
    return domain.Season { id: r.id, ordinal: r.ordinal, starts_at: r.starts_at, ends_at: r.ends_at, status: r.status };
}

fn current_sql() -> str {
    return "select id::text as id, ordinal, starts_at, ends_at, status from seasons " +
           "where status = 'ACTIVE' and starts_at <= now() and ends_at > now() " +
           "order by starts_at desc limit 1";
}

fn pg_current(p: Postgres) -> result[opt[domain.Season], str] {
    let none_args: [pg.Arg] = [];
    let r: result[opt[SeasonRow], str] = zokor.query_one(p.pool, current_sql(), none_args,
                                                         until_of(time.mono() + p.timeout));
    guard let found = r else let e = err_of(r) {
        return err(e);
    }
    let none_season: opt[domain.Season] = none;
    guard let row = found else {
        return ok(none_season);
    }
    return ok(some(to_season(row)));
}

gc struct IdRow {
    id: str
}

gc struct GrantRow {
    amount: int
}

// Posts the S `amount` signup grant on `c`, inside the caller's
// transaction, so it commits or rolls back with the verification that
// earned it. none when no season is active.
//
// Wallets are locked user-first then issuance, the same order every grant
// takes, so concurrent grants queue rather than deadlock. The issuance
// wallet is one hot row: every grant in a season serialises on it.
pub fn post_signup_grant(c: pg.Conn, account_id: str, amount: int, deadline: until) -> result[opt[domain.Grant], str] {
    let none_grant: opt[domain.Grant] = none;
    if let problem = domain.grant_problem(amount) {
        return err(problem);
    }
    let none_args: [pg.Arg] = [];
    let sr: result[[SeasonRow], str] = zokor.conn_query_all(c, current_sql(), none_args, deadline);
    guard let seasons = sr else let e = err_of(sr) {
        return err(e);
    }
    if len(seasons) == 0 {
        // TODO(season-rollover): the season job grants eligible accounts
        // verified while no season was active.
        return ok(none_grant);
    }
    let season = seasons[0];
    let issuer = domain.issuance_account_id();
    let key = domain.grant_business_key(season.id, account_id);

    let existing: result[[GrantRow], str] = zokor.conn_query_all(c,
        "select amount from issuance_grants where account_id = $1 and season_id = $2",
        [pg.arg_text(account_id), pg.arg_text(season.id)], deadline);
    guard let had = existing else let e = err_of(existing) {
        return err(e);
    }
    if len(had) > 0 {
        return ok(some(domain.Grant { amount: had[0].amount, season_ordinal: season.ordinal, season_ends_at: season.ends_at }));
    }

    for w in [[account_id, "false"], [issuer, "true"]] {
        let ins = pg.query(c,
            "insert into wallets (account_id, season_id, asset_key, allow_negative) " +
            "values ($1, $2, $3, $4::boolean) on conflict (account_id, season_id, asset_key) do nothing",
            [pg.arg_text(w[0]), pg.arg_text(season.id), pg.arg_text(domain.sedi()), pg.arg_text(w[1])], deadline);
        guard let _i = ins else let e = err_of(ins) {
            return err(e);
        }
    }

    let tr: result[[IdRow], str] = zokor.conn_query_all(c,
        "insert into ledger_transactions (business_key, kind, season_id) values ($1, 'ISSUANCE_GRANT', $2) " +
        "returning id::text as id",
        [pg.arg_text(key), pg.arg_text(season.id)], deadline);
    guard let txs = tr else let e = err_of(tr) {
        return err(e);
    }
    if len(txs) != 1 {
        return err("ledger transaction not created");
    }
    let tx_id = txs[0].id;

    for leg in [[account_id, to_str(amount)], [issuer, to_str(0 - amount)]] {
        let moved: result[[IdRow], str] = zokor.conn_query_all(c,
            "update wallets set free_units = free_units + $3::bigint " +
            "where account_id = $1 and season_id = $2 and asset_key = $4 returning id::text as id",
            [pg.arg_text(leg[0]), pg.arg_text(season.id), pg.arg_text(leg[1]), pg.arg_text(domain.sedi())], deadline);
        guard let wallets = moved else let e = err_of(moved) {
            return err(e);
        }
        if len(wallets) != 1 {
            return err("wallet missing for grant leg");
        }
        let entry = pg.query(c,
            "insert into ledger_entries (transaction_id, wallet_id, asset_key, delta_units) values ($1, $2, $3, $4::bigint)",
            [pg.arg_text(tx_id), pg.arg_text(wallets[0].id), pg.arg_text(domain.sedi()), pg.arg_text(leg[1])], deadline);
        guard let _e = entry else let e = err_of(entry) {
            return err(e);
        }
    }

    let g = pg.query(c,
        "insert into issuance_grants (account_id, season_id, amount, journal_id) values ($1, $2, $3, $4)",
        [pg.arg_text(account_id), pg.arg_text(season.id), pg.arg_int(amount), pg.arg_text(tx_id)], deadline);
    guard let _g = g else let e = err_of(g) {
        return err(e);
    }
    return ok(some(domain.Grant { amount: amount, season_ordinal: season.ordinal, season_ends_at: season.ends_at }));
}
