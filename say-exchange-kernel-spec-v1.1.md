# say — Exchange Kernel Specification

**Version:** 1.1 (decisions incorporated; implementation specification)  
**Date:** 2026-10-16  
**Product:** say (lowercase)  
**Runtime/framework:** slang + zokor  
**Status:** Architecture proposal, not audited production code

## 1. Purpose and boundaries

The kernel is the authoritative execution, contract inventory, and settlement subsystem for a virtual-credit binary prediction exchange. It is designed both to run say and to be reusable independently of say's front end, seasons UI, or leaderboards. Its correctness must not depend on Redis, WebSocket delivery, or a market maker remaining online.

**In scope:** market lifecycle, order admission and cancellation, deterministic matching, YES/NO pair mint and merge, trading balances and reservations, position accounting, fees, settlement, recovery, outbox events, runtime invariants, and execution/risk controls.

**Out of scope:** social UX, leaderboards beyond reliable event feeds, cash-out, fiat payments, leverage, margin, lending, options, on-chain custody, and real-money regulations. An initial points-only model does not independently guarantee legality in every jurisdiction.

## 2. Confirmed decisions and defaults

| Subject | Decision |
|---|---|
| Name | say |
| Virtual currency | sedis |
| Initial allocation | 1,000 sedis for each eligible new user |
| Competition | Consecutive 14-day seasons based on Africa/Lagos (UTC+01:00), season-isolated balances |
| Open market scope | Curated admins and approved creators |
| Outcome | Binary YES/NO |
| Liquidity | Platform-funded adaptive inventory-aware market makers |
| Trading fee | 1 sedi once per executed order |
| Resolution | Automated evidence collection, human decision/approval |
| Persistence | PostgreSQL authoritative, Redis for ephemeral functions |
| Streaming | WebSocket with REST admission |
| Architecture | Single writer per market, logically separable exchange kernel |

**Confirmed policy parameters:** fee `F=1` sedi once per order at first fill; minimum original order notional `S 2`; per-market immutable winning-contract redemption `V_m` set at market approval; maker price on execution, all feasible price improvement to taker; related-party self matches cancel instead of executing; void returns original paid trade principal, with separate treatment of previously sold positions and fees specified in section 16; season times and UI in Africa/Lagos (UTC+01:00); evidence dispute window 30 minutes; super admins make final resolution decisions; cancel/reject price computations outside configured allowed price interval. **Further implementation parameters:** per-market `V_m`, permitted tick and price bands, season epoch, bot budget, precisely defined void accounting for secondary trades and prior withdrawals. These are market/policy configuration rather than hardcoded constants.

## 3. Core domain model

- `Season`: id, starts_at, ends_at, status (`SCHEDULED`, `ACTIVE`, `CLOSING`, `CLOSED`, `FINALIZED`), finalization_version. Time windows are half-open `[starts_at, ends_at)` in UTC.
- `Wallet`: account_id + season_id + currency, available, reserved; treasury, fee, and collateral accounts exist in the same accounting namespace but have separate authorization policies.
- `Market`: id, season_id, statement, terms_version/hash, category, cutoff_at, scheduled_resolution_at, approved_source_policy, status, trading_owner_epoch, committed_seq, last_snapshot_seq.
- `Outcome`: YES or NO, exactly one of which wins in a valid settled binary market.
- `Position`: season_id + market_id + account_id + outcome, free_quantity, reserved_quantity, settled_quantity (with auditable inventory journals).
- `Order`: id, client/idempotency identity, account_id, market_id, outcome, `BUY|SELL`, limit_price, original_quantity, remaining_quantity, reserved_assets, fee_charged, time_in_force, status, accepted_seq, created_at.
- `Fill`: globally unique id, market_id, execution_seq, maker_order_id, taker_order_id, quantity, YES-equivalent price, execution_mode (`TRANSFER|MINT|MERGE`), transaction_id.
- `CollateralSet`: market_id, complete_sets_outstanding, collateral_units_locked; supply and collateral changes are journaled atomically.
- `LedgerTransaction`: unique transaction id, entries in same unit/asset, metadata and idempotent business reference. A transaction's entries sum to zero for each individual asset.
- `OrderCommand`: immutable submitted instruction, admission/result state, market-local durable sequence, stable payload hash.
- `OutboxEvent`: unique event id, aggregate, committed_seq, type, payload, delivered_at (delivery is retryable).
- `MarketResolution`: proposed outcome/evidence digest, approval identity/time, disputes/void rationale, immutable final decision id.

