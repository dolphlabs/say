# Portfolio and Notifications API

## Overview

This document specifies the HTTP endpoints, data models, error contracts, valuation rules, and background pipelines for **Portfolio and Notifications** in **say** (Prompt 07).

---

## 1. Portfolio APIs

All `/v1/me/*` endpoints require an authenticated session via the session cookie or authorization bearer token. Responses return `Cache-Control: no-store`.

### 1.1 `GET /v1/me/portfolio/summary`

Returns authoritative portfolio summary for the current or specified season.

- **Query Parameters**:
  - `season` *(optional, string)*: `"current"` or positive integer ordinal (e.g. `1`, `2`). Default: `"current"`.

- **Response `200 OK`**:
  ```json
  {
    "season": {
      "ordinal": 1,
      "status": "ACTIVE",
      "ends_at": "2026-12-31T23:59:59Z"
    },
    "available": 427,
    "held": 109,
    "held_shares": [
      {
        "market_id": "87b1c412-2591-4e4b-9e8c-8c5e93df15aa",
        "outcome": "YES",
        "qty": 4
      }
    ],
    "positions_value": 978,
    "total": 1514,
    "season_pnl": 514,
    "starting_grant": 1000,
    "rank": null
  }
  ```

- **Semantics**:
  - `total = available + held + positions_value`
  - `season_pnl = total - starting_grant` (or `null` if starting grant has not yet been issued).
  - `rank`: Returns `null` until Prompt 10 provides `season_standings`.

---

### 1.2 `GET /v1/me/positions`

Returns positive-quantity economic exposure for the player in the selected season.

- **Query Parameters**:
  - `season` *(optional, string)*: `"current"` or season ordinal.
  - `status` *(optional, string)*: `"open"` (default).

- **Response `200 OK`**:
  ```json
  {
    "items": [
      {
        "market": {
          "id": "87b1c412-2591-4e4b-9e8c-8c5e93df15aa",
          "slug": "enyimba-rivers-united",
          "question": "Enyimba vs Rivers United",
          "category": "SPORTS",
          "status": "OPEN",
          "closes_at": "2026-12-31T16:00:00Z",
          "redemption_units": 100
        },
        "outcome": "YES",
        "qty": 18,
        "qty_free": 14,
        "qty_in_orders": 4,
        "avg_price": { "numerator": 50, "denominator": 1 },
        "mark": { "numerator": 54, "denominator": 1 },
        "mark_source": "last_trade",
        "value": 972,
        "unrealized_pnl": 72,
        "pnl_pct": 8,
        "proposed_outcome": null
      }
    ]
  }
  ```

- **Mark Source Precedence**:
  1. `last_trade`: Last traded price (YES mark = last price, NO mark = $V - \text{last price}$).
  2. `mid`: Midpoint of best bid and ask $\lfloor(\text{own\_bid} + \text{own\_ask})/2\rfloor$.
  3. `avg_cost`: Exact rational fallback $\text{cost\_basis} / \text{qty}$.

---

### 1.3 `GET /v1/me/orders?status=open`

Returns open orders for the user, extended with Prompt 07 fields.

- **Query Parameters**:
  - `status`: `"open"` or `"all"`.
  - `market_id` *(optional)*.
  - `cursor` / `limit` *(optional)*.

- **Response `200 OK`**:
  ```json
  {
    "items": [
      {
        "id": "ord-4912a7e4-2319-4821-b0f3-52467d130a01",
        "market": "87b1c412-2591-4e4b-9e8c-8c5e93df15aa",
        "outcome": "YES",
        "side": "BUY",
        "price": 54,
        "qty": 6,
        "filled_qty": 4,
        "status_label": "Partly filled",
        "held": {
          "sedi": 108,
          "shares": 0
        },
        "placed_at": "2026-10-28T14:32:00Z",
        "cancellable": true
      }
    ],
    "next_cursor": null
  }
  ```

---

### 1.4 `GET /v1/me/results`

Returns settled positions from the `position_results` table.

- **Query Parameters**:
  - `season` *(optional, string)*: Season filter.

