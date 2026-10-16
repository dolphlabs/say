# say — Matching Engine Implementation & Verification Specification

**Version:** 1.0 | **Date:** 2026-10-16 | **Backend:** slang + zokor

## 1. Module layout

```text
internal/exchange/domain/         market, order, position, price, fills, errors
internal/exchange/book/           ordered price levels, FIFO queue, order index
internal/exchange/match/          deterministic transfer/mint/merge matching
internal/exchange/ledger/         signed postings and validation
internal/exchange/admission/      risk, idempotency, wallet reservation
internal/exchange/runtime/        slang per-market actor, ownership epochs
internal/exchange/persistence/    PostgreSQL transactions, snapshots, replay
internal/exchange/stream/         committed outbox, Redis fanout, WS schema
internal/exchange/settlement/     evidence, disputes, approval, redemption
internal/exchange/treasury/       seasons, issue 1000, maker allocations
internal/exchange/testing/        model oracle, generators, failure scenarios
apps/say-api/                      zokor REST + auth + WebSocket
apps/say-admin/                    operator policy and approval endpoints
apps/say-bots/                     adaptive reference/inventory quoting
```

Paths are proposed; use validated slang module conventions rather than interpreting them as confirmed syntax. The pure matching module must not know Redis, PostgreSQL, clocks, or networking.

## 2. Types and arithmetic

`MarketPolicy { V_m, min_price, max_price, tick, min_original_notional=2, fee=1 }`
`Order { id, account, beneficial_owner_group, outcome YES|NO, side BUY|SELL, limit_price, qty, remaining, tif GTC|IOC, created_seq, fee_posted }`
`Book { four directions, price-level ordered queues, order_id index, committed_seq, book_seq }`
`Transition { fills, order_deltas, wallet_deltas, inventory_deltas, collateral_deltas, fee_deltas, result_state_hash, book_deltas }`

Use signed checked integer arithmetic. Price is immutable per market quote, not an unbounded probability percentage. Winning redemption is quantity × `V_m`; user net PnL includes purchase/sale prices and fees. For example V=200, buying three YES at 120 with S1 fee costs 361, winning returns 600, net +239; losing returns 0, net −361.

## 3. Execution candidate enumeration

For incoming BUY YES: (a) resting SELL YES transfer at acceptable price; (b) resting BUY NO mint if `YES_limit + NO_limit >= V_m`. For incoming SELL YES: (a) resting BUY YES transfer; (b) resting SELL NO merge if seller minimum proceeds requirements can be satisfied by `V_m`. All NO commands mirror these paths. No candidate may use the same reserved order quantity twice.

Every eligible candidate is converted to a comparable **effective YES price** with an admissible taker limit. Rank by best price for taker, then oldest maker accepted sequence, then immutable maker order ID to ensure deterministic ties. For equivalent price paths, do not prefer mint/merge merely because one is cheaper to implement. Each execution is charged at maker's accepted limit, and any complement difference is assigned to taker (the resting maker never receives taker surplus). Audit the exact currency amounts for each execution path.

## 4. Engine pseudocode (language neutral)

```text
match(state, cmd):
  assert cmd.seq == state.committed_seq + 1
  if market closed or order invalid -> reject/cancel with reason
  if command is cancel -> release unfilled reservations; emit state change
  if incoming order: check market range, tick, amount >= 2, collateral and fee reserves
  while incoming.remaining > 0:
    candidates = eligible_native_and_complementary_makers(incoming, state)
    rank candidates by taker effective execution price, maker FIFO seq, maker id
    if no candidate: break
    maker = first(candidates)
    if linked_beneficial_owner(maker, incoming):
       cancel incoming offending remainder (CANCEL_NEW); emit self-trade audit; break
    price = maker_price_normalized_to_execution_path(maker, incoming, V_m)
    if price < min_price or price > max_price or not on_tick(price):
       cancel offending execution attempt; emit PRICE_OUT_OF_BAND; break
    qty = min(incoming.remaining, maker.remaining, collateral_and_inventory_capacity)
    post deterministic TRANSFER or MINT or MERGE candidate; post first-fill fee once/order
    reduce reserved quantities and increment executed amounts
  if IOC: cancel residual
  else if GTC: rest residual with FIFO priority
  verify conservation, order and collateral invariants, produce immutable transition
  return transition (uncommitted until DB commit)
```