### 3.1 Monetary and quantity representation

Use checked 64-bit signed integers (or a wider explicit checked type if exposure bounds require it). Prices and market-specific contract redemption values are integer sedis per contract. A user's realized net result depends on position quantity, execution price, fees and whether the predicted outcome wins. Display probability is derived from a price divided by the market redemption value; it is not an additional multiplier on redemption. Never use floating point for credit movement, rounding, collateral, or fee calculation. All multiplication and sums require overflow checks. Probabilities in UX are interpretations, not price storage primitives.

## 4. Accounting and invariants

**Currency accounts:** user free/reserved; treasury free/reserved; market collateral custody; protocol fee revenue; authorized issuance offset. The exact chart of accounts may vary, but every sedi movement is an explicit double-entry transaction. Seasonal currency issuance credits the user and debits a named issuance/equity account; issuance authority and totals are audited.

**Contract inventory:** YES and NO are distinct non-currency assets with per-market inventories. Creation credits one unit each against authorized issuance/clearing entries. Transfer moves inventories between owners; merge burns both. Asset-specific inventory journals reconcile to issued minus burned supply; do not add YES and NO quantities to sedis when testing ledger balance.

Required invariants following every committed transition:

1. Every ledger transaction balances to zero **per asset**.
2. Free and reserved user balances are nonnegative; reserved and free outcome inventory are nonnegative.
3. Total outstanding YES units == total outstanding NO units == unredeemed complete sets for a market, including escrowed positions.
4. Sedi collateral custody == `V * outstanding_complete_sets` per market (excluding pending/failed transactions, which must not be committed as partial states).
5. Each fill has a unique `(market_id, execution_seq, fill_index)` or stable equivalent and exactly one financial posting.
6. Credits or inventory reserved by an order cannot be reused for another concurrent market/order.
7. An order's executed quantity + remaining quantity + cancelled remainder == original quantity; partial transitions cannot increase the original size.
8. Fees are charged **once per order that receives a first fill**, if that fee policy is adopted; zero-fill cancellation pays no trade fee.
9. Position settlement happens at most once by unique settlement business key and only following authorized resolution.
10. An actor's externally published book sequence never exceeds the highest financially committed sequence.
11. A market can have at most one valid fenced execution owner for any epoch.
12. Trading never crosses season namespaces or uses old-season balances in a new season.

### 4.1 Example: mint one pair

For a market with `V_m=100`, a YES buyer pays 60 and a NO buyer pays 40 (both plus independently posted applicable fees): debit buyers' available/reserved credit positions, credit market collateral custody by 100, issue one YES to buyer A and one NO to buyer B. Collateral must not include fee revenue. On a winning YES resolution, redeem the YES for 100 from custody; redeem NO for zero and retire all outstanding outcome units. Void means return each eligible trader’s actual paid order principal rather than a winning-contract redemption. Crucially, a naive refund of every historical buy is insolvent after secondary trading or sales: implement a reversible-trade netting/compensation workflow with a funded treasury loss/guarantee account, no double refunds, and reversal of sold positions; otherwise halt void automation pending the precise policy in section 16.

### 4.2 Example: inventory transfer

An existing YES holder sells one YES at 60. Buyer pays 60, seller receives 60, YES inventory transfers. Collateral backing the complete set stays unchanged. Fee is posted as an additional independent balanced credit transfer on each order's first execution if applicable.

### 4.3 Example: merge

A YES seller is willing to receive 55 and a NO seller 45. Their units are retired; custody releases 100, distributed 55/45, plus separately accounted fees. This does not create any new sedis or contracts.

## 5. Orders, priorities, and matching

### 5.1 Supported commands and validation

Commands: `PlaceLimit`, `CancelOrder`, `CloseMarket`, `MintCompleteSets` (privileged or matched), `MergeCompleteSets` (privileged or matched), `RecordResolutionApproval`, `SettleMarket`, `SuspendMarket`, `ResumeMarket`, `Snapshot`. Marketable limit orders provide a beginner-friendly fast action without unbounded market order slippage.

