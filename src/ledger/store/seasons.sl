import "pg";
import "time";
import "timez";
import "zokor";
import "../domain" as domain;
import "../service" as service;

gc struct SeasonRow {
    id: str,
    ordinal: int,
    starts_at: timez.Time,
    ends_at: timez.Time,
    status: str
}

gc struct CountRow {
    n: int
}

gc struct SeasonIdRow {
    season_id: str
}

fn to_season(r: SeasonRow) -> domain.Season {
    return domain.Season { id: r.id, ordinal: r.ordinal, starts_at: r.starts_at, ends_at: r.ends_at, status: r.status };
}

fn seasons_of(rows: [SeasonRow]) -> [domain.Season] {
    let out: [domain.Season] = [];
    for r in rows {
        push(out, to_season(r));
    }
    return out;
}

fn one_season(p: Postgres, sql: str, args: [pg.Arg]) -> result[opt[domain.Season], str] {
    let r: result[opt[SeasonRow], str] = zokor.query_one(p.pool, sql, args, deadline(p));
    guard let found = r else let e = err_of(r) {
        return err(e);
    }
    let none_season: opt[domain.Season] = none;
    guard let row = found else {
        return ok(none_season);
    }
    return ok(some(to_season(row)));
}

fn st_current(p: Postgres) -> result[opt[domain.Season], str] {
    let none_args: [pg.Arg] = [];
    return one_season(p,
        "select id::text as id, ordinal, starts_at, ends_at, status from seasons where status = 'ACTIVE'", none_args);
}

fn st_by_ordinal(p: Postgres, ordinal: int) -> result[opt[domain.Season], str] {
    return one_season(p,
        "select id::text as id, ordinal, starts_at, ends_at, status from seasons where ordinal = $1",
        [pg.arg_int(ordinal)]);
}

fn open_seasons_on(c: pg.Conn, d: until) -> result[[domain.Season], str] {
    let none_args: [pg.Arg] = [];
    let r: result[[SeasonRow], str] = zokor.conn_query_all(c,
        "select id::text as id, ordinal, starts_at, ends_at, status from seasons " +
        "where status <> 'FINALIZED' order by ordinal", none_args, d);
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(seasons_of(rows));
}

fn st_open_seasons(p: Postgres) -> result[[domain.Season], str] {
    let none_args: [pg.Arg] = [];
    let r: result[[SeasonRow], str] = zokor.query_all(p.pool,
        "select id::text as id, ordinal, starts_at, ends_at, status from seasons " +
        "where status <> 'FINALIZED' order by ordinal", none_args, deadline(p));
    guard let rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(seasons_of(rows));
}

pub fn emit(c: pg.Conn, kind: str, payload: zokor.Json, d: until) -> result[int, str] {
    return exec(c, "insert into outbox_events (type, payload) values ($1, $2::jsonb)",
                [pg.arg_text(kind), pg.arg_text(payload.render())], d);
}

fn season_event(s: domain.Season, status: str) -> zokor.Json {
    return zokor.jobj().set_str("season_id", s.id).set_int("ordinal", s.ordinal).set_str("status", status)
        .set_str("starts_at", s.starts_at.rfc3339()).set_str("ends_at", s.ends_at.rfc3339());
}

// Settlement arrives in prompt 08; until then no season can finalize.
pub fn settlement_complete(season_id: str) -> opt[str] {
    return some("market settlement arrives in prompt 08");
}

fn system_wallets(c: pg.Conn, season_id: str, d: until) -> result[int, str] {
    let owners: [str] = [domain.issuance().id, domain.fees().id, domain.treasury().id];
    return exec(c,
        "insert into wallets (season_id, owner_kind, owner_id, asset_key) " +
        "select $1::uuid, 'system', o, 'SEDI' from unnest($2::text[]) as o " +
        "on conflict (season_id, owner_id, asset_key) do nothing",
        [pg.arg_text(season_id), pg.arg_text(text_array(owners))], d);
}

pub fn open_market_wallets(c: pg.Conn, season_id: str, market_id: str, d: until) -> result[int, str] {
    let owners: [str] = [domain.collateral(market_id).id, domain.shares(market_id).id, domain.shares(market_id).id];
    let assets: [str] = [domain.sedi(), domain.yes_asset(market_id), domain.no_asset(market_id)];
    return exec(c,
        "insert into wallets (season_id, owner_kind, owner_id, asset_key) " +
        "select $1::uuid, 'system', v.o, v.a from unnest($2::text[], $3::text[]) as v(o, a) " +
        "on conflict (season_id, owner_id, asset_key) do nothing",
        [pg.arg_text(season_id), pg.arg_text(text_array(owners)), pg.arg_text(text_array(assets))], d);
}

gc struct TickArg {
    now: timez.Time,
    anchor: timez.Time,
    timeout: int
}

