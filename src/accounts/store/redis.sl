import "builder";
import "redis";
import "strings";
import "time";

fn redis_deadline(s: Store) -> until {
    return until_of(time.mono() + s.redis_timeout);
}

fn as_bytes(v: str) -> bytes {
    return builder.new_bytes().write_str(v).finish();
}

fn command(s: Store, args: [str]) -> result[redis.Reply, str] {
    guard let pool = s.redis else {
        return err("redis not configured");
    }
    let d = redis_deadline(s);
    let cr = redis.acquire(pool, d);
    guard let conn = cr else let e = err_of(cr) {
        return err(e);
    }
    let parts: [bytes] = [];
    for a in args {
        push(parts, as_bytes(a));
    }
    let r = redis.do(conn, parts, d);
    redis.release(pool, conn);
    return r;
}

fn bulk_text(r: redis.Reply) -> opt[str] {
    guard let b = r.bulk else {
        return none;
    }
    return some(strings.from_bytes(b, 0, len(b)));
}

fn st_eph_put_nx(s: Store, key: str, val: str, secs: int) -> result[bool, str] {
    let r = command(s, ["SET", key, val, "NX", "EX", to_str(secs)]);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return ok(reply.text == "OK");
}

fn st_eph_put(s: Store, key: str, val: str, secs: int) -> result[bool, str] {
    let r = command(s, ["SET", key, val, "EX", to_str(secs)]);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return ok(reply.text == "OK");
}

fn st_eph_get(s: Store, key: str) -> result[opt[str], str] {
    let r = command(s, ["GET", key]);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return ok(bulk_text(reply));
}

// GETDEL: read and remove in one step, so a state or pending token can be
// used exactly once even when two requests race for it.
fn st_eph_take(s: Store, key: str) -> result[opt[str], str] {
    let r = command(s, ["GETDEL", key]);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return ok(bulk_text(reply));
}

fn st_eph_drop(s: Store, keys: [str]) -> result[int, str] {
    if len(keys) == 0 {
        return ok(0);
    }
    let args: [str] = ["DEL"];
    for k in keys {
        push(args, k);
    }
    let r = command(s, args);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return ok(reply.num);
}

// SET NX EX creates the window with its TTL, INCR counts in it: a crash
// between the two never leaves a counter without an expiry.
fn st_eph_hit(s: Store, key: str, window: int) -> result[int, str] {
    let first = command(s, ["SET", key, "0", "NX", "EX", to_str(window)]);
    guard let _f = first else let e = err_of(first) {
        return err(e);
    }
    let r = command(s, ["INCR", key]);
    guard let reply = r else let e = err_of(r) {
        return err(e);
    }
    return ok(reply.num);
}