Place order fields: authenticated account, market, side (`BUY|SELL`), outcome (`YES|NO`), limit price 1..99, positive integer quantity, time-in-force (`GTC|IOC` initially), stable idempotency key. No naked short selling. Buying reserves worst-case limit-price cost plus any as-yet-unpaid flat fee; selling reserves the specified outcome inventory plus any fee from spendable sedis. In a merge fill the sell proceeds cover execution value, but conservatively requiring a fee reserve avoids a fee-induced negative balance.

Orders are rejected if market/season cutoff passed, idempotency key payload conflicts, account lacks assets, limits exceeded, or relevant circuit breaker active. `GTC` rests unfilled residual; `IOC` cancels residual within the same execution command. Cancellation racing with a fill follows **market command sequence order**; neither can retroactively undo a committed fill.

### 5.2 Matching paths and canonical prices

Use four economic directions (`BUY YES`, `SELL YES`, `BUY NO`, `SELL NO`) with one market-local matching authority. A YES-normalized effective price permits synthetic opposite-side quotes but does **not** authorize treating one order as two independent units of liquidity.

- `BUY YES` + resting `SELL YES` -> direct **TRANSFER**.
- `BUY YES` + resting `BUY NO` -> **MINT** a fully collateralized YES/NO pair when `YES_limit + NO_bid >= V`.
- `SELL YES` + resting `SELL NO` -> **MERGE** if requested proceeds together are <= V.
- Symmetric paths apply for NO takers and YES/NO transfers.

For a `BUY YES` taker and resting `BUY NO` maker bid at 45, YES's effective ask is `V - 45 = 55`. If the YES limit is 60 or higher, the maker receives one NO for 45, taker receives one YES for 55; the entire 100 is locked. The difference between taker's limit and 55 is released, not captured by the exchange. For a `SELL YES` maker at 55 paired with an incoming `SELL NO`, the NO taker receives `V - 55 = 45`; the sellers' contracts are merged and collateral released.

**Priority:** Determine the *best effective executable price* across eligible direct and synthetic counterparties; within that effective price choose the resting order with the earliest market-local acceptance sequence, with order id as a deterministic final tie-break. Execute at resting maker's effective price, pass price improvement to taker, and proceed across levels until filled or no eligible match remains. Self-trade prevention is applied before execution and must not allow priority bypass. The engine must decide and specify whether prevention cancels the taker, maker, or decrement-and-cancels; default proposed policy is reject/cancel taker remainder on own-group crossing. Fill records retain original orders and mode, never just synthetic quote identifiers.

**Mirrored book invariant:** One actual order may be displayed as a native or complementary synthetic quote in the appropriate view, but its remaining quantity and reservation are counted **once**. Snapshot and delta generation must derive native/synthetic views from a single underlying order identity to avoid double count.

### 5.3 Fees and partial fills

Confirmed F=1 sedi once at the first non-zero fill **per participating order**. Fees are not incurred when placing, modifying, cancelling, or rejecting an unfilled order. For a fill between two as-yet-unfilled orders, each account pays 1 sedi; an order that already paid its fee does not pay again on subsequent fills. Multi-fill transaction groups must mark `fee_charged` atomically with actual fee transfer. Minimum original notional is S 2; validate it at admission using quantity × specified limit price. At S 2, the 1-sedi fee can still be 50% of notional; disclose this prominently in pre-trade preview. On every matched order, reserve one additional sedi until fee paid or order terminated.

### 5.4 Pure matching interface

The deterministic core takes immutable market state plus one sequenced command and returns a candidate transition: changed orders/book levels, fills, changes in available/reserved balances and contract inventories, collateral mint/merge operations, outbox facts, and a resulting state hash. It must have no network, Redis, clock, logging, or database calls. Runtime adapters validate and commit the transition before exposing its new state.

Illustrative signatures (language-neutral, **not verified slang syntax**):

```text
admit(command, account_state, market_policy) -> AdmissionDecision
match_one(book_state, sequenced_command) -> ProposedTransition
verify_transition(state, proposal) -> InvariantResult
apply_committed_transition(state, proposal, commit_receipt) -> NewState
replay(snapshot, committed_events) -> RebuiltState
```

