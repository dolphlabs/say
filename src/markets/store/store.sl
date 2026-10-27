import "pg";
import "time";
import "timez";
import "zokor";
import "../domain" as domain;
import "../service" as service;
import "../../ledger/store" as ledger_store;

pub gc struct Store { pool: pg.Pool, timeout: int, coordinator: ledger_store.Postgres, zone: timez.Zone }

pub fn on_postgres(pool: pg.Pool, timeout: int, coordinator: ledger_store.Postgres, zone: timez.Zone) -> service.MarketStore[Store] {
    return service.MarketStore[Store] { context: Store { pool: pool, timeout: timeout, coordinator: coordinator, zone: zone },
        mutate: mutate, find: find, snapshot: read_snapshot, due: due, history: history, source_create: source_create,
        lease_try: lease_try, lease_release: lease_release, validate: validate };
}

fn deadline(s: Store) -> until { return until_of(time.mono() + s.timeout); }


fn timestamp(ms: int) -> zokor.Json {
    if ms == 0 { return zokor.jnull(); }
    return zokor.jstr(timez.unix(ms / 1000).add((ms % 1000) * 1000000).rfc3339_milli());
}

fn document(m: domain.Market) -> zokor.Json {
    let j = zokor.jobj();
    j.set_str("id", m.id);
    j.set_str("slug", m.slug);
    if len(m.question) == 0 { j.set("question", zokor.jnull()); } else { j.set_str("question", m.question); }
    if len(m.category_id) == 0 { j.set("category_id", zokor.jnull()); } else { j.set_str("category_id", m.category_id); }
    if len(m.season_id) == 0 { j.set("season_id", zokor.jnull()); } else { j.set_str("season_id", m.season_id); }
    if len(m.resolution_source_id) == 0 { j.set("resolution_source_id", zokor.jnull()); } else { j.set_str("resolution_source_id", m.resolution_source_id); }
    j.set("open_at", timestamp(m.open_at));
    j.set("close_at", timestamp(m.close_at));
    j.set("resolve_by", timestamp(m.resolve_by));
    if m.redemption_units == 0 { j.set("redemption_units", zokor.jnull()); } else { j.set_int("redemption_units", m.redemption_units); }
    if m.min_price == 0 { j.set("min_price", zokor.jnull()); } else { j.set_int("min_price", m.min_price); }
    if m.max_price == 0 { j.set("max_price", zokor.jnull()); } else { j.set_int("max_price", m.max_price); }
    j.set_int("tick", m.tick);
    j.set_int("max_order_qty", m.max_order_qty);
    j.set_int("fee_units", m.fee_units);
    j.set_int("min_order_notional", m.min_order_notional);
    if m.liquidity_request == 0 { j.set("liquidity_request", zokor.jnull()); } else { j.set_int("liquidity_request", m.liquidity_request); }
    if m.featured_rank == 0 { j.set("featured_rank", zokor.jnull()); } else { j.set_int("featured_rank", m.featured_rank); }
    if m.opening_price == 0 { j.set("opening_price", zokor.jnull()); } else { j.set_int("opening_price", m.opening_price); }
    j.set_str("status", m.status);
    j.set_int("version", m.version);
    j.set_int("terms_version", m.terms_version);
    if len(m.terms_hash) == 0 { j.set("terms_hash", zokor.jnull()); } else { j.set_str("terms_hash", m.terms_hash); }
    j.set_str("created_by", m.created_by);
    if len(m.submitted_by) == 0 { j.set("submitted_by", zokor.jnull()); } else { j.set_str("submitted_by", m.submitted_by); }
    if len(m.approved_by) == 0 { j.set("approved_by", zokor.jnull()); } else { j.set_str("approved_by", m.approved_by); }
    j.set("created_at", timestamp(m.created_at));
    j.set("updated_at", timestamp(m.updated_at));
    j.set("opened_at", timestamp(m.opened_at));
    j.set("closed_at", timestamp(m.closed_at));
    j.set("suspended_at", timestamp(m.suspended_at));
    if len(m.suspend_reason) == 0 { j.set("suspend_reason", zokor.jnull()); } else { j.set_str("suspend_reason", m.suspend_reason); }
    if len(m.status_note) == 0 { j.set("status_note", zokor.jnull()); } else { j.set_str("status_note", m.status_note); }
    j.set("rules", zokor.jobj().set_str("yes_if", m.yes_if).set_str("no_if", m.no_if).set_str("edge_cases", m.edge_cases));
    return j;
}

gc struct IdRow { id: str }

fn save(c: pg.Conn, m: domain.Market, create: bool, expected: int, d: until) -> result[bool, str] {
    let args = [pg.arg_text(document(m).render()), pg.arg_text(m.id), pg.arg_int(expected)];
    let sql = "update markets m set slug=r.slug, question=r.question, category_id=r.category_id, season_id=r.season_id, resolution_source_id=r.resolution_source_id, open_at=r.open_at, close_at=r.close_at, resolve_by=r.resolve_by, redemption_units=r.redemption_units, min_price=r.min_price, max_price=r.max_price, tick=r.tick, max_order_qty=r.max_order_qty, fee_units=r.fee_units, min_order_notional=r.min_order_notional, liquidity_request=r.liquidity_request, featured_rank=r.featured_rank, opening_price=r.opening_price, status=r.status, version=r.version, terms_version=r.terms_version, terms_hash=r.terms_hash, submitted_by=r.submitted_by, approved_by=r.approved_by, updated_at=r.updated_at, opened_at=r.opened_at, closed_at=r.closed_at, suspended_at=r.suspended_at, suspend_reason=r.suspend_reason, status_note=r.status_note, rules=r.rules from jsonb_populate_record(null::markets,$1::jsonb) r where m.id=$2::uuid and m.version=$3 returning m.id::text as id";
    if create {
        sql = "insert into markets (id, slug, question, category_id, season_id, resolution_source_id, open_at, close_at, resolve_by, redemption_units, min_price, max_price, tick, max_order_qty, fee_units, min_order_notional, liquidity_request, featured_rank, opening_price, status, version, terms_version, terms_hash, created_by, submitted_by, approved_by, created_at, updated_at, opened_at, closed_at, suspended_at, suspend_reason, status_note, rules) select r.id, r.slug, r.question, r.category_id, r.season_id, r.resolution_source_id, r.open_at, r.close_at, r.resolve_by, r.redemption_units, r.min_price, r.max_price, r.tick, r.max_order_qty, r.fee_units, r.min_order_notional, r.liquidity_request, r.featured_rank, r.opening_price, r.status, r.version, r.terms_version, r.terms_hash, r.created_by, r.submitted_by, r.approved_by, r.created_at, r.updated_at, r.opened_at, r.closed_at, r.suspended_at, r.suspend_reason, r.status_note, r.rules from jsonb_populate_record(null::markets,$1::jsonb) r where r.id=$2::uuid and $3::bigint=0 returning id::text as id";
    }
    let r: result[[IdRow], str] = zokor.conn_query_all(c, sql, args, d);
    guard let rows = r else let e = err_of(r) { return err(e); }
    return ok(len(rows) == 1);
}
