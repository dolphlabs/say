# slang and zokor: what auth can rely on

Confirmed against slang 0.2.3 (`../slang`, docs and `runtime/`), zokor
v0.2.0 (`../zokor/docs/api.txt`) and `zokor check` (`../zokor_cli`), on
2026-10-19. Where a fact comes from the runtime source rather than the
docs, the file is named.

**Changed since, for this work** (the sections below describe 0.2.3):
- dolphlabs/slang#445: argon2id runs on kdf threads while the task parks,
  in any program with the reactor (every server), so it no longer pins a
  worker or delays garbage collection. `crypto.rsa_verify_sha256` checks
  RS256 against JWKS `n`/`e`.
- zokor_cli: `tenant` and `auth` are opt-in via `zokor.rules`, and a
  store may import another feature's store.
- Found while building: `httpc` ignores the deadline while connecting
  (it uses `net.dial` / `net.tls_dial`). And the reactor can wedge after
  a login flood (see LOADTEST.md).

## spawn and scheduling

- `spawn f(args)` runs `f` as a green task on an M:N pool. Arguments are
  evaluated in the spawner; nothing is captured (there are no closures).
  `f` must be a top-level function or a function value, not a method.
- Pool size: one worker per usable CPU (affinity mask and cgroup quota on
  Linux), at least 2; `SLANG_WORKERS=N` overrides. The program cannot
  read the worker count (`proc` has no such call), so anything sized
  "per core" has to come from config.
- **Scheduling is preemptive** for slang code: a task that runs past its
  time slice without a yield point is preempted by a signal
  (`runtime/sl_pool.c`, `sl_preempt_handler`). A long slang loop does not
  freeze a worker.
- **Native crypto is not preemptible.** `crypto.argon2id_raw` and
  `argon2id_verify` wrap OpenSSL's `EVP_KDF_derive` in
  `sl_rt_preempt_disable()` / `enable()` (`runtime/sl_crypto.c`). One
  hash pins one OS worker for its whole duration (tens of ms). With N
  workers, N concurrent hashes stop every other task in the process.
- **A hash also delays every GC pause.** A stop-the-world collection
  waits until each worker has acked or is marked GC-blocked
  (`runtime/sl_gc.c`). Network waits mark themselves blocked
  (`sl_net.c`); argon2 does not, so a collection requested during a hash
  waits for the hash to finish, and every task waits with it.
- Blocking-looking calls (`net`, `chan_*`, `time.sleep`, `mutex_lock`,
  pg, redis, httpc) park the task, not the worker. There is no
  async/await split.
- **No blocking-offload facility exists**: no thread pool for native
  work, no `spawn_blocking`. A CPU-bound native call runs on whichever
  worker the task is on.
- Panics: a runtime error in a spawned task ends that task only
  (`task panicked: ...` on stderr). In the main task it ends the process.
  `exit()` always ends the process.
- Lifetime: spawned tasks are not tied to a request; they outlive it and
  run until they return. `proc.active_tasks()` counts in-flight tasks,
  and `proc.wait_idle()` parks until it is zero.

## Channels and select

- `chan[T]` from `make_chan(capacity)`. **Always bounded.** `chan_send`
  parks while the channel is full (back-pressure by waiting). `chan_recv`
  returns `opt[T]`, `none` once the channel is closed and drained.
  Sending on a closed channel is a checked runtime error.
- There is no `try_send`. A non-blocking send is
  `select { case chan_send(ch, v) { .. } default { .. } }`, and the
  `default` arm is the drop path.
- `select` has no timeout arm. A deadline means a spawned timer task that
  sends on a channel. A closed channel's recv arm is ready forever, so
  loops must exit on close.
- `mutex`: `make_mutex`, `mutex_lock`, `mutex_unlock`, `mutex_trylock`.
  Contention parks the task. It is not recursive, and there is no
  `defer`, so unlock must come before every `return`.

## Join

- `let h = spawn f(..)` gives `join[T]`; `join_wait(h) -> result[T, str]`
  parks until `f` returns, and a panic in `f` comes back as `err`.
