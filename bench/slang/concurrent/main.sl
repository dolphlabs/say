import "json";
import "proc";
import "strings";
import "time";
import "../../../src/exchange/domain" as core;

extern fn say_probe_begin();
extern fn say_probe_end() -> int;
extern fn say_probe_gc() -> int;
extern fn say_probe_gc_bytes() -> int;
extern fn say_probe_native_bytes() -> int;
extern fn say_probe_maps() -> int;

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

struct Done { market: int, commands: int, a: int, b: int, c: int, d: int, e: int, f: int, g: int, h: int }
gc struct ConcurrentReport { markets: int, cycles_per_market: int, commands: int, elapsed_ns: int, commands_per_second: float,
    gc_allocations_including_harness: int, native_allocation_calls_including_harness: int, native_bytes_including_harness: int,
    memory_maps_including_harness: int, checksum: int, history_digest: str }

fn run_market(number: int, cycles: int, ready: chan[int], start: chan[int], done: chan[Done]) -> int {
    let p = policy(); p.market_id = id(900 + number);
    let created = core.new_book(p, 16, 1000000); guard let b = created else { panic("book"); }
    let w = core.new_workspace(&b, 16);
    let commands: [core.Command] = [];
    for i in 0..(cycles + 20) {
        let c = command(i * 2 + 1, 1000000 + number * 10000 + i, 11, "YES", "BUY", 50, 2);
        push(commands, c);
        c.kind = "Cancel"; c.seq += 1; c.order_id = c.order.id; c.account_id = c.order.account_id;
        push(commands, c);
    }
    for i in 0..40 { execute(&mut b, commands[i], &mut w); }
    chan_send(ready, number);
    let got = chan_recv(start); guard let _token = got else { panic("start gate closed"); }
    for i in 40..len(commands) { execute(&mut b, commands[i], &mut w); }
    chan_send(done, Done { market: number, commands: cycles * 2,
        a: read_word(b.digest.data,0), b: read_word(b.digest.data,4), c: read_word(b.digest.data,8), d: read_word(b.digest.data,12),
        e: read_word(b.digest.data,16), f: read_word(b.digest.data,20), g: read_word(b.digest.data,24), h: read_word(b.digest.data,28) });
    return b.last_seq;
}

fn read_word(data: wire, offset: int) -> int {
    return (data[offset] << 24) | (data[offset+1] << 16) | (data[offset+2] << 8) | data[offset+3];
}

let args = proc.args(); let cycles = 100;
if len(args) > 1 { cycles = to_int(args[1]) ?? 0; }
assert(cycles > 0 && cycles <= 1000);
let ready: chan[int] = make_chan(1000); let start: chan[int] = make_chan(1000); let done: chan[Done] = make_chan(1000);
let handles: [join[int]] = [];
for number in 0..1000 { push(handles, spawn run_market(number, cycles, ready, start, done)); }
for i in 0..1000 { let got = chan_recv(ready); guard let _number = got else { panic("lost ready"); } }
let histories = core.byte_writer(32000);
say_probe_begin(); let began = time.mono();
for i in 0..1000 { chan_send(start, i); }
let total = 0; let checksum = 0;
for i in 0..1000 {
    let got = chan_recv(done); guard let result_ = got else { panic("lost completion"); }
    total += result_.commands; checksum += result_.a;
    for word_index in 0..8 {
        let value = result_.a;
        if word_index==1 { value=result_.b; } if word_index==2 { value=result_.c; } if word_index==3 { value=result_.d; }
        if word_index==4 { value=result_.e; } if word_index==5 { value=result_.f; } if word_index==6 { value=result_.g; } if word_index==7 { value=result_.h; }
        for byte_index in 0..4 { histories.data[result_.market*32+word_index*4+byte_index]=(value >> ((3-byte_index)*8)) & 255; }
    }
}
let elapsed = (time.mono() - began) as int; let calls = say_probe_end();
for h in handles { let _joined = join_wait(h); }
let hash = core.sha256_workspace(); let digest = core.byte_writer(32);
assert(core.sha256_into(&mut hash,histories.data,32000,digest.data,0));
println(json.encode(ConcurrentReport { markets: 1000, cycles_per_market: cycles, commands: total, elapsed_ns: elapsed,
    commands_per_second: (total as float) * 1000000000.0 / (elapsed as float), gc_allocations_including_harness: say_probe_gc(),
    native_allocation_calls_including_harness: calls, native_bytes_including_harness: say_probe_native_bytes(),
    memory_maps_including_harness: say_probe_maps(), checksum: checksum, history_digest: core.digest_text(digest.data,0) }));
