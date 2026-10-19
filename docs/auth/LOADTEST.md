# Auth load test

`make load` (script: `loadtest/run.sh`, needs `wrk` and `make test-stack`).
Run on 2026-10-19 with the slang build from PR dolphlabs/slang#445
(argon2id on kdf threads).

## Setup

- macOS (Darwin x86_64), 8 cores. **wrk, the server, Postgres and
  Redis all share the machine**, so every number includes contention with
  the load generator. Treat them as relative, not as production capacity.
- slang workers: 8 (default). `HASH_WORKERS=4`, `HASH_QUEUE=64`,
  `DB_POOL_SIZE=20`. argon2id m=19456 KiB, t=2, p=1 (about 40 ms a hash
  here).
- 5,000 seeded active users sharing one real argon2id hash. Each request
  logs in a random one, from a random client address (`X-Forwarded-For`
  with `TRUSTED_PROXIES=127.0.0.1/32`), so the per-IP limit does not
  dominate.
- Phase 1: the probe alone, `GET /v1/seasons/current`, 10 connections,
  10 s. Phase 2: 500 concurrent logins for 30 s with the probe alongside.
  Phase 3: the server's state 10 s later.

## Results

| | p50 | p95 | p99 | max | errors |
|---|---|---|---|---|---|
| Probe alone | 2.0 ms | 3.4 ms | 5.7 ms | 50 ms | 0 |
| Probe during the login flood | 7.6 ms | 73 ms | 159 ms | 345 ms | 0 |
| Logins (all answers) | 124 ms | 1,290 ms | 1,932 ms | 2,496 ms | 0 socket errors |

Login answers over 30 s (3,279 requests/s in total):

| Status | Count | Why |
|---|---|---|
| 200 | 1,127 | Hashed and verified |
| 503 `BUSY` | 52,400 | Queue full: refused at once with `retry_after` |
| 429 `RATE_LIMITED` | 45,138 | About 20 tries per user in 30 s, over the spec's 10 per email per 15 min |

Ten seconds after the flood: `/healthz` ok, no sockets left in CLOSE_WAIT,
CPU 1.6%.

## Reading it

- **The hashing pool does its job.** Of about 100,000 login attempts, only
  1,127 ever reached argon2id. The rest were refused in microseconds,
  either by the bounded queue or by the rate limit. That is the protection
  the prompt asked for: a flood costs the server four hashes at a time,
  not 500.
- **Login tail latency is queue wait.** A login that wins a queue slot
  waits behind at most 64 others at about 37 hashes/s under this
  contention, so p95–p99 sits around 1.3–1.9 s. A smaller `HASH_QUEUE`
  trades more 503s for a shorter tail.
- **Unrelated endpoints stay up but slow down.** The probe never failed;
  its p99 went from 6 ms to 159 ms. Most of that comes from sharing 8
  cores with wrk (8 threads, 500 sockets) and with roughly 3,300 refusals
  a second. Because argon2id no longer runs on scheduler workers, a hash
  cannot stall the probe for the length of a hash. Measuring on separate
  load-generator hardware is the next step for real capacity numbers.

## A slang runtime defect found by this test

In 4 of 14 login floods of 500 connections, the server stopped answering
after the clients disconnected, and one more run crashed:
- one core spins at 100% in `sl_reactor_thread`;
- every worker and the main thread block on a reactor wait-queue mutex
  inside `sl_reactor_wait_until`;
- about 500 sockets sit in CLOSE_WAIT;
- `/healthz` times out until the process is killed.

What the A/B runs showed:

- It reproduces **with argon2id inline**, the `dev` behaviour (slang built
  without `SL_HAVE_REACTOR`), so the kdf offload does not cause it. The
  inline build also crashed once with `SIGBUS` at `pc == address`.
- It did **not** reproduce flooding endpoints that never hash
  (`/v1/seasons/current`, the username check) at the same concurrency,
  nor with 50 connections.
- The trigger seems to be heavy connection churn while workers do long
  CPU-bound work.

Repro: `make test-stack`, then run `loadtest/run.sh` a few times (or the
same flood by hand) and watch for CLOSE_WAIT sockets and a dead
`/healthz` after it ends. `sample <pid> 2` (macOS) on the stuck process
shows the stacks above.

This needs a slang fix before launch. Every say instance under a login
flood is exposed to it. Until then, keep `HASH_QUEUE` small, put
connection limits at the load balancer, and alert on `/readyz`.
