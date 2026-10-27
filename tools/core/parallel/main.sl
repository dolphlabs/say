import "fs";
import "json";
import "proc";
import "../../../src/exchange/domain" as core;

gc struct Check { command: core.Command, expected_state_hash: opt[str], expected_full_hash: opt[str], expected_error: opt[str] }
gc struct Case { policy: core.Policy, pairs: int, capacity: int, commands: [Check] }
gc struct Bundle { cases: [Case] }
gc struct Manifest { files: [str], workers: int }
gc struct Completion { file: str, commands: int, error: str }
gc struct Summary { cases: int, commands: int, workers: int }

fn read_file(path: str) -> result[bytes, str] {
    let opened = fs.open(path); guard let fd = opened else let e = err_of(opened) { return err(e); }
    let stat = fs.fstat(fd);
    if len(stat) != 4 || stat[0] != 0 || stat[1] > 33554432 { fs.close(fd); return err("INVALID_CASE_FILE"); }
    let data = fs.read(fd, stat[1]);
    let closed = fs.close(fd); guard let _ok = closed else let e = err_of(closed) { return err(e); }
    return data;
}

fn execute_case(c: Case, path: str) -> Completion {
    let created = core.new_book(c.policy, c.capacity, c.pairs); guard let b = created else let e = err_of(created) { return Completion { file: path, commands: 0, error: e }; }
    let w = core.new_workspace(&b, c.capacity);
    let completed = 0;
    for check in c.commands {
        let planned = core.plan(&b, check.command, &mut w);
        if let expected_error = check.expected_error {
            if planned != expected_error || w.ready { return Completion { file: path, commands: completed, error: "EXPECTED_ERROR_MISMATCH:" + planned }; }
            let invariant = core.verify(&b, &mut w);
            if invariant != "" { return Completion { file: path, commands: completed, error: invariant }; }
            if let expected = check.expected_state_hash {
                if core.digest_text(b.digest.data, 0) != expected { return Completion { file: path, commands: completed, error: "REJECT_CHANGED_ROLLING_HASH" }; }
            }
            if let expected = check.expected_full_hash {
                let hashed = core.full_hash(&b, false, &mut w);
                if hashed != "" { return Completion { file: path, commands: completed, error: hashed }; }
                if core.digest_text(w.hashes.data, 64) != expected { return Completion { file: path, commands: completed, error: "REJECT_CHANGED_BOOK" }; }
            }
            completed += 1; continue;
        }
        if planned != "" { return Completion { file: path, commands: completed, error: planned }; }
        if core.digest_text(w.hashes.data, 32) != (check.expected_state_hash ?? "") { return Completion { file: path, commands: completed, error: "STATE_HASH_MISMATCH" }; }
        let full = core.full_hash(&b, true, &mut w);
        if full != "" { return Completion { file: path, commands: completed, error: full }; }
        if core.digest_text(w.hashes.data, 64) != (check.expected_full_hash ?? "") { return Completion { file: path, commands: completed, error: "FULL_HASH_MISMATCH" }; }
        let applied = core.apply(&mut b, &mut w);
        if applied != "" { return Completion { file: path, commands: completed, error: applied }; }
        let verified = core.verify(&b, &mut w);
        if verified != "" { return Completion { file: path, commands: completed, error: verified }; }
        completed += 1;
    }
    return Completion { file: path, commands: completed, error: "" };
}

fn run_case(path: str) -> Completion {
    let loaded = read_file(path); guard let data = loaded else let e = err_of(loaded) { return Completion { file: path, commands: 0, error: e }; }
    let decoded: result[Bundle, str] = json.decode(data); guard let bundle = decoded else let e = err_of(decoded) { return Completion { file: path, commands: 0, error: e }; }
    let total = 0;
    for c in bundle.cases {
        let completed = execute_case(c, path);
        total += completed.commands;
        if completed.error != "" { return Completion { file: path, commands: total, error: completed.error }; }
    }
    return Completion { file: path, commands: total, error: "" };
}

fn worker(jobs: chan[str], done: chan[Completion]) -> int {
    let total = 0;
    while true {
        let got = chan_recv(jobs); guard let path = got else { break; }
        let completed = run_case(path); total += completed.commands;
        chan_send(done, completed);
    }
    return total;
}

let args = proc.args();
if len(args) != 2 { println("usage: say-core-parallel manifest.json"); exit(2); }
let loaded = read_file(args[1]); guard let data = loaded else let e = err_of(loaded) { println(e); exit(1); }
let decoded: result[Manifest, str] = json.decode(data); guard let manifest = decoded else let e = err_of(decoded) { println(e); exit(1); }
if manifest.workers < 1 || manifest.workers > 64 || len(manifest.files) < 1 { println("INVALID_MANIFEST"); exit(1); }
let jobs: chan[str] = make_chan(manifest.workers);
let done: chan[Completion] = make_chan(len(manifest.files));
let handles: [join[int]] = [];
for i in 0..manifest.workers { push(handles, spawn worker(jobs, done)); }
for path in manifest.files { chan_send(jobs, path); }
chan_close(jobs);
let count = 0; let failed = false;
for i in 0..len(manifest.files) {
    let got = chan_recv(done); guard let completed = got else { panic("lost worker completion"); }
    count += completed.commands;
    if completed.error != "" { println(json.encode(completed)); failed = true; }
}
for h in handles { let _joined = join_wait(h); }
println(json.encode(Summary { cases: len(manifest.files), commands: count, workers: manifest.workers }));
if failed { exit(1); }