## 6. Command and commit protocol

1. **HTTP gateway** authenticates and validates syntax, rate limits, checks required idempotency key.
2. **Durable admission transaction** locks relevant account reservation rows in a globally consistent lock order, enforces policy, records order identity/payload hash and reserves maximum required assets. If the response is lost, the client can query status using the stable idempotency identity.
3. **Queue and sequence**: accepted commands are durably ordered per market; the actor's bounded mailbox holds work hints, not the only copy of accepted commands.
4. **Compute**: the market actor loads the next accepted command and deterministically derives candidate fills, cancels, and book changes from the last committed state.
5. **Atomic commit**: one PostgreSQL transaction verifies owner fencing epoch and expected market version, applies order/ledger/positions/collateral/fee deltas, inserts unique fills, advances market committed sequence, and creates outbox events. All-or-nothing. Failure -> actor discards candidate and reconciles durable state; no phantom visible fill.
6. **Confirm**: order final or accepted/working status is returned or made queryable only from durable records. REST returning `202 Accepted` means admitted, not necessarily filled; `200/201` with explicit final state means that state is committed.
7. **Publish**: a retryable outbox worker distributes committed deltas to Redis and WebSocket fan-out; Redis is not a ledger of record.

**Crash windows to test:** admission committed before actor receives hint; commit succeeds before actor memory advance; commit succeeds before outbox delivery; actor lease expires during DB transaction; publication succeeds then outbox ack fails; client request times out after admission; concurrent market orders attempt to reserve the same user's funds.

**Batching policy:** Start with one candidate transaction per market command for correctness. Later batch sequential transitions only if each candidate has a durable sub-sequence and the batch preserves atomicity, replay behavior, charge-once fees, and useful latency. Never acknowledge a financial result before its DB commit.

## 7. Market actor concurrency and ownership

A market actor is a slang task that exclusively mutates the in-memory order book for one market within its current ownership epoch. No other task may mutate that market's state directly. The actor receives bounded commands through a channel and uses non-blocking/offloaded delivery to WebSocket publishers. Database access may suspend that actor while awaiting commit; this is safe for ordering, but limits per-market throughput. To prevent starvation and runaway memory, use bounded admission queues, admission rejection/429/503 with retry semantics, fair scheduling measurements, and per-market load isolation.

**Single ownership across processes:** persistent assignment, monotonically increasing fencing token/epoch, checked by *every* financial write. Redis leases may help coordinate but must not override the epoch verified inside the PostgreSQL transaction. Only one writer may commit for any epoch. Graceful migration closes admissions, commits through a known sequence, snapshots, transfers epoch and resumes. Crash recovery reloads durable state and acquires a new epoch.

Other tasks: admission workers, ledger queries, websocket gateways, settlement workers, admin operators, outbox workers, bot API clients, metrics/telemetry. No mutable order-book data is shared without immutable messages, versioned snapshots, or explicit ownership transfer.

## 8. WebSocket stream and Redis

REST:

```text
POST   /v1/markets/{id}/orders          Idempotency-Key mandatory
DELETE /v1/orders/{id}                  cancel request, idempotent outcome
GET    /v1/orders/{id}
GET    /v1/markets/{id}/book             snapshot, market_seq, owner_epoch
GET    /v1/markets/{id}/trades
GET    /v1/me/positions
GET    /v1/me/ledger
GET    /v1/seasons/current
WS     /v1/stream                       subscribe market/public and authenticated private channels
```

WebSocket event envelope (illustrative):

```json
{
  "event_id":"evt_...",
  "market_id":"m_...",
  "stream":"book:m_...",
  "market_seq":1092,
  "owner_epoch":7,
  "type":"book.delta",
  "payload":{}
}
```

Not every committed market command must produce a visible book delta. Either publish a gap-free dedicated `book_seq` for book-changing events (recommended), or include explicit no-op markers; do **not** call missing market-sequence values a broken book stream if intervening commands had no book effect. A REST snapshot returns the same book-sequence domain as the deltas. Client subscribes/buffers, fetches a consistent snapshot, applies strictly later contiguous deltas, and resyncs on a gap, overflow, or unknown owner epoch.

