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
The actor, durable admission, commit/recovery and endpoint work remain pending.

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


Latest validation: `make check` passed, including `zokor check` (28 packages),
the package tests, and build. Focused PostgreSQL exchange-store tests (4)
and market-store tests (5) passed. `make test-integration` passed the
exchange and registry checks plus 28 ledger-store tests, but the runner
terminated the full suite during the next package after the ledger tests took
218 seconds; the complete integration suite is not yet verified.
