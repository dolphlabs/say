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

// Appends one entry to a Redis stream, trimmed to about `max_len` entries.
// The in-memory cache keeps the last entry per id, for tests.
pub fn xadd(c: Cache, stream: str, max_len: int, fields: [str]) -> result[bool, str] {
    if let p = c.pool {
        let d = deadline(2000000000);
        let cr = redis.acquire(p, d);
        guard let conn = cr else let e = err_of(cr) {
            return err(e);
        }
        let args: [bytes] = [to_bytes("XADD"), to_bytes(stream), to_bytes("MAXLEN"), to_bytes("~"),
                             to_bytes(to_str(max_len)), to_bytes("*")];
        for f in fields {
            push(args, to_bytes(f));
        }
        let r = redis.do(conn, args, d);
        redis.release(p, conn);
        guard let _reply = r else let e = err_of(r) {
            return err(e);
        }
        return ok(true);
    }
    if let m = c.memory {
        mutex_lock(m.lock);
        let key = stream;
        for i in 0..len(fields) {
            if fields[i] == "id" && i + 1 < len(fields) {
                key = stream + ":" + fields[i + 1];
            }
        }
        m.data[key] = strings.join(fields, "\n");
        m.expires[key] = time.wall() + 3600000000000;
        mutex_unlock(m.lock);
        return ok(true);
    }
    return err("no cache configured");
}

pub fn xadd_ordered(c: Cache, stream: str, market_id: str, max_len: int, seq: int,
                    ordinal: int, fields: [str]) -> result[bool, str] {
    if len(stream)==0 || len(market_id)!=36 || max_len<1 || seq<1 || ordinal<0 {
        return err("invalid ordered stream event");
    }
    if let p=c.pool {
        let d=deadline(2000000000);
        let acquired=redis.acquire(p,d);
        guard let conn=acquired else let e=err_of(acquired) { return err(e); }
        let script="local function norm(v) " +
            "v=string.gsub(v,'^0+',''); if v=='' then return '0' end; return v end " +
            "local function cmp(a,b) a=norm(a); b=norm(b); " +
            "if string.len(a)<string.len(b) then return -1 end; " +
            "if string.len(a)>string.len(b) then return 1 end; " +
            "if a<b then return -1 end; if a>b then return 1 end; return 0 end " +
            "local current=redis.call('GET',KEYS[1]); " +
            "if current then local split=string.find(current,':'); " +
            "local cs=string.sub(current,1,split-1); local co=string.sub(current,split+1); " +
            "local sc=cmp(ARGV[1],cs); if sc<0 or (sc==0 and cmp(ARGV[2],co)<=0) then return 0 end end " +
            "redis.call('XADD',KEYS[2],'MAXLEN','~',ARGV[3],'*',unpack(ARGV,4)); " +
            "redis.call('SET',KEYS[1],ARGV[1]..':'..ARGV[2]); return 1";
        let args:[bytes]=[to_bytes("EVAL"),to_bytes(script),to_bytes("2"),
            to_bytes(stream+":cursor:"+market_id),to_bytes(stream),
            to_bytes(to_str(seq)),to_bytes(to_str(ordinal)),to_bytes(to_str(max_len))];
        for field in fields { push(args,to_bytes(field)); }
        let response=redis.do(conn,args,d);
        redis.release(p,conn);
        guard let _reply=response else let e=err_of(response) { return err(e); }
        return ok(true);
    }
    if let m=c.memory {
        mutex_lock(m.lock);
        let cursor_key=stream+":cursor:"+market_id;
        let event_key=stream+":"+market_id+":"+to_str(seq)+":"+to_str(ordinal);
        let write=true;
        if has(m.data,cursor_key) {
            let old=strings.split(m.data[cursor_key],":");
            if len(old)==2 {
                let old_seq=to_int(old[0]) ?? 0;
                let old_ordinal=to_int(old[1]) ?? -1;
                if seq<old_seq || (seq==old_seq && ordinal<=old_ordinal) { write=false; }
            }
        }
        if write {
            m.data[event_key]=strings.join(fields,"\n");
            m.expires[event_key]=time.wall()+3600000000000;
            m.data[cursor_key]=to_str(seq)+":"+to_str(ordinal);
            m.expires[cursor_key]=time.wall()+3600000000000;
        }
        mutex_unlock(m.lock);
        return ok(true);
    }
    return err("no cache configured");
}
