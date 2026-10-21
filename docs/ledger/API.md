# Ledger API

For the web app, and for the prompts that move money (exchange, settlement,
bots). The design is in [DESIGN.md](DESIGN.md).

All amounts are whole sedis or whole shares (integers). Times are UTC,
RFC 3339. Errors use the standard envelope:
`{"error":{"code","message","fields"?}}`.

## HTTP

### `GET /v1/seasons/current` (public)

```json
{ "id": "6f1c…", "ordinal": 1, "status": "ACTIVE",
  "starts_at": "2026-10-11T23:00:00Z", "ends_at": "2026-10-25T23:00:00Z",
  "day": 9, "days_total": 14, "timezone": "Africa/Lagos",
  "server_time": "2026-10-20T12:00:00.000Z" }
```

- `day` is the season's day in Lagos calendar days, 1–14.
- Show times in Africa/Lagos. Use `server_time` for countdowns, not the
  device clock.
- When no season is active (before launch only), the answer is 404
  `SEASON_NOT_FOUND`.

### `GET /v1/seasons/{ordinal}` (public)

The same shape, plus:

- `finalized`: `true` once every market in the season has settled.
- `provisional_reason`: present while `finalized` is false. The
  leaderboard for that season must be labelled provisional.

Errors: 404 `SEASON_NOT_FOUND`; 400 `BAD_REQUEST` for an ordinal below 1.

### `GET /v1/me/balance?season=current|{ordinal}` (session)

```json
{ "season": { "ordinal": 1, "status": "ACTIVE" },
  "available": 958, "held": 42, "starting_grant": 1000 }
```

- `available` can be spent now. `held` is set aside for open orders.
- `starting_grant` is `null` when the player has not been granted this
  season yet (no approved policy, or the cap was reached).
- One indexed read, about 0.7 ms (see PERFORMANCE.md). It is not cached,
  so it is always current.

### `GET /v1/me/ledger?season=&cursor=&limit=50` (session)

```json
{ "items": [
    { "id": "1b7e…", "at": "2026-10-20T12:00:00.000Z", "kind": "FILL",
      "delta": -141, "held_delta": 0, "available_after": 817, "held_after": 42,
      "ref": { "type": "order", "id": "9c2d…" },
      "shares": [ { "asset": "YES:5a0e…", "delta": 5, "held_delta": 0 } ],
      "meta": { "market_title": "Afrobeats UK No. 1", "outcome": "YES", "qty": 5, "price": 28, "fee": 1 } }
  ],
  "next_cursor": "MjAyNi0x…" }
```

- **Order:** newest first. Pass `next_cursor` back as `cursor`; it is
  `null` on the last page.
- **`limit`:** 1–100, default 50.
- **One item per ledger transaction that touched the player this season:**
  - `delta` and `held_delta` are the change to the player's sedis in the
    two buckets;
  - `available_after` and `held_after` are the sedi balance after it (both
    `null` if the transaction moved only shares);
  - `shares` lists share movements.
- **The text is the client's job.** The server sends `kind` and `meta`,
  never prose, so the client writes "Bought 5 Yes @ S 28 ·
  Afrobeats UK No. 1 · incl. S 1 fee" itself.
- **Errors:** 400 `BAD_REQUEST` for a bad `limit` or a cursor the server
  did not issue; 404 `SEASON_NOT_FOUND`.

### `GET /v1/me/summary` (session)

`{ "season": <current season>, "balance": <balance> }`. The page header
gets both in one round trip; the server fetches them concurrently. Either
part can be `null`.

### Admin

| Route | Role | Answer |
|---|---|---|
| `GET /v1/admin/reconciliation/latest` | admin | `{ "trading_halted": {halted, reason, changed_at}, "run": {id, scope, status, ok, finished_at?, checks: [{name, status, count, detail}]} \| null }` |
| `POST /v1/admin/reconciliation/run` | admin | 202 `{ "run_id" }`. Queues a full run; the runner picks it up within seconds. |
| `POST /v1/admin/trading-halt/clear` `{ "reason" }` | super_admin | 204. Writes an `audit_events` row. |

- **Check `status` values:** `ok`, `failed` or `not_applicable`.
- **Check names**, in the order the treasury screen shows them:
  `entries_balance`, `cached_balances`, `no_negative_balances`, `grants`,
  `season_isolation`, `holds`, `yes_no_supply`, `collateral`, `fee_once`.
  The last three are `not_applicable` until prompt 05.
- **Errors:** a session without the role gets 403 `FORBIDDEN`.

### Error codes

| Code | Status | When |
|---|---|---|
| `SEASON_NOT_FOUND` | 404 | No such season |
| `INSUFFICIENT_FUNDS` | 409 | A posting would take a wallet below zero |
| `IDEMPOTENCY_CONFLICT` | 409 | A business key was reused with a different movement |
| `SEASON_MISMATCH` | 409 | Wallets or holds from another season |
| `SEASON_NOT_ACTIVE` | 409 | The season's status does not allow that kind of posting |
| `HOLD_NOT_OPEN` | 409 | The hold is closed or does not exist |
| `HOLD_EXCEEDED` | 409 | Releasing or consuming more than the hold has left |
| `ISSUANCE_UNAVAILABLE` | 503 | No approved issuance policy, or the season cap was reached |
| `UNAVAILABLE` | 503 | Anything else; the cause is logged, never sent |

