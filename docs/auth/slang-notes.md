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
