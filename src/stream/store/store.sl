import "json";
import "pg";
import "redis";
import "strings";
import "time";
import "zokor";
import "../domain" as domain;
import "../service" as service;

pub gc struct PostgresRedisStore {
    pg: pg.Pool,
    redis_pool: opt[redis.Pool],
    runtime_views: map[str]str,
    runtime_views_lock: mutex
}

gc struct SessionCheckRow {
    valid: int
}

gc struct MarketStatRow {
    market_id: str,
    last_price: opt[int],
    chance_pct: opt[int],
    yes_ask: opt[int],
    no_ask: opt[int],
    volume_units: opt[int],
    change_24h: opt[int]
}

gc struct JsonBookLevel {
    yes_price: int,
    qty: int
}

gc struct JsonBookView {
    market_id: str,
    owner_epoch: int,
    committed_seq: int,
    book_seq: int,
    last_price: opt[int],
    pending_count: int,
    as_of: int,
    lease_until: int,
    health: str,
    mode: str,
    bids: [JsonBookLevel],
    asks: [JsonBookLevel]
}

fn deadline_of(timeout_ms: int) -> until {
    return until_of(time.mono() + timeout_ms * 1000000);
}

fn parse_stream_entry(key: str, e: redis.StreamEntry) -> service.StreamMessage {
    let eid = "";
    let mid = "";
    let aid = "";
    let aud = "";
    let mseq = 0;
    let ord = 0;
    let epoch = 0;
    let mtype = "";
    let payload = "";

    if has(e.fields, "id") { eid = to_str(e.fields["id"]); }
    if has(e.fields, "market_id") { mid = to_str(e.fields["market_id"]); }
    if has(e.fields, "account_id") { aid = to_str(e.fields["account_id"]); }
    if has(e.fields, "audience") { aud = to_str(e.fields["audience"]); }
    if has(e.fields, "market_seq") { mseq = to_int(to_str(e.fields["market_seq"])) ?? 0; }
    if has(e.fields, "event_ordinal") { ord = to_int(to_str(e.fields["event_ordinal"])) ?? 0; }
    if has(e.fields, "owner_epoch") { epoch = to_int(to_str(e.fields["owner_epoch"])) ?? 0; }
    if has(e.fields, "type") { mtype = to_str(e.fields["type"]); }
    if has(e.fields, "payload") { payload = to_str(e.fields["payload"]); }

    return service.StreamMessage {
        id: e.id,
        stream: key,
        event_id: eid,
        market_id: mid,
        account_id: aid,
        audience: aud,
        market_seq: mseq,
        event_ordinal: ord,
        owner_epoch: epoch,
        msg_type: mtype,
        payload: payload
    };
}

fn store_read_market_stream(s: PostgresRedisStore, market_id: str, last_id: str, count: int, block_ms: int) -> result[[service.StreamMessage], str] {
    let empty: [service.StreamMessage] = [];
    guard let pool = s.redis_pool else {
        return ok(empty);
    }
    let d = deadline_of(block_ms + 2000);
    let cr = redis.acquire(pool, d);
    guard let conn = cr else let e = err_of(cr) {
        return err(e);
    }
    let stream_key = "stream:market:" + market_id;
    let start_id = last_id;
    if start_id == "" {
        start_id = "$";
    }
    let opt_blk = some(block_ms);
    let opt_cnt = some(count);
    let r = redis.xread(conn, [stream_key], [start_id], opt_blk, opt_cnt, d);
    redis.release(pool, conn);

    guard let opt_reads = r else let e = err_of(r) {
        return err(e);
    }
    guard let reads = opt_reads else {
        return ok(empty);
    }
    let out: [service.StreamMessage] = [];
    for sr in reads {
        for entry in sr.entries {
            push(out, parse_stream_entry(sr.key, entry));
        }
    }
    return ok(out);
}

fn store_read_shard_stream(s: PostgresRedisStore, shard: int, last_id: str, count: int, block_ms: int) -> result[[service.StreamMessage], str] {
    let empty: [service.StreamMessage] = [];
    guard let pool = s.redis_pool else {
        return ok(empty);
    }
    let d = deadline_of(block_ms + 2000);
    let cr = redis.acquire(pool, d);
    guard let conn = cr else let e = err_of(cr) {
        return err(e);
    }
    let stream_key = "stream:private:" + to_str(shard);
    let start_id = last_id;
    if start_id == "" {
        start_id = "$";
    }
    let opt_blk = some(block_ms);
    let opt_cnt = some(count);
    let r = redis.xread(conn, [stream_key], [start_id], opt_blk, opt_cnt, d);
    redis.release(pool, conn);

    guard let opt_reads = r else let e = err_of(r) {
        return err(e);
    }
    guard let reads = opt_reads else {
        return ok(empty);
    }
    let out: [service.StreamMessage] = [];
    for sr in reads {
        for entry in sr.entries {
            push(out, parse_stream_entry(sr.key, entry));
        }
    }
    return ok(out);
}

