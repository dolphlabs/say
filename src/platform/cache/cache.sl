import "redis";
import "zokor";

pub gc struct Cache {
    pool: redis.Pool
}

pub fn open(cfg: zokor.Config) -> result[Cache, str] {
    let r = zokor.redis_from_config(cfg);
    guard let pool = r else let e = err_of(r) {
        return err(e);
    }
    return ok(Cache { pool: pool });
}

pub fn close(c: Cache) {
    zokor.redis_close(c.pool);
}

pub fn pool(c: Cache) -> redis.Pool {
    return c.pool;
}

pub fn ping(c: Cache, deadline: until) -> result[int, str] {
    let cr = redis.acquire(c.pool, deadline);
    guard let conn = cr else let e = err_of(cr) {
        return err(e);
    }
    let r = redis.ping(conn, deadline);
    redis.release(c.pool, conn);
    guard let _ok = r else let e = err_of(r) {
        return err(e);
    }
    return ok(0);
}