fn activate(c: pg.Conn, s: domain.Season, now: timez.Time, d: until) -> result[int, str] {
    let wr = system_wallets(c, s.id, d);
    guard let _w = wr else let e = err_of(wr) {
        return err(e);
    }
    let br = seed_budget_if_approved(c, s.id, d);
    guard let _b = br else let e = err_of(br) {
        return err(e);
    }
    // Only the season that is live now gets a rollover; one missed while
    // the service was down is history (DESIGN.md D4).
    if domain.contains(s, now) {
        let gr = exec(c, "insert into grant_runs (season_id) values ($1::uuid) on conflict (season_id) do nothing",
                      [pg.arg_text(s.id)], d);
        guard let _g = gr else let e = err_of(gr) {
            return err(e);
        }
    }
    return emit(c, "season.started", season_event(s, domain.active()), d);
}

fn tick_tx(c: pg.Conn, t: TickArg) -> result[service.TickReport, str] {
    let d = until_of(time.mono() + t.timeout);
    let none_args: [pg.Arg] = [];
    let tz = exec(c, "set local timezone to 'UTC'", none_args, d);
    guard let _tz = tz else let e = err_of(tz) {
        return err(e);
    }
    let mr: result[[CountRow], str] = zokor.conn_query_all(c,
        "select count(*)::bigint as n from seasons " +
        "where starts_at <> $1::timestamptz + make_interval(secs => (ordinal - 1) * 1209600)",
        [pg.arg_time(t.anchor)], d);
    guard let mismatched = mr else let e = err_of(mr) {
        return err(e);
    }
    if mismatched[0].n > 0 {
        return err("seasons in the database disagree with SEASON_ANCHOR " + t.anchor.rfc3339() + "; refusing to schedule");
    }

    let target = domain.ordinal_at(t.anchor, t.now) + 1;
    let xr: result[[CountRow], str] = zokor.conn_query_all(c, "select coalesce(max(ordinal), 0)::bigint as n from seasons",
                                                           none_args, d);
    guard let maxes = xr else let e = err_of(xr) {
        return err(e);
    }
    for o in (maxes[0].n + 1)..(target + 1) {
        let ir = exec(c,
            "insert into seasons (ordinal, starts_at, ends_at, status) values ($1, $2, $3, 'SCHEDULED') " +
            "on conflict (ordinal) do nothing",
            [pg.arg_int(o), pg.arg_time(domain.starts_at(t.anchor, o)), pg.arg_time(domain.ends_at(t.anchor, o))], d);
        guard let _i = ir else let e = err_of(ir) {
            return err(e);
        }
    }

    let sr = open_seasons_on(c, d);
    guard let seasons = sr else let e = err_of(sr) {
        return err(e);
    }
    let applied: [domain.Step] = [];
    for step in domain.time_steps(seasons, t.now) {
        let sql = "update seasons set status = $3 where id = $1::uuid and status = $2 and $4::timestamptz is not null returning ordinal as n";
        if step.to == domain.active() {
            sql = "update seasons set status = $3, activated_at = $4 where id = $1::uuid and status = $2 returning ordinal as n";
        }
        let ur: result[[CountRow], str] = zokor.conn_query_all(c, sql,
            [pg.arg_text(step.season_id), pg.arg_text(step.from), pg.arg_text(step.to), pg.arg_time(t.now)], d);
        guard let updated = ur else let e = err_of(ur) {
            return err(e);
        }
        if len(updated) == 0 {
            continue;
        }
        push(applied, step);
        for s in seasons {
            if s.id != step.season_id {
                continue;
            }
            let er: result[int, str] = ok(0);
            if step.to == domain.active() {
                er = activate(c, s, t.now, d);
            } else {
                er = emit(c, "season.closing", season_event(s, domain.closing()), d);
            }
            guard let _e = er else let e = err_of(er) {
                return err(e);
            }
        }
    }

    let closed: [int] = [];
    let cr: result[[SeasonRow], str] = zokor.conn_query_all(c,
        "update seasons s set status = 'CLOSED', closed_at = $1 where s.status = 'CLOSING' " +
        "and not exists (select 1 from holds h where h.season_id = s.id and h.status = 'open') " +
        "returning s.id::text as id, s.ordinal, s.starts_at, s.ends_at, s.status",
        [pg.arg_time(t.now)], d);
    guard let closings = cr else let e = err_of(cr) {
        return err(e);
    }
    for row in closings {
        push(closed, row.ordinal);
        let er = emit(c, "season.closed", season_event(to_season(row), domain.closed()), d);
        guard let _e = er else let e = err_of(er) {
            return err(e);
        }
    }

    let gr: result[[SeasonIdRow], str] = zokor.conn_query_all(c,
        "select g.season_id::text as season_id from grant_runs g join seasons s on s.id = g.season_id " +
        "where s.status = 'ACTIVE' and g.finished_at is null", none_args, d);
    guard let runs = gr else let e = err_of(gr) {
        return err(e);
    }
    let rollover = "";
    if len(runs) > 0 {
        rollover = runs[0].season_id;
    }
    let problems: [str] = [];
    return ok(service.TickReport { steps: applied, closed: closed, rollover: rollover, problems: problems });
}

// Applies every overdue transition in one transaction. The caller holds
// the seasons lease, and every step is a compare-and-set, so running it
// twice changes nothing.
fn st_tick(p: Postgres, now: timez.Time, anchor: timez.Time) -> result[service.TickReport, str] {
    return zokor.transaction(p.pool, TickArg { now: now, anchor: anchor, timeout: p.timeout }, tick_tx,
                             until_of(time.mono() + p.timeout));
}