- **Response `200 OK`**:
  ```json
  {
    "items": [
      {
        "market": {
          "id": "87b1c412-2591-4e4b-9e8c-8c5e93df15aa",
          "slug": "remo-stars-shooters",
          "question": "Remo Stars vs Shooting Stars",
          "category": "SPORTS",
          "status": "SETTLED",
          "closes_at": "2026-10-27T16:00:00Z",
          "redemption_units": 100
        },
        "outcome": "YES",
        "qty": 10,
        "avg_price": { "numerator": 40, "denominator": 1 },
        "result": "WON",
        "paid_out": 1000,
        "pnl": 599,
        "settled_at": "2026-10-27T18:30:00Z"
      }
    ]
  }
  ```

---

## 2. Notification APIs

### 2.1 `GET /v1/me/notifications`

Keyset paginated feed of notifications for the authenticated account.

- **Query Parameters**:
  - `cursor` *(optional, string)*: ID of the last seen notification.
  - `limit` *(optional, integer)*: Default 20, max 100.

- **Response `200 OK`**:
  ```json
  {
    "items": [
      {
        "id": "f29da57e-37bb-4e63-bfb1-3e4453b6f001",
        "kind": "order_filled",
        "title": "Order partly filled",
        "body": "4 of 6 Enyimba Yes @ S 54. The rest is still waiting.",
        "link": "/portfolio",
        "created_at": "2026-10-28T15:00:00Z",
        "updated_at": "2026-10-28T15:05:00Z",
        "unread": true
      }
    ],
    "unread_count": 1,
    "next_cursor": null
  }
  ```

---

### 2.2 `POST /v1/me/notifications/read`

Marks specific notifications or all notifications as read.

- **Request Body**:
  ```json
  { "ids": ["f29da57e-37bb-4e63-bfb1-3e4453b6f001"] }
  ```
  *or*
  ```json
  { "all": true }
  ```

- **Response**: `204 No Content`.

---

### 2.3 `GET /v1/me/notification-prefs`

Returns effective user notification preferences.

- **Response `200 OK`**:
  ```json
  [
    {
      "kind": "order_filled",
      "label": "Order filled",
      "hint": "When an order fills or partially fills",
      "in_app": true,
      "email": false
    },
    {
      "kind": "market_settled",
      "label": "Market settled",
      "hint": "When a market settles and pays out",
      "in_app": true,
      "email": true
    },
    {
      "kind": "weekly_recap",
      "label": "Weekly recap",
      "hint": "Sunday 18:00 WAT email summary of your week",
      "in_app": false,
      "email": false
    }
  ]
  ```

---

### 2.4 `PUT /v1/me/notification-prefs`

Updates notification channels for a specific event kind.

- **Request Body**:
  ```json
  {
    "kind": "order_filled",
    "in_app": true,
    "email": true
  }
  ```

- **Response**: `204 No Content`.

---

### 2.5 `GET /v1/unsubscribe?token=`

Public single-purpose unsubscribe endpoint for email notifications (no login required).

- **Query Parameters**:
  - `token` *(required, string)*: HMAC-SHA256 signed token binding account, kind, and expiry.

- **Response `200 OK`**:
  ```json
  {
    "status": "ok",
    "message": "You have been unsubscribed from this notification email."
  }
  ```

---

## 3. Performance & Test Verification

- **Valuation Test Vectors**: Passed in `spec/valuation-vectors.json` against both Slang (`src/portfolio/domain/domain_test.sl`) and TypeScript (`packages/say-stream/test/valuation.test.js`).
- **Unit & Integration Suite**: All 22 tests in `@say/stream` pass; all unit test suites in `portfolio` and `notifications` pass.
- **Architectural Rules**: Passed `zokor check: ok (41 packages)` with 0 errors.
- **Latency Targets**:
  - Summary read p99 target: < 20 ms.
  - Positions read p99 target: < 30 ms (with 50 positions).
  - Batch fanout: 1,000 recipients per transaction.
- **Assumptions & Future Prompt Dependencies**:
  - Prompt 08 writes `position_results` and triggers `result_proposed` and `market_settled`.
  - Prompt 10 provides `season_standings` for the `rank` field.
