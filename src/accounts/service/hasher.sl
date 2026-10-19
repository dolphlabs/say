import "argon";

gc struct HashJob {
    verify: bool,
    password: str,
    encoded: str,
    reply: chan[HashOut]
}

gc struct HashOut {
    ok: bool,
    hash: str,
    matched: bool,
    error: str
}

pub enum HashFail {
    Busy,
    Failed
}

// A fixed set of hasher tasks fed by a bounded queue. A hash costs tens of
// milliseconds and ~19 MiB, so the pool caps both; when the queue is full
// the caller gets Busy (503 + retry_after) instead of joining an unbounded
// line. Hash and verify are function values so tests can stub the cost.
pub gc struct Hasher {
    jobs: chan[HashJob],
    hash: fn(str) -> result[str, str],
    verify: fn(str, str) -> result[bool, str]
}

pub fn argon_hash(password: str) -> result[str, str] {
    return argon.hash(password);
}

pub fn argon_verify(password: str, encoded: str) -> result[bool, str] {
    return argon.verify(password, encoded);
}

pub fn argon_needs_rehash(encoded: str) -> bool {
    return argon.needs_rehash(encoded, argon.default_params()) ?? true;
}

pub fn password_algo() -> str {
    return "argon2id";
}

pub fn password_params() -> str {
    let p = argon.default_params();
    return "m=" + to_str(p.memory_kib) + ",t=" + to_str(p.iterations) + ",p=" + to_str(p.parallelism);
}

pub fn new_hasher(workers: int, queue: int, hash: fn(str) -> result[str, str],
                  verify: fn(str, str) -> result[bool, str]) -> Hasher {
    let n = workers;
    if n < 1 {
        n = 1;
    }
    let q = queue;
    if q < 1 {
        q = 1;
    }
    let h = Hasher { jobs: make_chan(q), hash: hash, verify: verify };
    for i in 0..n {
        spawn hash_worker(h);
    }
    return h;
}

fn hash_worker(h: Hasher) {
    while true {
        let next = chan_recv(h.jobs);
        guard let j = next else {
            return;
        }
        let out = HashOut { ok: false, hash: "", matched: false, error: "" };
        if j.verify {
            let f = h.verify;
            let r = f(j.password, j.encoded);
            if let m = r {
                out.ok = true;
                out.matched = m;
            } else let e = err_of(r) {
                out.error = e;
            }
        } else {
            let f = h.hash;
            let r = f(j.password);
            if let enc = r {
                out.ok = true;
                out.hash = enc;
            } else let e = err_of(r) {
                out.error = e;
            }
        }
        chan_send(j.reply, out);
    }
}

fn submit(h: Hasher, verify: bool, password: str, encoded: str) -> result[HashOut, HashFail] {
    let reply: chan[HashOut] = make_chan(1);
    let job = HashJob { verify: verify, password: password, encoded: encoded, reply: reply };
    let queued = false;
    select {
        case chan_send(h.jobs, job) {
            queued = true;
        }
        default {}
    }
    if !queued {
        return err(HashFail.Busy);
    }
    let got = chan_recv(reply);
    guard let out = got else {
        return err(HashFail.Failed);
    }
    if !out.ok {
        return err(HashFail.Failed);
    }
    return ok(out);
}

pub fn hash_with(h: Hasher, password: str) -> result[str, HashFail] {
    let r = submit(h, false, password, "");
    guard let out = r else let e = err_of(r) {
        return err(e);
    }
    return ok(out.hash);
}

pub fn verify_with(h: Hasher, password: str, encoded: str) -> result[bool, HashFail] {
    let r = submit(h, true, password, encoded);
    guard let out = r else let e = err_of(r) {
        return err(e);
    }
    return ok(out.matched);
}

fn hash_failure(e: HashFail) -> Failed {
    if e == HashFail.Busy {
        return fail_retry(Why.Busy, 1);
    }
    return fail(Why.Unavailable, "password hashing failed");
}