- That covers fan-out and wait-all: spawn several, then `join_wait`
  each. A spawn immediately followed by its own `join_wait` runs on the
  same worker without waking another.
- There is no wait-any and no cancellation. Deadlines go to the I/O
  calls themselves (`until`).

## CPU-heavy work: the hashing pool

Given the above, the pool has to bound how many workers argon2 can pin
at once:

- K long-lived hasher tasks, fed by a bounded `chan[HashJob]`. Each job
  carries its own reply channel (capacity 1), and the request task waits
  on it.
- K comes from config (`HASH_WORKERS`). It must be below the slang
  worker count so at least one worker always serves requests: K =
  `max(1, workers / 2)`, so 2 on a 4-core box.
- When the queue is full, a `select ... default` send fails at once, and
  the handler answers `503` with `retry_after`.
- Memory: each hash allocates `memory_kib`. K=2 at 19 MiB is about 38 MiB
  at peak; the current 64 MiB setting is 128 MiB.
- What the pool cannot fix: GC pauses waiting on an in-flight hash
  (above). The proper fix is in the slang runtime: copy the inputs and
  mark the thread GC-blocked around `EVP_KDF_derive`, as `sl_net.c` does
  around waits. That is a slang change, not a say change.

## Crypto available

- `crypto`: `sha256`, `hmac_sha256`, `rand` (CSPRNG via OpenSSL),
  `sha1`, `md5`, `pbkdf2_sha256`, `argon2id_raw`, `argon2id_verify`
  (OpenSSL 3.2+; password capped at 1 MiB by the runtime).
- `zokor.constant_time_equal(a, b)` for comparing HMACs and token
  hashes.
- `../slangpackages/argon` (github.com/dolphlabs/argon) gives standard
  PHC strings, bounded params, `verify` and `needs_rehash`. Defaults are
  m=19456 KiB, t=2, p=1 (OWASP). It has no git tag yet, so it cannot be
  pinned in `slang.project`.
- **No RSA or ECDSA anywhere.** The `jwt` package and zokor's JWT are
  HS256 only (`jwt.verify(token, key: bytes)`). Verifying a Google ID
  token's RS256 signature against JWKS is not possible today. The
  smallest workaround is a native `crypto.rsa_verify_sha256(n, e, msg,
  sig)` in slang's runtime (OpenSSL `EVP_DigestVerify`).
- `encoding`: hex and base64url (for JWT segments and PKCE),
  `url_encode`, `form_encode`.

## zokor

- **Middleware**: `r.before(fn(Ctx[S]) -> opt[http.Response])` and
  `group.before(..)`; they apply to routes registered after them.
  `guarded` covers a single route. `after` hooks always run. Request
  state passes through `c.set_local` / `c.local` (strings only).
- **Context**: `c.state` (the shared `App`, a gc struct shared by every
  task), `c.param`, `c.query`, `c.header`, `c.bearer()`, `c.client_ip`
  (honours `TRUSTED_PROXIES`), `c.request_id` (off in say:
  `request_ids = false`).
- **Cookies**: `zokor.Cookie` defaults to `HttpOnly; Secure;
  SameSite=Lax; Path=/`. `set_cookie` refuses unsafe ones;
  `clear_cookie`; `c.cookie(name)`. Signed cookies are optional; an
  opaque random token does not need signing.
- **Errors**: `zokor.register(reg, code, status, message)`, then
  `respond`, `respond_with` (custom detail) or `respond_fields`. The
  envelope shape is replaced once with `set_renderer`, which is how
  `{error:{code,message,retry_after?}}` will be produced.
