# Registry validation and performance

Measured 2026-10-27, installed slangc0.2.3, default compiler flags, Darwin
x86_64 and local Docker PostgreSQL16. SLANG_WORKERS=2 for the performance
runs; no CPU affinity or isolated-hardware claim. Existing OpenSSL and
generic-instantiation compiler warnings remain.

| Check | Result |
|---|---|
| Domain validation/role/transition/hash tests | 5 passed |
| Service validation/cache generation/filter tests | 3 passed |
| HTTP integration plus serialization tests | 3 passed |
| PostgreSQL lifecycle/races/isolation/immutability | 3 passed before load additions |
| Expanded PostgreSQL suite with leadership/catchup/load | 5 passed |
| Warm1,000-market list,500 samples/100 warmups | p50 0.472ms; p99 1.406ms |
| Warm1,000-market detail,same sample counts | p50 0.035ms; p99 0.300ms |
|1,000 real markets,200 deadlines/s over0–4s,8 workers | All committed closed; maximum cohort-completion lateness upper bound388ms |

Cache data was an explicit in-memory benchmark fixture with1,000 markets,
half having synthetic stats. Requests went through the real router and
handlers; setup/warmup were outside the timing. This is a warm-cache
microbenchmark, not an end-to-end network/gateway load result. A regression
assertion closes both database pools before timed cache reads.

Closing fixtures were created, independently approved and opened through
the actual transactional registry adapter in disposable migrated databases.
The benchmark used the same due scan and bounded advance_batch routine as
the scheduler. It conservatively measures completion of the entire batch
against its earliest newly due market; individual commits occur no later
than this upper bound. It includes handoff work and a50ms harness poll.
Leadership contention and boot overdue-scan behavior are tested separately;
this is not a claim that a two-node process-kill rehearsal ran.

The first close run failed at2239ms. Replacing repeated scheduled-transition
round trips with one atomic CTE retained the season guard, market version
CAS, update, audit and outbox, and reduced the measured upper bound to388ms.
The general human-mutation path still performs full validation/authorization.

The required make check passed with network access, including the existing
email timeout test. Its earlier denied-connect failure was sandbox-specific.
Database integration runs explicitly set both test database URLs; load gates
also set MARKET_LOAD=1. No skipped integration run counts as passing that gate.

Reproduce with local docker-compose.test.yml and both test URLs:

```sh
MARKET_LOAD=1 SLANG_WORKERS=2 slangc test src/markets/store
MARKET_LOAD=1 SLANG_WORKERS=2 slangc test src/markets/server
```

Re-run these gates after later modules alter admission/market locking,
snapshot payloads, governance authorization or finalization. Full exchange
trading and whole-system rehearsal measurements remain separate gates.