Redis handles subscription distribution, quote caches, rate limits, and ephemeral presence. Use PostgreSQL outbox for durable event publication. Gateway queues are bounded; slow clients receive coalesced non-critical book updates only when correctness is preserved, otherwise a resync-required notification or disconnect. Never silently coalesce private fills or account ledger events in a way that suggests exactly-once end-user delivery. Clients dedupe by event id and recover private state using REST.

## 9. Market lifecycle, seasons, resolution

Statuses: `DRAFT -> REVIEW -> APPROVED -> FUNDING -> OPEN -> CLOSED -> RESOLUTION_PENDING -> RESOLVED -> SETTLING -> SETTLED`, with guarded branches `SUSPENDED`, `DISPUTED`, and `VOIDED` (void semantics explicitly defined later).

**14-day season:** time boundaries defined in `Africa/Lagos` (UTC+01:00) using half-open intervals and stored as UTC instants in PostgreSQL; contiguous next season. Every market belongs to exactly one season. Normally scheduled resolution and trading cutoff occur before end; exceptionally unresolved markets stay attached to old-season ledger and collateral. At season cutoff cancel all GTC order residuals and release reservations. New-season 1,000-sedi allocation is posted to new namespace independently of old-season positions. Archived leaderboard remains provisional until old-season settlement is complete; do not show provisional results as final.

**Resolution pipeline:** defined source policy and unambiguous market terms -> automated evidence retrieval and append-only evidence digest -> human approval by authorized resolver (dual approval for high-risk/disputed markets) -> immutable resolution decision -> idempotent settlement job -> per-account payout/position retirement -> reconciliation -> terminal settled status. Void requires an authorized super-admin decision and explicit ledger compensation rules; do not erase fills or silently reverse settled transfers.

## 10. Adaptive liquidity agents and treasury

Agents have explicit account IDs, limited seasonal starting balances/inventory, per-market notional caps, global loss/drawdown caps, outstanding-order caps, cancel/replace rate limits, source freshness checks, and suspend switches. They submit regular public-order-path limit orders; no direct write access to match state or ledger. Bot identification and self-trade prevention apply across related accounts.

Pricing components: reference probability estimator, exposure/inventory skew, spread and quantity control, execution adapter. Inventory checks consider both YES and NO positions, cash, reserved order obligations, and payout-state worst-case exposure. A paused maker does not imply paused market, but administrative suspension must prevent new trading if market integrity becomes uncertain.

Treasury credit issuance is privileged, auditable, bounded, and separately approved; virtual money does not justify unlimited mint permissions. Segregate the treasury's market-making cash from collateral already pledged to outstanding complete sets.

## 11. Schema and database constraints (logical)

Recommended primary tables: `seasons`, `accounts`, `wallets`, `markets`, `market_terms_versions`, `market_owner_epochs`, `orders`, `market_commands`, `fills`, `positions`, `collateral_balances`, `ledger_transactions`, `ledger_entries`, `resolution_evidence`, `resolution_decisions`, `settlement_jobs`, `outbox_events`, `idempotency_records`, `treasury_allocations`, `operator_approvals`, `audit_events`, `market_snapshots`.

Key constraints/indexes:
- Unique `(account_id, endpoint_scope, idempotency_key)` with stored request hash and response/result reference; repeated same request returns existing identity; conflicting payload returns 409.
- Unique `(market_id, accepted_seq)` for market commands; unique `(market_id, execution_seq, fill_index)` for fills.
- Unique `(market_id, settlement_decision_id, account_id, outcome)` for redemptions or finer-grained stable business keys.
- Checked nonnegative balances and quantities. Ledger entry integrity is enforced at transaction boundary with explicit invariant queries, not only application checks.
- Market sequence advancement and owner-epoch validation occur under a locked versioned market row in the committing transaction.
- Referential integrity between fills, orders, journal references, contract issuance/redemption, and resolution approvals.
- Snapshot includes market state hash and covered committed sequence, and is verified before use.

Use deterministic lock ordering for wallet rows to mitigate deadlocks; handle SQL serialization/retry safely via stable business keys. Ledger aggregation and order-book events should be derived from committed records only.

## 12. Error codes and operations

