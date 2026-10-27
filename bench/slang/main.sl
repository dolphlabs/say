import "json";
import "proc";
import "strings";
import "time";
import "../../src/exchange/domain" as core;

extern fn say_probe_book_storage() -> int;
extern fn say_probe_workspace_storage() -> int;
extern fn say_probe_begin();
extern fn say_probe_end() -> int;
extern fn say_probe_gc() -> int;
extern fn say_probe_gc_bytes() -> int;
extern fn say_probe_native_bytes() -> int;
extern fn say_probe_maps() -> int;
extern fn say_probe_slot_bytes() -> int;
extern fn say_probe_order_bytes() -> int;
extern fn say_probe_bucket_bytes() -> int;

gc struct Report {
    scenario: str, samples_ns: [int], commands: int, p50_ns: int, p99_ns: int, p999_ns: int, commands_per_second: float,
    gc_allocations: int, gc_bytes: int, native_allocation_calls: int, native_requested_bytes: int, memory_maps: int,
    book_buffer_bytes: int, workspace_buffer_bytes: int, order_record_bytes: int, slot_record_bytes: int, index_bucket_bytes: int, final_hash: str,
}

fn id(n: int) -> str { let text = to_str(n); return "00000000-0000-4000-a000-" + strings.repeat("0", 12 - len(text)) + text; }
fn policy() -> core.Policy { return core.Policy { market_id: id(900), season_id: id(901), V: 100, min_price: 1, max_price: 99, tick: 1, max_order_qty: 100000, min_order_notional: 2 }; }
fn command(seq: int, number: int, account: int, outcome: str, side: str, price: int, qty: int) -> core.Command {
    let order = core.empty_order();
    order.id = id(number); order.account_id = id(account); order.owner_kind = "user"; order.outcome = outcome; order.side = side;
    order.limit = price; order.qty = qty; order.remaining = qty; order.tif = "GTC"; order.accepted_seq = seq;
    order.sedi_hold_id = id(100000000 + number * 2); order.sedi_original = 1;
    if side == "BUY" { order.sedi_original = price * qty + 1; }
    else { order.share_hold_id = id(100000001 + number * 2); order.shares_original = qty; }
    return core.Command { kind: "Place", seq: seq, ref: order.id, order: order, order_id: "", account_id: "", system: false, reason: "USER_CANCEL" };
}

fn execute(b: &mut core.Book, cmd: core.Command, w: &mut core.Workspace) {
    let planned = core.plan(&*b, cmd, &mut *w); assert(planned == "", planned);
    let applied = core.apply(&mut *b, &mut *w); assert(applied == "", applied);
}

fn sorted_samples(values: [int]) -> [int] {
    let source: [int] = []; let target: [int] = [];
    for n in values { push(source, n); push(target, 0); }
    let width = 1;
    while width < len(source) {
        let start = 0;
        while start < len(source) {
            let mid = start + width; if mid > len(source) { mid = len(source); }
            let end = mid + width; if end > len(source) { end = len(source); }
            let i = start; let j = mid;
            for out in start..end {
                if i < mid && (j >= end || source[i] < source[j]) { target[out] = source[i]; i += 1; }
                else { target[out] = source[j]; j += 1; }
            }
            start = end;
        }
        for i in 0..len(source) { source[i] = target[i]; }
        width *= 2;
    }
    return source;
}

fn report(name: str, samples: [int], allocations: int, gc_count: int, gc_bytes: int, native_bytes: int, maps: int, final_hash: str) {
    let sorted = sorted_samples(samples); let total = 0;
    for n in sorted { total += n; }
    println(json.encode(Report { scenario: name, samples_ns: samples, commands: len(samples), p50_ns: sorted[len(sorted) / 2],
        p99_ns: sorted[(len(sorted) - 1) * 99 / 100], p999_ns: sorted[(len(sorted) - 1) * 999 / 1000],
        commands_per_second: (len(samples) as float) * 1000000000.0 / (total as float),
        gc_allocations: gc_count, gc_bytes: gc_bytes, native_allocation_calls: allocations, native_requested_bytes: native_bytes, memory_maps: maps,
        book_buffer_bytes: say_probe_book_storage(), workspace_buffer_bytes: say_probe_workspace_storage(), order_record_bytes: say_probe_order_bytes(), slot_record_bytes: say_probe_slot_bytes(), index_bucket_bytes: say_probe_bucket_bytes(), final_hash: final_hash }));
}

