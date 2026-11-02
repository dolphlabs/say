import "pg";
import "redis";
import "../domain" as domain;
import "../service" as service;

fn test_parse_stream_entry() {
    let fields: map[str]bytes = {
        "id": to_bytes("evt_100"),
        "market_id": to_bytes("m_1"),
        "account_id": to_bytes("acc_1"),
        "market_seq": to_bytes("105"),
        "owner_epoch": to_bytes("2"),
        "type": to_bytes("book.delta"),
        "payload": to_bytes("{\"levels\":[]}")
    };
    let entry = redis.StreamEntry { id: "1000-0", fields: fields };
    let parsed = parse_stream_entry("stream:market:m_1", entry);
    assert(parsed.id == "1000-0");
    assert(parsed.event_id == "evt_100");
    assert(parsed.market_id == "m_1");
    assert(parsed.account_id == "acc_1");
    assert(parsed.market_seq == 105);
    assert(parsed.owner_epoch == 2);
    assert(parsed.msg_type == "book.delta");
}

fn test_store_creation() {
    let pool_res = pg.new_pool("postgres://say:say@127.0.0.1:55432/say_test?sslmode=disable", 1);
    guard let pool = pool_res else {
        panic("pool creation failed");
    }
    let views: map[str]str = {};
    let lock = make_mutex();
    let opt_redis: opt[redis.Pool] = none;
    let s = make_stream_store(pool, opt_redis, views, lock);
    assert(len(s.context.runtime_views) == 0);
}