IMPORTANT: for complementary orders, canonical maker price and taker improvement allocation must be defined and tested symmetrically in both YES/NO directions. Implement only after a small mathematically precise oracle passes exhaustive combinations for V=10 and all legal ticks.

## 5. Price band rule

Market band `[min_price,max_price]` fixed at approval. A user-submitted limit outside range is rejected at admission. An internally computed price (e.g., `V_m - complementary_bid`, or a bot quote) outside range causes a cancel/rejection of the offending execution/quote, not clipping to nearest bound. No fill at out-of-range prices.

## 6. Account and order lifecycle

`RECEIVED -> ADMITTED -> OPEN/PARTIAL -> FILLED` or `CANCELLED`, with `REJECTED` from pre-admission and terminal `EXPIRED` at market/season end. One market command queue gives deterministic ordering; cancellation cannot undo prior fill. `202 Accepted` indicates durable admission, not fill; `/orders/{id}` resolves state. Partial fills retain reserve for remaining quantity and unpaid first-fill fee only until first fill.

## 7. Deterministic matching examples

**A transfer:** Maker SELL YES 1 @60; taker BUY YES limit 75 -> fill @60; taker gets improvement 15; fee 1 for each previously unfilled order.

**B mint:** `V_m=100`; maker BUY NO @45, incoming BUY YES limit 70 -> mint one set; maker contributes 45, taker contributes 55 (improvement 15 vs max budget), custody locks 100.

**C merge:** `V_m=100`; maker SELL NO min 40, incoming SELL YES min 50 -> merge a YES and NO pair; maker receives 40, taker 60 (improvement 10).

**D self-trade:** same beneficial-owner group controls maker and taker -> cancel incoming remaining, no fill and no fee.

**E invalid derived price:** `V_m=100`, allowed 5..95, maker complementary quote implies YES=97 -> cancel/reject attempted calculation, no fill.

**F variable redemption:** Market A `V_m=50`, Market B `V_m=200`, both use identical engine, but cannot share collateral or price ranges.

**G min notional:** BUY 1 contract @1 is rejected (S1); BUY 1 @2 passes but preview shows S1 fee.

## 8. Runtime integration with slang

One owner task per market; bounded command channel contains hints, durable PostgreSQL commands hold truth. Actor processes sequentially: load next durable command -> pure match -> single SQL commit with owner fencing and market state hash -> update memory -> outbox notification. Do not block on WebSocket sends; route via fanout workers and Redis. Do not use task scheduling alone as market ownership lock across processes.

## 9. Property tests and acceptance gates

Generate random legal order sequences for V in {10,50,100,200}; vary price ticks and bands. Assert `(outstanding YES=outstanding NO)`, `(collateral=V×pairs)`, ledger zero sum per asset, no negative available or reserved assets, no duplicate fills or idempotency results, no fill out of market band, no self fills, taker receives all price improvement, fee only once/order, snapshot replay produces same state hash. Include simultaneous user orders in distinct markets to prove wallet-reservation isolation.

Failure scenarios: actor crash before/after commit, Redis offline, outbox at-least-once delivery, stale epoch takeover, delayed database commit, season boundary in Africa/Lagos, 30-minute evidence dispute, super-admin-only finalization, and void refusal until refunds are solvency-defined.

Performance scenarios: 1 hot market at 80% traffic, 1000 balanced markets, 10k WS sockets, 30-minute endurance, cancellation storms, increasing commit latency. Measure order admit p50/p99, durable fill p50/p99, fanout p99, peak RSS/GC pause, actor runnable latency and replay time. Baseline against a separate reference implementation to distinguish slang runtime bottlenecks from database design.

## 10. Release blockers

1. Void policy for secondary trades is ambiguous: refunding all gross historical purchase principals double-counts amounts when contracts have been sold and bought again. Need a mathematically solvent compensating-accounting policy, including fee treatment and realized resales. Do not enable void payout until resolved.
2. Confirm per-market redemption values and permitted price-band constraints in operator tooling; no market opens without them.
3. Finalize initial season anchor instant in Africa/Lagos, and verified-account qualification and abuse controls.
4. Verify actual slang/zokor support for transactional APIs, channels, cancellation and WebSocket backpressure before calling sample signatures production code.