Common operational result classes: invalid request, unauthorized, insufficient credits, insufficient inventory, market closed/suspended, invalid season, idempotency conflict, rate limited, queue full/retry later, stale ownership epoch, stale snapshot/stream gap, resolution not approved, temporarily unavailable. A request is never ambiguously described as filled merely because it was admitted.

Administrative duties: configure seasons, approve markets/creators, set bot and treasury policies, pause/resume markets, approve evidence-based outcomes, perform controlled accounting adjustments, inspect reconciliation reports, and audit all privileged actions. Sensitive credit issuance and high-impact resolutions should have two-person approval when feasible.

## 13. Testing and release gates

### 13.1 Deterministic model tests

- Price-time priority between native and complementary synthetic quotes; FIFO ties across both sources.
- Direct transfer, complement mint, complement merge; partial fills and multiple price levels.
- Uncrossed book, price improvement to taker, reservation release, and zero-fill cancellation.
- One-time flat fee across multiple executions; both maker and taker accounting.
- Mirror views never double-count an order's liquidity.
- Self-trade prevention with related bot/admin accounts.
- Overflow, invalid prices, race between fill and cancel.

### 13.2 Property-based and model checking

Generate random multi-account order, cancel, mint, merge, season-close and resolution sequences. After **each committed transition**, verify all invariant classes. Compare slang kernel outputs to a small independent reference implementation in another language. Require deterministic state hash and output event stream across repeated replays of an identical command sequence.

### 13.3 Fault injection

Kill the process after durable admission, before/after commit, before actor memory update, during outbox retry, during maker cancel/replace, and during settlement. Force Redis outage, slow and failed PostgreSQL commits, stale owner epochs, abrupt WebSocket disconnects, and simultaneous order submissions across markets by a cash-constrained account. Assert no lost confirmed trades, duplicate postings, negative balances, unbacked sets, or owner split-brain commits.

### 13.4 Performance profiles and metrics

Profiles: 1 hot market receiving 80% of orders; 1,000 mostly idle markets; live-event burst; cancellation storm; 10,000 open WebSockets; multi-market concurrent wallet contention; database slowdown; restart/replay with large journals. These are **proposed test scenarios**, not promised operating capacity.

Measure admission p50/p95/p99, order-to-fill commit p50/p95/p99, cancel latency, per-market commands/sec, mailbox depth, scheduler runnable latency, database lock/commit time, worker fairness, RSS and GC pauses, outbox delay, book-fanout delay, resync frequency, failed requests, invariant violations, settlement duration, and recovery time. Establish numeric SLOs after baseline measurement and provisioned hardware selection.

### 13.5 Minimum launch acceptance

No observed ledger/inventory invariant violations under randomized and failure tests; deterministic replay parity; no duplicated fill/settlement on forced retry; ability to stop all trading and reconcile; operator-approved settlement; bounded queue memory; demonstrable clean deployment and documented recovery runbook. Numeric throughput targets must be calibrated on measured hardware and a comparable Go reference path.

## 14. Work breakdown

1. Define exact market/order/account schema and decimal-free amount types.
2. Build pure matching reference model and property tests.
3. Implement slang in-memory market actor and transition verifier.
4. Add Postgres admission, reservations, epoch fencing, commit-gated execution, outbox.
5. Implement deterministic recovery, snapshots, and crash harness.
6. Add REST, stream protocol, Redis distribution, and backpressure.
7. Add season allocation/rollover, treasury, funding, settlement and admin audit.
8. Add maker agents, risk controls, load harness and comparative benchmarks.
9. Launch curated markets only after correctness and operational release gates.

## 15. Explicit open questions before code freeze

1. Is 1 sedi per executing order (not per fill) acceptable, and what is the minimum trade notional?
2. Is payout exactly 100 sedis, with 1-sedi price tick and whole-contract lots?
3. Should price improvement always go to the taker and self-trades cancel taker remainder?
4. What specific void policy applies to ambiguous, postponed, or cancelled events (including fees and trading P&L)?
5. How does the first season start in UTC and are new signups during a season credited with a full 1,000 sedis?
6. Are bot treasury allocations fixed per market or periodically rebalanced within global caps?
7. What is the required dispute window and who has final decision rights for sensitive resolutions?
8. How should a season's final rankings handle positions that settle after its 14-day window?