- **Postgres** (`pg.Pool` from `zokor.pg_from_config`, `DB_POOL_SIZE`):
  `query_all`, `query_one`, `conn_query_all` and `transaction(pool, arg,
  body, deadline)`, which runs `BEGIN ... COMMIT` and rolls back on `err`
  or panic. It always uses READ COMMITTED; a stricter level means `SET
  TRANSACTION ISOLATION LEVEL` as the body's first statement. Every call
  takes a deadline (`until`). When it passes, pg sends a CancelRequest to
  the server (`stdlib/pg/pg.sl`), so a timeout really stops the query.
  There is no server-side `statement_timeout` setting; use `SET LOCAL
  statement_timeout` inside transactions if wanted. Results map by
  column name, NULL to `opt`, `timestamptz` to `timez.Time`.
  `is_unique_violation(e)` and `pg.sqlstate(e)` classify errors.
- **Migrations**: forward-only. `zokor.migrate` checks a checksum per
  file under an advisory lock, so editing an applied file breaks
  `migrate`. Changes go in a new `NNN_*.sql`.
- **Redis** (`redis.Pool` from `zokor.redis_from_config`): typed
  `set_ex`, `set_nx`, `incr`, `expire`, `del_keys`, `get`, plus `do(conn,
  args)` for any command. `SET k v NX EX 600` and atomic
  `INCR`-with-TTL (MULTI/EXEC, or SET NX EX then INCR) go through `do`.
  Every call takes a deadline.
- **In-process rate limiting**: `zokor.new_rate_limiter(limit,
  window_ns)` is a sharded, mutex-guarded rolling window. It is the
  fail-open fallback when Redis is down.
- **Jobs**: `zokor.new_jobs(state)` gives cron (`every`) and a retrying
  in-memory queue (`handle`/`enqueue`), stopped on SIGTERM. It suits the
  cleanup and JWKS refresh schedules, but not the outbox, which must
  survive restarts and so lives in Postgres.
- **httpc**: `Client.send(req, deadline)` over https with a pooled
  client. Good for Google's token endpoint and JWKS, and for the email
  provider.
- **Tests**: `zokor.request(..).build()`, `r.serve(req)`, and
  `resp_status`/`resp_json`/`resp_header`, with no sockets.

## zokor check (constraints on the design)

- `pure`: `domain/` and `service/` may not import `pg`, `http`,
  `httpc`, `net`, `fs`, `os`, `proc`, `io`, `sql`, `redis` or `zokor`.
  `crypto`, `encoding`, `strings`, `builder`, `timez`, channels and
  `spawn` are allowed, so the hashing pool can live in `service/`.
- `tenant`: every `pub fn` in `service/` must take `tenant_id: str`.
  `auth`: every `server.sl` must call `require_tenant` or say
  `// zokor:public`. **These cannot be switched off**; removing the
  tenant means changing `zokor_cli/cmd/zokor/check.sl`.
- `config`: only `src/main.sl` and `platform/config` read configuration.
- `imports`: `server -> service -> domain`; a store implements its own
  feature's ports; features reach each other only through `service`;
  `platform/app` wires everything.

## Learned while building the ledger (prompt 02)

