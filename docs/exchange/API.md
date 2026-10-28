# Exchange runtime API

Prompt 05; implementation contract as of 2026-10-28. All amounts, prices,
quantities and fees use integer units. Authentication uses the existing
session cookie or bearer session. Private responses are `Cache-Control:
no-store`; another account's order is indistinguishable from a missing one.

## Admission and completion

`POST /v1/markets/{market_id}/orders` requires a UUID `Idempotency-Key`.
The account and hold/ownership/sequence facts come from the server.

```json
{"outcome":"YES","side":"BUY","price":40,"qty":3,"tif":"GTC"}
```

`type` defaults to `limit`; `tif` defaults to `GTC` and can be `IOC`.
Market BUY uses `{"type":"market","outcome":"NO","side":"BUY","spend":101}`.
Market SELL uses `{"type":"market","outcome":"YES","side":"SELL","qty":2}`.
Market orders use IOC and derive their protection limit from a fresh book;
the maximum spend includes the one-unit order fee. A limit BUY holds
`price*qty+1`; a SELL atomically holds shares plus its one-unit fee.

Admission commits the order, holds, idempotency record, command and queue
permit together. The request then waits at most the configured 300ms reply
interval, with a separate bounded pool of reply slots. The current
implementation polls account-scoped durable order state at intervals up to
50ms; each read's database deadline is limited to the remaining interval.
There are no timer-sender tasks. A saturated reply pool returns a pending
acknowledgement immediately after successful admission.

An unfinished order returns HTTP 202:

```json
{"order_id":"<uuid>","command_id":"<uuid>","status":"ADMITTED","existing":false}
```

HTTP 200 means execution has committed, including when the committed result
is an unfilled resting order or a rejection. It does not always mean a fill.
It returns the private order representation below, plus `command_id` and
`existing`. `principal`, `filled_qty`, `fee_charged` and `avg_price` describe
actual committed execution. `avg_price` is null before any fill and otherwise
a display ratio; financial storage remains integer. A market order also
includes its `protection_limit`.

The original intent, including market spend, is hashed before normalization.
Identical retries return the same order even after a quote change, closure
or overload; changing the payload returns `IDEMPOTENCY_CONFLICT`/409.
Admission itself has the configured PostgreSQL deadline, independent of the
post-admission reply interval.

## Cancellation and private reads

`DELETE /v1/orders/{id}` durably enqueues an owned cancellation. It returns
HTTP 200 with the committed order if completed within the reply interval;
otherwise HTTP 202 with `{order_id,command_id,status:"CANCEL_PENDING",existing}`.
An existing queued or completed cancellation reuses its command identity.
An already finished order without a prior cancellation returns
`ORDER_NOT_OPEN`/409. Cancellation remains available during halt/suspension.

`GET /v1/orders/{id}` returns the current private order, including ADMITTED
orders whose command has not yet run:

```json
{
  "order_id":"<uuid>","market_id":"<uuid>","status":"PARTIAL",
  "outcome":"YES","side":"BUY","price":42,"qty":10,
  "remaining":4,"filled":6,"filled_qty":6,"cancelled":0,
  "accepted_seq":17,"fee_paid":true,"fee_charged":1,
  "principal":240,"avg_price":40,"created_at":"<database timestamp>"
}
```

`accepted_seq` is zero for ADMITTED orders. Status values are ADMITTED,
OPEN, PARTIAL, FILLED, CANCELLED, REJECTED and EXPIRED. A final order has no
open admission holds; an admitted order legitimately retains its holds.

`GET /v1/me/orders?market_id=<uuid>&status=open&limit=50&cursor=<opaque>`
returns `{items,next_cursor?}`. Status can be `open` or `all`, limit is
1–100, and the keyset cursor binds the account and filters. `open` includes
ADMITTED, OPEN and PARTIAL.

## Public market data

- `GET /v1/markets/{id}/book` returns an immutable local view with market ID,
  owner epoch, committed command sequence, separate book sequence, last
  price, approximate pending count, millisecond timestamps, health, mode and
  up to 50 bid/ask levels. Levels use canonical YES prices. NO prices mirror
  around redemption value. Non-ready or expired views return
  `MARKET_DEGRADED`/503. Request handling neither queries PostgreSQL nor sends
  an actor message. Background hydration supports non-owner nodes and idle
  genesis books, and refuses epoch/sequence regressions.
- `GET /v1/markets/{id}/trades?limit=50&cursor=<opaque>` returns public fills
  newest first by execution sequence/fill index. Limit is 1–100; cursors bind
  the market. Modes are TRANSFER_YES, TRANSFER_NO, MINT and MERGE. Private
  parties and order IDs are excluded.
- `GET /v1/markets/{id}/history?period=1D` returns OHLCV bars; periods are 1H,
  6H, 1D, 1W and ALL. Volume is canonical YES-price times quantity. Minute
  bars aggregate into time buckets; empty buckets are omitted.

## Errors and delivery

Errors use the existing `{error:{code,message,fields?}}` envelope. Field
validation identifies the invalid request field. Insufficient balance/share
errors include actual locked `available`, `needed` and `asset` values as
fields. No store/SQL error is exposed as a client message.

| HTTP | Codes |
|---|---|
| 400 | BAD_REQUEST; malformed UUID/key/request/cursor |
| 401 | UNAUTHENTICATED |
| 404 | NOT_FOUND, ORDER_NOT_FOUND |
| 409 | IDEMPOTENCY_CONFLICT, ORDER_NOT_OPEN, MARKET_NOT_OPEN, MARKET_SUSPENDED, SEASON_NOT_ACTIVE, INSUFFICIENT_FUNDS, INSUFFICIENT_SHARES, NO_LIQUIDITY_IN_RANGE |
| 422 | PRICE_OUT_OF_BAND, OFF_TICK, QTY_TOO_LARGE, BELOW_MIN_NOTIONAL, OVERFLOW |
| 429 | RATE_LIMITED; existing shared auth limiter, 120 mutations/account/second |
| 503 | QUEUE_FULL with Retry-After: 1, MARKET_DEGRADED, TRADING_HALTED, UNAVAILABLE |

Runtime events retain UUID identity and `(market_seq,event_ordinal)` ordering
per source. Public events route to `stream:market:<market>`; private order,
balance and position changes route to `stream:account:<account>`. PostgreSQL
claim leases, retries and Redis sequence cursors tolerate lost publication
acknowledgements. The legacy `say:events` lifecycle route remains separate.
WebSocket delivery is prompt 06 and is not provided by these HTTP routes.