fn scenario(name: str, count: int) {
    let capacity = 16;
    if name == "cancel_storm" { capacity = 10001; }
    let created = core.new_book(policy(), capacity, 1000000); guard let b = created else { panic("book"); }
    let w = core.new_workspace(&b, capacity);
    let commands: [core.Command] = [];
    for i in 0..(count + 200) { push(commands, command(0, 1000000 + i, 11, "YES", "BUY", 50, 2)); }
    let samples: [int] = []; for i in 0..count { push(samples, 0); }
    let cancel_ids: [str] = [];
    if name == "cancel_storm" {
        for i in 0..10000 {
            let c = command(b.last_seq + 1, 2000000 + i, 11, "YES", "BUY", 50, 2);
            push(cancel_ids, c.order.id); execute(&mut b, c, &mut w);
        }
    }
    let gc_count = 0; let gc_bytes = 0; let native_bytes = 0; let calls = 0; let maps = 0;
    for iteration in 0..(count + 200) {
        let warmup = iteration < 200;
        let cmd = commands[iteration]; cmd.seq = b.last_seq + 1; cmd.order.accepted_seq = cmd.seq;
        if name == "cancel" {
            execute(&mut b, cmd, &mut w);
            cmd.kind = "Cancel"; cmd.seq = b.last_seq + 1; cmd.order_id = cmd.order.id; cmd.account_id = cmd.order.account_id;
        } else if name == "fill_one" {
            let maker = cmd; maker.order.side = "SELL"; maker.order.account_id = id(12); maker.order.sedi_original = 1;
            maker.order.share_hold_id = id(3000000 + iteration); maker.order.shares_original = 2;
            execute(&mut b, maker, &mut w);
            cmd = command(b.last_seq + 1, 4000000 + iteration, 11, "YES", "BUY", 60, 2);
        } else if name == "walk_transfer_mint" || name == "walk_transfer_merge" {
            for level in 0..10 {
                let maker = command(b.last_seq + 1, 5000000 + iteration * 10 + level, 12, "YES", "SELL", 45 + level, 2);
                if name == "walk_transfer_mint" && level % 2 == 1 {
                    maker.order.outcome = "NO"; maker.order.side = "BUY"; maker.order.limit = 55 - level;
                    maker.order.sedi_original = maker.order.limit * 2 + 1; maker.order.share_hold_id = ""; maker.order.shares_original = 0;
                }
                if name == "walk_transfer_merge" {
                    maker = command(b.last_seq + 1, 5000000 + iteration * 10 + level, 12, "YES", "BUY", 54 - level, 2);
                    if level % 2 == 1 {
                        maker.order.outcome = "NO"; maker.order.side = "SELL"; maker.order.limit = 46 + level;
                        maker.order.sedi_original = 1; maker.order.share_hold_id = id(20000000 + iteration * 10 + level); maker.order.shares_original = 2;
                    }
                }
                execute(&mut b, maker, &mut w);
            }
            cmd = command(b.last_seq + 1, 6000000 + iteration, 11, "YES", "BUY", 60, 20);
            if name == "walk_transfer_merge" {
                cmd = command(b.last_seq + 1, 6000000 + iteration, 11, "YES", "SELL", 40, 20);
            }
        } else if name == "cancel_storm" {
            if warmup {
                let c = command(b.last_seq + 1, 7000000 + iteration, 11, "NO", "BUY", 20, 2);
                execute(&mut b, c, &mut w);
                cmd.kind = "Cancel"; cmd.seq = b.last_seq + 1; cmd.order_id = c.order.id; cmd.account_id = c.order.account_id;
            } else {
                cmd.kind = "Cancel"; cmd.order_id = cancel_ids[iteration - 200]; cmd.account_id = id(11);
            }
        }
        say_probe_begin();
        let start = time.mono();
        execute(&mut b, cmd, &mut w);
        let elapsed = (time.mono() - start) as int;
        let allocated = say_probe_end();
        if !warmup {
            samples[iteration - 200] = elapsed;
            calls += allocated; gc_count += say_probe_gc(); gc_bytes += say_probe_gc_bytes(); native_bytes += say_probe_native_bytes(); maps += say_probe_maps();
        }
        if name == "rest" {
            cmd.kind = "Cancel"; cmd.seq = b.last_seq + 1; cmd.order_id = cmd.order.id; cmd.account_id = cmd.order.account_id;
            execute(&mut b, cmd, &mut w);
        }
    }
    let verified = core.verify(&b, &mut w); assert(verified == "", verified);
    report(name, samples, calls, gc_count, gc_bytes, native_bytes, maps, core.digest_text(b.digest.data, 0));
}

let args = proc.args();
let count = 10000; if len(args) > 1 { count = to_int(args[1]) ?? 0; }
assert(count > 0 && count <= 10000);
for name in ["rest", "cancel", "fill_one", "walk_transfer_mint", "walk_transfer_merge", "cancel_storm"] { scenario(name, count); }