`ledger/server.code_of_fault(fault)` maps a `LedgerError` to these codes.
`Overflow`, `Unbalanced`, `WalletNotFound` and `Malformed` are programming
errors and map to `UNAVAILABLE`.

## For later prompts: posting money

Everything is in `src/ledger/store`. Each function runs on the caller's
`pg.Conn`, inside the caller's transaction, and is never spawned. **On
`err`, roll the transaction back**: a failed call may have written part of
its work.

| Function | Use |
|---|---|
| `post(c, LedgerTx, d)` | One posting. |
| `post_many(c, [LedgerTx], d)` | Several postings in one season, all their wallets locked once (a fill and its fees). |
| `hold(c, owner, season, asset, amount, ref_type, ref_id, key, d)` | free → held; returns the hold id. |
| `release(c, hold_id, amount, key, d)` | held → free. |
| `consume(c, hold_id, amount, kind, counter_entries, key, d)` | held → the counter entries (counterparty, collateral, fees). |
| `read_hold(c, hold_id, d)` | The hold, its owner and what is left. |
| `grant_season_allowance(c, account_id, season_id, d)` | The season grant, at most once; `none` if not granted. |
| `grant_current_season(c, account_id, d)` | The same, for the season active now (verification uses this). |
| `open_market_wallets(c, season_id, market_id, d)` | Creates `system:collateral:{m}` (SEDI) and `system:shares:{m}` (`YES:{m}`, `NO:{m}`). Call it when a market opens. |

**One posting call per database transaction.** Two calls would lock
wallets in two rounds, and two such transactions could deadlock. The
second call fails with `Malformed`. Use `post_many` instead.

Build postings with the helpers in `ledger/domain`: `free(owner, asset, delta)`,
`held(owner, asset, delta, hold)`, `user(id)`, `bot(id)`, `issuance()`,
`fees()`, `treasury()`, `collateral(m)`, `shares(m)`, `sedi()`,
`yes_asset(m)`, `no_asset(m)`, `hold_tx`, `release_tx`, `consume_tx`.

**Rules `post` enforces:**
- at least two entries, no zero delta;
- every asset sums to zero;
- every held-bucket entry names its hold;
- system wallets use the free bucket only;
- one season per call;
- the kind must be allowed in the season's status.

**Business keys** must be unique and stable for one movement, for example
`fill:{market}:{seq}:{idx}` or `fee:{order_id}`:
- the same key with the same movement returns the first posting
  (`replayed: true`);
- with a different movement it is `IdempotencyConflict`;
- `metadata` is not part of the comparison.

### Kinds, statuses and `meta`

| Kind | Allowed while the season is | `meta` the poster must include |
|---|---|---|
| `SEASON_GRANT` | ACTIVE | `{}` (the client shows "Season N allowance") |
| `ORDER_HOLD` | ACTIVE | `market_id, market_title, outcome, side, qty, limit_price, fee` |
| `ORDER_RELEASE` | ACTIVE, CLOSING | `market_id, market_title, reason`: `cancel`, `fee_unused`, `price_improvement` or `season_close` |
| `FILL` | ACTIVE | `market_id, market_title, outcome, side, qty, price, fee` |
| `FEE` | ACTIVE | `market_id, order_id` |
| `MINT` | ACTIVE | `market_id, market_title, qty, yes_price` |
| `MERGE` | ACTIVE | `market_id, market_title, qty, yes_price` |
| `PAYOUT` | CLOSING, CLOSED | `market_id, market_title, outcome, qty, per_share` |
| `BOT_FUNDING` | ACTIVE | `allocation_id` |
| `ADJUSTMENT` | anything but FINALIZED | `reason, operator_id` |

`meta` values are display text and ids only. Nothing reads them for logic.

### Outbox events

Each event is written in the same transaction as the change it reports,
then published to the Redis stream `say:events` (fields `id`, `type`,
`payload`). Delivery is at least once, so consumers dedupe on `id`.

| Type | Payload |
|---|---|
| `season.started` | `season_id, ordinal, status, starts_at, ends_at` |
| `season.closing` | the same. The exchange cancels resting orders and releases their holds on this (prompt 05). |
| `season.closed` | the same |
| `season.grants_done` | `season_id, granted, skipped, halted_reason?` |
| `alert.issuance_halted` | the same, when the rollover stopped at the cap or without a policy |
| `reconciliation.failed` | `run_id, reason`. Trading is halted. |

### The trading halt

- Postgres holds `trading_halt.halted`. It is mirrored to the Redis key
  `say:trading_halted` (`"1"`/`"0"`) when a check fails and when an
  operator clears it.
- The exchange must refuse new orders while it is set: read Redis, and
  fall back to `ledger.halt_state` if Redis does not answer.

## Operator CLI

```
say admin role grant --account <uuid> --role admin|super_admin
say admin issuance-policy propose --amount 1000 --cap 10000000 --operator <uuid>
say admin issuance-policy approve --policy <uuid> --operator <uuid>   # twice, two operators
say admin issuance-policy show
```