- **Integers wrap on overflow** (two's complement, no trap). Money sums go
  through `ledger/domain/money.sl` (`checked_add`, `checked_mul`), which
  return `none` instead of wrapping.
- There is no sort builtin. Small lists use insertion sort (canonical
  hashes, lock lists); the load test has a merge sort. `str` compares with
  `<` byte-wise. Postgres ordering does not match that unless the SQL says
  `COLLATE "C"`, which every lock-order query does.
- Maps iterate with `for k, v in m` (insertion order), and `del(m, k)`
  removes a key. `m[k]` on a missing key panics, so check `has(m, k)` first.
- A generic function cannot be passed as a function value (for example as
  a transaction body). Write a concrete wrapper. Spawning an instantiated
  generic function (`spawn run_rollover(l, id)`) works.
- `join_wait(spawn f(..))` gives `result[R, str]` around whatever `f`
  returns, so a function returning `result[T, E]` comes back nested.
  `ledger.summary` unwraps both levels.
- A session advisory lock needs one connection for the length of the
  lease: `pg.acquire`, then `pg.release` after `pg_advisory_unlock_all()`.
  On any error, `pg.close` it before releasing, so the lock can never go
  back into the pool.
- `SET LOCAL`/`set_config(..., true)` changes made inside a savepoint are
  undone by `ROLLBACK TO SAVEPOINT`. The ledger relies on that for its
  one-posting-per-transaction marker.

## Confirmed for exchange runtime design (prompt 05, 2026-10-26)

These additions support `docs/exchange/RUNTIME.md`; the registry, matching
core and runtime are still proposed, not implemented. Existing concurrency
sections above remain applicable except where their earlier limitations
were explicitly corrected by later sections.

### Task cost: local capability probe

Installed compiler: `slangc 0.2.3`, normal compilation without custom flags.
Host reports Darwin x86_64; CPU model and RAM sysctl queries were denied by
the sandbox, so no more specific hardware claim is made. Each run used
`SLANG_WORKERS=2`. Three fresh processes were run for each task count.
Each task sent ready, then parked on a shared stop channel; main waited for
all ready signals, slept 250 ms, closed stop and waited for task completion.

| Parked tasks | Spawn-to-ready times, ms | Peak RSS bytes, three trials |
|---|---|---|
| 0 | 0.000 / 0.000 / 0.001 | 970752 / 974848 / 987136 |
| 1,000 | 6.642 / 8.067 / 7.669 | 5431296 / 5447680 / 5443584 |
| 5,000 | 37.073 / 32.294 / 36.822 | 23236608 / 23199744 / 23252992 |

Median peak-RSS difference from the zero-task run was about 4,469 bytes per
task at 1,000 and 4,452 at 5,000, around **4.3–4.4 KiB resident per task**.
Median spawn-to-ready was 7.669 ms for 1,000 and 36.822 ms for 5,000; this
includes scheduling and channel handshakes, not just task creation.
All nine processes exited successfully and drained their spawned tasks.
The runs were not CPU-affined and project checks were running concurrently;
these startup timings are not an isolated performance benchmark.

Peak RSS came from `os.wait4(...).ru_maxrss` in Python, bytes on this Darwin
host. These are small-sample process measurements, not an exact allocator
size. Shared ready-channel storage is included; per-actor mailboxes,
book/order pools, immutable views, GC under traffic, PG waits and timer
tasks are not. Sibling source `../slang/runtime/sl_core.c` at inspected
commit `4f5fa28` defines an 8,192-byte initial default stack; resident pages
and reserved stack size are different measurements, and that sibling
commit is not claimed as the installed binary's build commit.

The probe supports starting with 1,000 idle owner tasks without inventing
a hibernation requirement. A full 1,000-market actor test is still needed
before assigning production memory limits or deciding about hibernation.

Reproduction source (temporary probe, outside project implementation):

```slang
import "proc";
import "time";

fn idle(ready: chan[int], stop: chan[int]) -> int {
    chan_send(ready, 1);
    let stopped = chan_recv(stop);
    return 0;
}

let args = proc.args();
let count = 0;
if len(args) > 1 {
    count = to_int(args[1]) ?? 0;
}
let ready: chan[int] = make_chan(count + 1);
let stop: chan[int] = make_chan(1);
let start = time.mono();
for i in 0..count {
    spawn idle(ready, stop);
}
for i in 0..count {
    let arrived = chan_recv(ready);
    guard let value = arrived else { panic("ready closed"); }
}
let parked_ns = time.mono() - start;
time.sleep(250000000);
chan_close(stop);
proc.wait_idle();
println("tasks=" + to_str(count) + " spawn_to_ready_ns=" + to_str(parked_ns));
```

Compile as `slangc probe.sl -o probe`, then run
`SLANG_WORKERS=2 ./probe 0`, `./probe 1000` and `./probe 5000`, setting the
same worker override for every invocation. Raw source/results for this run
were kept in `/private/tmp/say-runtime-task-probe-20261026/`; this temporary
path is not a durable test harness or a CI artifact.

### Nonblocking hints and bounded replies

Rechecked `../slang/docs/concurrency/index.md` and the existing ledger's
select/default kick pattern. There is no standalone `try_send` or native
timeout-receive/select-after API. Use select with a send case and default
for hints; use a capacity-one reply channel and a timer channel for the
300 ms select. A timer is a top-level spawned wrapper around time.sleep,
or a bounded long-lived timer service, not an invented time.after call.

Timers cannot be cancelled through a verified public primitive. Let a
losing timer finish with one nonblocking/buffered send and remove the
waiter registration. Never close reply/timer channels while a sender may
still use them; sending on a closed channel panics. Do not let per-request
timers or waiter lists grow without request concurrency limits. A reply
channel works within one process only; remote completion needs a separate
runtime port/watcher, not a cross-server channel.

### Immutable publication for many readers

No public atomic-reference swap primitive was found in the inspected
language/concurrency API. Plain struct assignment is shallow for list/map
members; GC allocation is not a synchronization or immutability guarantee.
Build a fresh BookView with independent level vectors, then never mutate
it after publishing.

Use a mutex-protected per-market view cell: readers copy the reference
under lock and serialize after unlock. The actor uses mutex_trylock,
coalesces its latest pending view if contended and retries later, so it
does not park on readers. Other workers may acquire the cell normally for
hydration/invalidation. Every early return unlocks explicitly; there is
no defer. Measure publication lag and reject stale views as specified in
RUNTIME.md. This is an equivalent publication design with verified
primitives, not a claimed lock-free atomic-pointer implementation.

## Confirmed for live-feed design (prompt 06, 2026-10-26)

The stream design is docs/stream/STREAM.md. No gateway implementation or
live WebSocket/Redis load result is implied by these API/source checks.
`slangc doc zokor` confirmed WsRules, Socket, WsRoute, ws_route, Ctx,
new_conn, receive, pending, close_frame and default_ws. The resolved
dependency is v0.2.0 with hash
`3f41f1692182186f373063e9fcbf6d389f9c463daacd24c7373374f51b5b1b6d`.
The matching cached package is under
`~/.cache/slang/pkg/zokor/sha256:<hash>/zokor/`; its ws.sl, ws_serve.sl
and socket.sl were byte-compared with ../zokor/zokor and matched.

### Upgrade, reader/writer and protocol controls

- Register `Router.websocket(path, open, route)` with
  `zokor.ws_route(rules, message).on_close(closed)`. The open handler uses
  `Ctx.socket()` and `Ctx.accept_ws()`; there is no exported ws_accept or
  socket_of function. Ordinary route hooks run before the upgrade.
- Callback types are `fn(App, Socket, Message)` and
  `fn(App, Socket, int, str)` for close. The framework reader decodes
  messages and invokes callbacks in order. It spawns/joins a transient
  callback task to isolate panic; there are two long-lived transport tasks,
  not necessarily only two tasks ever associated with a socket.
- `Socket.send_text`, `send_binary`, `close(code,reason)` return bool.
  The dedicated ws_writer owns sends on the split connection. Reader-side
  ping/pong/close decoder output is queued for that writer too.
- WsRules frame/message limits default to 1 MiB/8 MiB. Set both to 16 KiB
  for this protocol; assembled fragments must not bypass the message cap.
  The parser validates masking, framing, UTF-8 and close payloads.
- Native WebSocket pings occur after silence. Durations are nanoseconds;
  default ping_interval=25s, pong_timeout=20s, close_timeout=5s. A fixed
  twenty-second schedule under active traffic requires explicit integration;
  it does not follow merely from setting ping_interval=20s.
- Local close codes include 1000/1001/1002/1003/1007/1008/1009/1010/1011
  and 3000–4999 application codes. 4001 and 4008 are valid. 1006 is a
  local abnormal-close observation and cannot be sent on the wire.
  Current close_because always emits 1002, even for oversize parse errors;
  an intended 1009 mapping needs a tested extension.

### Existing queue behavior does not implement prompt 06's policy

Socket.out is a channel bounded only by WsRules.max_queue (default 256).
It has no byte counter, replacement/coalescing API, write acknowledgement
or priority-control reserve. Socket enqueue takes a mutex before its
nonblocking channel offer; it can briefly park on mutex contention.
Overflow immediately marks the socket closed with 1008, rather than
merging and allowing ten seconds before 4008.

Socket.close queues behind existing data and may have no room for its close
frame. The served writer uses ServerConfig.write_timeout, default ten
seconds; reader shutdown notices socket state around its receive loop.
These details prevent claiming the required priority/sub-second revocation
and bounded merge policy from stock send_text/close alone. STREAM.md
proposes an opt-in queue/writer integration, not an existing API. Do not
add an unaccounted second queue/writer pump to conceal this limitation.

### Redis XREAD and connection capacity

`../slang/stdlib/redis/redis.sl` exports
`redis.do(Conn,[bytes],until) -> result[Reply,str]`; XREAD BLOCK is passed
as ordinary command arguments and its nested RESP Reply is decoded by
the store adapter. No typed redis.xread API is assumed.

do holds that connection's mutex for the complete round trip. Its receive
path calls deadline-aware net.recv_until/net.tls_recv_until: waiting parks
the task, not the worker. Each blocked reader therefore needs its own
connection; sharing an auth connection would stall that connection's other
commands even though the worker pool still runs. A timed-out/broken
connection is discarded by release rather than returned healthy to the
pool. Bound BLOCK and network deadlines separately so control work and
shutdown are serviced; no native select-after or cancellable XREAD is
assumed. Provision separate streaming capacity for active hubs, sixty-four
private readers and node listeners before claiming latency targets.

## Matching-core representation checks (2026-10-27)

Verified against installed slangc0.2.3 and its emitted C, not assumed from
language syntax:

- A plain owning struct can hold an arena, its wire and preallocated arrays,
  return by value and move through a result/guard. Emitted cleanup frees the
  nested arena on normal/error exits. A GC struct containing an affine arena
  does not provide that owning drop behavior; the core uses plain Book and
  Workspace values instead.
- One arena wire borrow prevents a second simultaneous mutable arena borrow.
  Separate owning ByteWriter values provide disjoint canonical/key/hash/UUID
  buffers. `wire_put` copies a string into an existing wire without making
  bytes. Wire indexing reads/writes bytes. String indexing is unavailable;
  UUID parsing/hashing first copies exactly36 bytes into scratch.
- `to_bytes(str)` and `to_bytes(wire)` allocate and copy. JSON materialization
  and hex text exports belong outside plan/apply. Length-prefixed integer
  output uses a decimal writer that handles INT64_MIN without negating it.
- Plain records can live directly in arrays. Assigning an indexed record's
  field directly produced nonassignable generated C; load the record into a
  local, update it, then assign the complete record back to the array slot.
- Forwarding a mutable borrow moves it. Use `&mut *w` when forwarding it to
  several calls. Borrow lifetime also covers a complete expression, so split
  a mutable call and a later immutable read into separate statements.
- `opt[int]` uses the inline `sl_opt_int {has,v}` representation in this
  compiler. Checked arithmetic returning this option did not allocate.
  Generic results/GC DTOs can have different costs; no universal claim about
  every option/result representation follows.
- The stdlib crypto SHA256 interface allocates its result. The core's
  SHA256_into uses preallocated state/schedule arrays and caller-owned wire.
  Known vectors and padding boundaries are compared against stdlib crypto
  in tests; all32-bit intermediate words are masked inside checked-safe
  signed64-bit bounds.
- `bench/instrument.py` instruments the generated/runtime allocation entry
  point and native malloc/calloc/realloc/posix_memalign/mmap call sites in
  explicit timed regions. Warm ordinary plan/apply measured zero calls;
  constructor, growth, snapshots, DTO conversion and scheduling are reported
  separately. This is source instrumentation, not a claim that libc-internal
  allocations in arbitrary foreign functions are intercepted.