## 16. External conceptual references

- Polymarket archived CLOB documentation: binary complementary mint/merge matching and unified order books: https://archive.is/oTZIh
- Binary exchange order representation: https://www.tvlr.tech/docs/typescript/binary
- NautilusTrader complementary order transformation: https://nautechsystems.github.io/nautilus_docs/latest/concepts/order_book/

These are design references; say's implementation must have its own verified invariants, behavior contract, and tests.

## 16. Final policy resolution and implementation caveats (2026-10-16)

1. **Fee:** `S 1` per order that executes at least once, charged on first fill; no additional fee on later partial fills. Minimum original trade notional is `S 2`; small trades must prominently display effective fee rate.
2. **Variable consumer returns:** Contract payout is **not globally 100**. Each market declares an immutable `V_m` chosen by authorized operators before opening. A winning position receives `quantity × V_m` on settlement; losing positions receive zero. Entry price, quantity, and fees determine profit/loss; the market price divided by `V_m` approximates implied probability. The probability is NOT independently multiplied into winning redemption, because doing so after trading would render collateral unpredictable. If the requested policy is truly dynamically variable redemption at resolution, it requires a different product and matching/collateral model and must not be silently implemented as binary CLOB.
3. **Execution:** price improvement always belongs to the taker. Maker/resting order’s limit determines execution price for same-outcome transfer. Complementary mint uses resting order’s accepted limit and gives residual value `V_m - maker_price` to taker; complementary merge uses analogous split with residual to taker. Enforce limit checks and amount conservation. Related beneficial-owner matches trigger cancel-new (incoming taker residual or offending portion), no fill or fee; record audit reason `SELF_TRADE_PREVENTED`.
4. **Void refunds:** intention is returning actual amount paid for an order, not a standardized redemption. Because positions may be traded onward, a literal refund of all historical purchases double-pays resellers and creates negative positions. Proposed safe implementation: freeze market, cancel orders, calculate user net external cashflows across this market (excluding separately specified fee refund), unwind remaining collateral and inventory, and make explicit treasury-funded compensating transfers so users receive their approved eligible net principal; all totals audited and super-admin authorized. **Blocking issue:** whether trading losses/profits from earlier closed resales are also reversed, whether sellers must repay proceeds, and whether fees are refunded. Until that is defined, do not enable market void execution.
5. **Onboarding and seasons:** verified accounts receive 1,000 sedis once in the current active season. Each subsequent 14-day season allocates 1,000 to each eligible verified user, once per `(account_id,season_id)`. Season starts/ends use Africa/Lagos time (`+01:00`), stored as UTC instants. Define an initial activation epoch and account eligibility/anti-Sybil policy operationally.
6. **Price limits:** configured per market, fixed from opening; order admission rejects out-of-range limits; internal calculations that fall outside the configured range **cancel the affected matching attempt/order** rather than clamp or execute outside bounds. This also applies when spread/inventory logic creates invalid bot prices.
7. **Resolution:** automated evidence, immutable proposal, 30-minute dispute period after publication, final super-admin decision. Allow explicit suspension for disputed or source-incomplete markets; do not auto-settle before window closes.
8. **Payout example:** `V_m=200`, buy 3 YES at 120 each, 1-sedi order fee -> debited 361; if YES wins, redeemed 600; net outcome +239; if NO wins, net −361. Market implied probability at entry ≈60% before spread and fees. This demonstrates variable return without variable collateral after the fact.

### Additional acceptance tests

- Verify per-market `V_m` invariants for `V_m=10`, `100`, and `200`, including exact complement and all ledger balances.
- Taker receives all price improvement in direct transfer, mint and merge; maker never receives unexpected improvement.
- Self-trading across linked accounts emits no fill and cancels using the configured prevention policy.
- Void workflow does not settle until refunds/proceeds rules are fully specified and an audit-calculated solvency guarantee passes.
- Seasonal rollover at 00:00 Africa/Lagos is deterministic under UTC storage and restart.
- A first fill of a S 2 order posts one S 1 fee; later partial fills post none.
- Any calculated price outside immutable market range is rejected/cancelled, never coerced.
