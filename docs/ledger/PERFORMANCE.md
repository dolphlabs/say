# Ledger performance

Measured 2026-10-21 (final run, after every fix in DESIGN.md §7) with slang from `dev` (with dolphlabs/slang#447–#450).
The tests are `src/ledger/store/load_test.sl` (`LEDGER_LOAD=1`) and the hot
account test in `jobs_test.sl`.

**Setup:** macOS, 8 cores. Postgres 16 runs in Docker Desktop
(`make test-stack`, tmpfs, no fsync cost) and is reached through Docker's
port forwarding. Every number includes that hop:
- one `select 1` round trip is about 0.7 ms (1,380 a second on one
  connection);
- 32 connections reach about 12,500 a second.

The numbers are relative, not production capacity. On a host with Postgres
on the same network, round trips are about 0.1 ms and every figure below
improves.

## Results

| What | Result | Target |
|---|---|---|
| Rollover, 100k accounts, 4 workers, chunks of 500 | **70 s** (1,430 grants/s) | under 2 min |
| `GET /v1/me/balance` read, 1 connection | p50 0.8 ms, p95 1.5 ms, p99 2.0 ms | — |
| The same, 32 concurrent | p50 3.1 ms, p95 6.2 ms, p99 10.7 ms, 8,194 reads/s | — |
| `post` (a transfer), 32 concurrent over only 20 wallets | p50 44 ms, p95 331 ms, p99 534 ms, 360/s | — |
| 5,000 grants, 32 concurrent, insert-only issuance wallet | 14.8 s, **336/s** | — |
| The same, issuance wallet locked first (the rejected design) | 95.8 s, **52/s** | — |

## Reading it

- **Hot account.** Insert-only system wallets make concurrent grants about
  6.5 times faster than locking the issuance wallet (several runs: 329–381/s
  against 52–57/s). Under the locking design,
  every grant in a season queues behind one row; prompt 01's code worked
  that way. What remains for a single grant is about 18 round trips, at
  roughly 2.5 ms each through Docker under load.
- **Rollover.** It costs about ten round trips per chunk of 500, because
  `post_many` is batched. The remaining time is the claim insert and the
  entry rows themselves.
- **Balance.** One indexed read, sub-millisecond on one connection. The
  prompt said to measure before adding a Redis cache. A cache would save
  little and would add an invalidation path, so there is none.
- **`post` under contention.** That test makes 32 workers fight over 20
  wallets, so most postings wait for a wallet row another one holds. The
  tail is queueing on those row locks, which is the price of never letting
  a balance go negative. Real traffic spreads over many more wallets.
  Concurrency test 2 (1,000 crossing transfers between 10 wallets) shows
  the lock order holding: no deadlocks, and every transfer posted.

## Concurrency tests (integration, `make test-integration`)

| Test | Result |
|---|---|
| 1. 200 parallel holds of S 7 on S 1,000 | exactly 142 posted, 58 `InsufficientFunds`, free 6, held 994 |
| 2. 1,000 crossing transfers among 10 wallets | 1,000 posted, 0 deadlocks, total unchanged |
| 3. One business key posted 50 times in parallel | one transaction; a changed payload is `IdempotencyConflict` |
| 4. Hot system account | above |
| 5. Verification and rollover granting the same account, 20 rounds | exactly one grant each time |