fn store_read_session_revocations(s: PostgresRedisStore, last_id: str, count: int, block_ms: int) -> result[[service.SessionRevocation], str] {
    let empty: [service.SessionRevocation] = [];
    guard let pool = s.redis_pool else {
        return ok(empty);
    }
    let d = deadline_of(block_ms + 2000);
    let cr = redis.acquire(pool, d);
    guard let conn = cr else let e = err_of(cr) {
        return err(e);
    }
    let stream_key = "stream:sessions";
    let start_id = last_id;
    if start_id == "" {
        start_id = "$";
    }
    let opt_blk = some(block_ms);
    let opt_cnt = some(count);
    let r = redis.xread(conn, [stream_key], [start_id], opt_blk, opt_cnt, d);
    redis.release(pool, conn);

    guard let opt_reads = r else let e = err_of(r) {
        return err(e);
    }
    guard let reads = opt_reads else {
        return ok(empty);
    }
    let out: [service.SessionRevocation] = [];
    for sr in reads {
        for entry in sr.entries {
            let sid = "";
            if has(entry.fields, "session_id") {
                sid = to_str(entry.fields["session_id"]);
            }
            if sid != "" {
                push(out, service.SessionRevocation { id: entry.id, session_id: sid });
            }
        }
    }
    return ok(out);
}

fn store_get_book_view(s: PostgresRedisStore, market_id: str) -> result[opt[service.RuntimeBookSnapshot], str] {
    mutex_lock(s.runtime_views_lock);
    let raw: opt[str] = none;
    if has(s.runtime_views, market_id) {
        raw = some(s.runtime_views[market_id]);
    }
    mutex_unlock(s.runtime_views_lock);

    guard let payload = raw else {
        let none_snap: opt[service.RuntimeBookSnapshot] = none;
        return ok(none_snap);
    }

    let decoded: result[JsonBookView, str] = json.decode(payload);
    guard let v = decoded else let e = err_of(decoded) {
        return err("view decode error: " + e);
    }

    let bids: [domain.Level] = [];
    for b in v.bids {
        push(bids, domain.Level { side: "bid", yes_price: b.yes_price, qty: b.qty });
    }
    let asks: [domain.Level] = [];
    for a in v.asks {
        push(asks, domain.Level { side: "ask", yes_price: a.yes_price, qty: a.qty });
    }

    let snap = service.RuntimeBookSnapshot {
        market_id: v.market_id,
        owner_epoch: v.owner_epoch,
        committed_seq: v.committed_seq,
        book_seq: v.book_seq,
        value: 100,
        min_price: 1,
        max_price: 99,
        tick: 1,
        health: v.health,
        mode: v.mode,
        bids: bids,
        asks: asks
    };
    return ok(some(snap));
}

fn store_get_market_stats(s: PostgresRedisStore) -> result[[service.CardStatItem], str] {
    let d = deadline_of(2000);
    let no_args: [pg.Arg] = [];
    let qr: result[[MarketStatRow], str] = zokor.query_all(
        s.pg,
        "select market_id::text as market_id, last_price, chance_pct, yes_ask, no_ask, volume_units, change_24h from market_stats",
        no_args,
        d
    );
    guard let rows = qr else let e = err_of(qr) {
        return err(e);
    }
    let out: [service.CardStatItem] = [];
    for r in rows {
        push(out, service.CardStatItem {
            market_id: r.market_id,
            last_price: r.last_price ?? 0,
            chance_pct: r.chance_pct ?? 50,
            yes_ask: r.yes_ask ?? 0,
            no_ask: r.no_ask ?? 0,
            volume_units: r.volume_units ?? 0,
            change_24h: r.change_24h ?? 0
        });
    }
    return ok(out);
}

fn store_is_session_valid(s: PostgresRedisStore, session_id: str) -> result[bool, str] {
    let d = deadline_of(1000);
    let qr: result[[SessionCheckRow], str] = zokor.query_all(
        s.pg,
        "select 1 as valid from sessions where id = $1::uuid and revoked_at is null and expires_at > now()",
        [pg.arg_text(session_id)],
        d
    );
    guard let rows = qr else let e = err_of(qr) {
        return err(e);
    }
    return ok(len(rows) > 0);
}


pub fn make_stream_store(
    pool: pg.Pool,
    redis_pool: opt[redis.Pool],
    runtime_views: map[str]str,
    runtime_views_lock: mutex
) -> service.StreamStore[PostgresRedisStore] {
    let s = PostgresRedisStore {
        pg: pool,
        redis_pool: redis_pool,
        runtime_views: runtime_views,
        runtime_views_lock: runtime_views_lock
    };
    return service.StreamStore[PostgresRedisStore] {
        context: s,
        read_market_stream: store_read_market_stream,
        read_shard_stream: store_read_shard_stream,
        read_session_revocations: store_read_session_revocations,
        get_book_view: store_get_book_view,
        get_market_stats: store_get_market_stats,
        is_session_valid: store_is_session_valid
    };
}
