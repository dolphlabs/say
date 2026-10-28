# Implementation progress

Authorized on 2026-10-27: implement prompts 03–10 in order using their
existing PRDs/designs, subject to explicit review gates in each prompt.

| Prompt | State |
|---|---|
| 01 Auth | Existing implementation; regression checks required |
| 02 Ledger/seasons | Existing implementation; integration extensions required |
| 03 Market registry | Implemented registry; cross-module seed/approval integration remains |
| 04 Matching core | Implemented; final verification/reporting in progress |
| 05 Exchange runtime | In progress; design approved 2026-10-27 |
| 06 Live feed | Pending |
| 07 Portfolio/notifications | Pending |
| 08 Resolution/settlement | Pending |
| 09 Treasury/bots | Pending |
| 10 Governance/rehearsal | Pending |

Prompt 05 groundwork: registry opening now creates the market's collateral
and outcome system wallets in the same transaction. Migration 010 adds a
restricted queue-permit lock function so the runtime role can follow the
documented queue-before-wallet lock order without direct budget-table access.
Fresh node incarnations, conditional heartbeat/lease renewal, same-node
ownership renewal, expired-owner epoch fencing and release are implemented
and wired into app startup. A command-queue store now reserves permits and
enqueues control commands transactionally, and captures committed ID
frontiers for bounded ordered pending reads. A commit-gated single-transition
actor service primitive and a fenced Postgres transaction adapter are
present. The adapter commits ledger postings, orders, fills, positions,
statistics, audience-scoped outbox events and persisted top-50 book-view
payloads. Durable Place admission now validates canonical intent, computes
server-owned hold facts, reserves queue capacity, posts holds, creates the
admitted order and command, and records the idempotency link in one
transaction. Durable Cancel enqueue is implemented. The supervisor now assigns markets,
renews leases in bounded batches, recovers books, drains durable commands and
publishes local immutable views. Authenticated Place/Cancel and private order
read routes, plus public book/trades/history routes, are present. A bounded
snapshot writer captures applied state; recovery verifies supported snapshot
checksums and covered journal hashes, tries older snapshots, and replays the
decided suffix, with genesis fallback where the journal remains bounded.
Cross-node view hydration and recovery projection reconciliation are wired;
crash/load acceptance remains pending. The Postgres/Redis integration suite now passes
against the test stack with separate owner and app-role connections. The
three ledger reconciliation checks for outcome supply, collateral and
per-order fees have SQL implementations and are covered by store tests.

Implementation resolves design clarifications within the requested policies;
any remaining source/provider or operational dependency will be recorded
with concrete evidence. No unrun benchmark or staging deployment is complete.

Registry progress: scaffolded layered code, forward migrations 005/006,
pure validation/authorization/lifecycle/hash rules, transactional CAS edits/
independent decisions/immutable terms, public snapshot reads, admin routes,
and scheduled opening/closing/handoff. Five domain and three service tests
passed; two real PostgreSQL transaction/concurrency tests passed. The race
test exposed a stale self-join projection under row locking; selecting the
projection directly with FOR UPDATE fixed it. Further HTTP, recovery/load,
seed and cross-module integration remain. API.md and PERFORMANCE.md record
the actual HTTP contracts and measured gates. Full make check passed with
network access. Warm list/detail p99 were1.406ms/0.300ms. The first close
load missed its gate; a single atomic scheduled-transition SQL statement
reduced the1,000-market cohort-completion lateness bound to388ms; all five
expanded PostgreSQL tests passed. Shared
approval facts now govern issuance policy proposals and votes; legacy vote
history remains read-only, with proposer self-votes excluded from the threshold.


Matching progress: independent Python reference, preallocated Slang price/FIFO
book with bounded UUID index, read-only plan / checked decided apply, all four
accounting modes, exact hold/fee releases, deterministic canonical hashes,
snapshots, restore/growth, decided replay and depth helpers. Eleven Slang domain
tests and two record/replay service tests passed. Exact golden A–J, discard,
restore/replay/tampering and randomized JSON comparisons passed. The reduced
alphabet passed all22,620 sequences through length four (88,428 commands).
The full660-token alphabet passed all436,260 sequences through length two
(871,860 commands). The full length-four space is190,035,292,260 sequences;
the resumable sharded enumerator exists, but that entire space was not run.

One million differential commands passed across124 traces of up to10,000
commands,20 accounts and four spawned Slang workers, with a separate
wallet/hold conservation model and both hashes checked after every command.
The Go core independently passed a10,000-command oracle corpus. Initial
single-market benchmarks measured zero GC and native allocation calls in
ordinary warmed plan/apply and matching Go history hashes. Both languages'
1,000 spawned-market runs completed200,000 commands with the same checksum.
Raw samples, method limits and comparisons are recorded in exchange/BENCH.md.
The authoritative RejectPlace interface releases admission holds while leaving
makers/mode unchanged; exact oracle and decided-replay tests passed. CI is
configured for1M per ordinary run and100 separately seeded 1M nightly shards;
no remote CI execution or deployment is claimed.


Latest integration validation: `make test-runtime` passed all 8 acceptance
tests in an isolated PostgreSQL and Redis environment, including financial HTTP
modes (MINT, TRANSFER_YES, TRANSFER_NO, MERGE), golden cases A–J (48 commands),
cross-market budget concurrency (200 parallel buys across 10 markets with zero
overdraft: S 410 held from S 427, S 17 free), cross-node genesis view hydration,
and all six crash windows (W1 admission kill, W2 commit kill, W3 outbox kill,
W4 lease expiration before final guard rejected by PostgreSQL, W5 Redis append
ack loss with ordered deduplication, and W6 client timeout replay).

All five load profiles in `make bench-runtime` (`tools/runtime/load.py --profile all`)
passed and are recorded in `docs/exchange/runtime-load-results.json`:
- `hot`: 192 admitted, 192 completed, 0 rejected, 0 pending, 0 degraded, health p99 5.9ms, peak RSS 28.5MB, drain 3.6s, reconciliation passed.
- `distributed_1000`: 1,000 markets, 401 admitted, 403 completed, 0 rejected, 0 pending, 0 degraded, health p99 42.7ms, peak RSS 403.9MB, drain 8.8s, reconciliation passed.
- `cancel_storm`: 20 markets, 1,851 completed, 0 rejected, 0 pending, 0 degraded, health p99 4.6ms, peak RSS 43.6MB, drain 4.3s, reconciliation passed.
- `postgres_50ms`: 10 markets with 50ms latency injection, 104 admitted, 104 completed, 0 rejected, 0 pending, 0 degraded, health p99 7.4ms, peak RSS 41.1MB, drain 1.8s, reconciliation passed.
- `redis_outage_60s`: 60.0s Redis outage, 489 admitted, 490 completed, 0 rejected, 0 pending, 0 degraded, outbox drained cleanly in 36.2s, reconciliation passed.

Differential verification (`tools/runtime/differential.py`) validated 1,000
commands across 10 markets in all 4 execution modes (240 MERGE, 90 TRANSFER_YES,
90 MINT, 80 TRANSFER_NO) with 10/10 matching sequence recovery hashes and
complete ledger reconciliation.

