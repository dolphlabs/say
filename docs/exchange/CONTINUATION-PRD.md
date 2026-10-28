# Prompt 05 continuation: requirements and technical baseline

Date: 2026-10-28. Scope: finish the exchange runtime described in
[RUNTIME.md](RUNTIME.md), preserving the previous agent's working changes.
The approved runtime design remains the product and accounting contract.

The repository is a single-tenant Slang/zokor service. Authentication,
season issuance, the double-entry ledger, registry lifecycle, and a pure
matching engine already exist. Exchange services express admission,
ownership, recovery and actor use cases through ports; PostgreSQL adapters
implement them. `platform/app` composes the service and background workers.
The matching core must remain independent of HTTP, PostgreSQL and Redis.

## Required user and operator outcomes

- A valid order atomically reserves funds/shares and queue capacity. A retry
  returns the same order, including after closure or a changed quote.
- One independently scheduled actor per owned market processes committed
  commands in admission-ID order. A slow market cannot stop other markets
  or ownership heartbeats. Every financial transition is fenced at commit.
- HTTP waits a bounded interval for a committed result, otherwise returns
  an explicit pending acknowledgement. Private reads stay account-scoped.
- Recovery verifies durable decisions, inventory and projections before
  publishing a usable view. An uncertain commit forces recovery before any
  further command. Capacity growth remains bounded.
- Registry suspension/resume/close and season closure produce durable core
  commands. Close rejects pending placements and releases all resting holds;
  filled positions remain available for later settlement.
- Public views describe actual committed sequence domains and pending work.
  Cross-node hydration cannot overwrite a newer view with an older one.
- Outbox retry preserves audience, event identity and source ordering through
  PostgreSQL/Redis failures without blocking a matching transaction.
- Reconciliation uses a consistent database snapshot and checks journal,
  wallets, supply, collateral, fees, positions, live order holds and queue
  permits. Financial drift halts admission/fills while permitting cleanup.

## Baseline gaps found during continuation review

The existing supervisor serializes discovery, recovery, heartbeats and every
market's command batch. No registry-to-core lifecycle enqueue is present.
Actor errors retain the potentially stale in-memory book. HTTP immediately
returns ADMITTED without its designed reply interval. Local views use the
command sequence as both book sequence and pending count. Recovery genesis
uses current issued supply rather than the initial supply. The existing
exchange server test checks only request shape; real financial HTTP,
process-fault and runtime load acceptance still need evidence.

## Verification and delivery

Extend the isolated PostgreSQL/app-role/Redis suite with real admission,
matching, cancellation, restart/replay, lifecycle and concurrent-budget
checks. Add reproducible process-fault and load harnesses for the acceptance
matrix in RUNTIME.md section 9, and record measured results separately from
unrun gates. Run `make check`, integration checks and relevant changed-area
tests. Publish API/runtime validation documentation and update
`docs/IMPLEMENTATION.md` with exact remaining limitations. Prompt 06 and
later prompts remain outside this continuation.
