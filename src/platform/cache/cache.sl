import "builder";
import "redis";
import "strings";
import "time";
import "zokor";

gc struct MemoryCache {
    lock: mutex,
    data: map[str]str,
    expires: map[str]int
}

fn new_memory_cache() -> MemoryCache {
    let d: map[str]str = {};
    let exp: map[str]int = {};
    return MemoryCache { lock: make_mutex(), data: d, expires: exp };
}

pub gc struct Cache {
    pool: opt[redis.Pool],
    memory: opt[MemoryCache]
}

pub fn open(cfg: zokor.Config) -> result[Cache, str] {
    let r = zokor.redis_from_config(cfg);
    guard let pool = r else let e = err_of(r) {
        return err(e);
    }
    let none_mem: opt[MemoryCache] = none;
    return ok(Cache { pool: some(pool), memory: none_mem });
}

pub fn in_memory() -> Cache {
    let none_pool: opt[redis.Pool] = none;
    return Cache { pool: none_pool, memory: some(new_memory_cache()) };
}

pub fn close(c: Cache) {
    if let p = c.pool {
        zokor.redis_close(p);
    }
}

pub fn ping(c: Cache, d: until) -> result[int, str] {
    if let p = c.pool {
        let cr = redis.acquire(p, d);
        guard let conn = cr else let e = err_of(cr) {
            return err(e);
        }
        let r = redis.ping(conn, d);
        redis.release(p, conn);
        guard let _ok = r else let e = err_of(r) {
            return err(e);
        }
        return ok(0);
    }
    return ok(0);
}

fn deadline(timeout_ns: int) -> until {
    return until_of(time.mono() + timeout_ns);
}

pub fn set_ex(c: Cache, key: str, seconds: int, val: str) -> result[bool, str] {
    if let p = c.pool {
        let d = deadline(2000000000);
        let cr = redis.acquire(p, d);
        guard let conn = cr else let e = err_of(cr) {
            return err(e);
        }
        let val_bytes = builder.new_bytes().write_str(val).finish();
        let r = redis.set_ex(conn, key, seconds, val_bytes, d);
        redis.release(p, conn);
        return r;
    }
    if let m = c.memory {
        mutex_lock(m.lock);
        m.data[key] = val;
        m.expires[key] = time.wall() + seconds * 1000000000;
        mutex_unlock(m.lock);
        return ok(true);
    }
    return err("no cache configured");
}

pub fn get(c: Cache, key: str) -> result[opt[str], str] {
    let none_str: opt[str] = none;
    if let p = c.pool {
        let d = deadline(2000000000);
        let cr = redis.acquire(p, d);
        guard let conn = cr else let e = err_of(cr) {
            return err(e);
        }
        let r = redis.get(conn, key, d);
        redis.release(p, conn);
        guard let opt_bytes = r else let e = err_of(r) {
            return err(e);
        }
        guard let b = opt_bytes else {
            return ok(none_str);
        }
        let s = strings.from_bytes(b, 0, len(b));
        return ok(some(s));
    }
    if let m = c.memory {
        mutex_lock(m.lock);
        let found = none_str;
        if has(m.data, key) {
            let exp = m.expires[key];
            if exp >= time.wall() {
                found = some(m.data[key]);
            }
        }
        mutex_unlock(m.lock);
        return ok(found);
    }
    return err("no cache configured");
}

pub fn delete_key(c: Cache, key: str) -> result[bool, str] {
    if let p = c.pool {
        let d = deadline(2000000000);
        let cr = redis.acquire(p, d);
        guard let conn = cr else let e = err_of(cr) {
            return err(e);
        }
        let r = redis.del_keys(conn, [key], d);
        redis.release(p, conn);
        guard let count = r else let e = err_of(r) {
            return err(e);
        }
        return ok(count > 0);
    }
    if let m = c.memory {
        mutex_lock(m.lock);
        let had = has(m.data, key);
        if had {
            m.expires[key] = 0;
            m.data[key] = "";
        }
        mutex_unlock(m.lock);
        return ok(had);
    }
    return err("no cache configured");
}
