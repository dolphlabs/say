# Treasury and Market-Making Bots

Status: **proposed; awaiting review**. Date: 2026-10-28.

This is Prompt 09's design deliverable. Work proceeds in this strict order:
**design doc → review → implement → simulate → test**.
This document details sections §1–§4, including the worked quoting example, and pauses for review before writing migrations, executor code, or simulation harnesses.

---

## 0. Product Outcomes & Architectural Ground Rules

### Product Outcomes

| User / System | Required Outcome |
|---|---|
| **Player** | Finds liquid, two-sided books with tight spreads from minute one without noticing artificial matching mechanics or unfair privileges. |
| **Treasury Operator** | Monitors total player disbursements, bot allocations against approved season caps, collateral held, fees collected, and system balance integrity. |
| **Risk / Admin** | Enforces hard risk limits (`max_loss`, holding caps, drawdown limits) per bot and market; instantly pulls quotes via global or per-bot kill switches (< 2 s). |
| **Exchange Kernel** | Treats bots as ordinary market participants. All bot trades pass through standard admission, holds, self-trade prevention, order books, and settlement journals. |
| **Auditor** | Traces every bot decision through immutable audit logs (`bot_decisions`), proving why quotes shifted, widened, or pulled. |

### Ground Rules & Guarantees

1. **Ordinary Account Trading**: Bots trade exclusively through the public/internal HTTP order API (`POST /v1/markets/{id}/orders`, `DELETE /v1/markets/{id}/orders/{order_id}`, and `DELETE /v1/markets/{id}/orders?mine=true`). Bots never perform direct database mutations, bypass holds, or receive special matching priority.
2. **Approved Money Only**: Every Sedi a bot holds originates from an approved ledger allocation (`BOT_FUNDING` and `BOT_ALLOCATION`). No bot can ever spend unallocated or unapproved capital.
3. **Pure Quoting Mathematics**: The quoting algorithm is a deterministic, pure function: `quote(inputs) -> DesiredOrders`. It contains zero network I/O, database access, or side effects, making it 100% property- and unit-testable.
4. **House Beneficial-Owner Group**: All bots and all staff/admin accounts belong to the beneficial-owner group `house`. Prompt 04's self-trade prevention mechanism cancels any order that would match against another house order, guaranteeing bots never trade with each other or with administrators.
5. **Separation of Concerns**: The bot runner is an independent application (`apps/say-bots`) consuming the live WebSocket feed (Prompt 06) and dispatching orders over HTTP with Idempotency-Keys.

---

## 1. Treasury and Funding (Ledger Flows)

### 1.1 Capital Lifecycle & Ledger Invariants

The bot capital lifecycle flows through strictly balanced, insert-only ledger transactions across four stages:

```
[system:issuance]
       │
       ▼ (BOT_FUNDING via 2-operator approval)
[system:treasury]
       │
       ▼ (BOT_ALLOCATION via liquidity approval upon market FUNDING)
[bot_wallet (season)]
       │
       ▼ (Trading, Fills, Settlement Payouts)
[bot_wallet (season)]
       │
       ▼ (BOT_SWEEP upon market SETTLED)
[system:treasury]
```

#### 1. Season Bot Budget (`BOT_FUNDING`)
- Each season has an approved bot budget cap (e.g. S 750,000).
- Initiated via an `approvals` proposal of kind `bot_season_budget` (`scope = 'treasury'`, `required_votes = 2`).
- Upon dual-operator approval, a journal transaction is posted:
  - Debit: `system:issuance` (delta: `-amount`)
  - Credit: `system:treasury` (delta: `+amount`)
  - Kind: `BOT_FUNDING`
  - Reference: `approval:{approval_id}`

#### 2. Per-Market Allocation (`BOT_ALLOCATION`)
- When a market enters `FUNDING` (Prompt 03) with a `liquidity_request`:
  - An approval of kind `liquidity` is created (`scope = 'treasury'`). The requester cannot approve their own allocation.
  - Verification: `season_allocated + requested_amount <= season_cap`. If the allocation would breach the season cap, it is rejected with `BUDGET_CAP_EXCEEDED`.
  - Upon approval, the ledger posts:
    - Debit: `system:treasury` (delta: `-amount`)
    - Credit: `user:{bot_account_id}` (delta: `+amount`, season: `market.season_id`)
    - Kind: `BOT_ALLOCATION`
    - Reference: `market:{market_id}`
  - The market advances from `FUNDING` to `OPEN`.

#### 3. Top-Ups (`bot_topup`)
- Operators can inject additional liquidity into an active bot market if inventory or volatility requires it.
- Created as an `approvals` request of kind `bot_topup` with an explicit reason (e.g. "Top up mm-football-01 by S 25,000 due to high volume").
- Follows the same cap checks and posts `BOT_ALLOCATION` from `system:treasury` to the bot wallet.

#### 4. Post-Settlement Sweep (`BOT_SWEEP`)
- When a market transitions to `SETTLED` (Prompt 08), the settlement worker sweeps remaining cash and payouts associated with that market:
  - Debit: `user:{bot_account_id}` (delta: `-remaining_market_balance`)
  - Credit: `system:treasury` (delta: `+remaining_market_balance`)
  - Kind: `BOT_SWEEP`
  - Reference: `market:{market_id}:sweep`
- **Bot P/L Calculation**:
  $$\text{Bot P/L} = \text{Swept Amount} - (\text{Initial Allocation} + \text{Top-Ups})$$
- The final profit/loss is recorded in `bot_market_results`.

### 1.2 Bot Account Architecture & Bookkeeping

- **Owner Kind**: `accounts.owner_kind = 'bot'`.
- **Beneficial Owner Group**: `accounts.owner_group = 'house'`. This activates the matching engine's self-trade prevention against any other account in `house`.
- **Authentication**: Bots authenticate via high-entropy API keys (`say_bot_...`), hashed with SHA-256 in `bot_api_keys`. Keys are rotatable, scoped strictly to trading (`/v1/markets/{id}/orders`) and private stream access (`/v1/stream`), and reject session cookies.
- **Exclusion Filters**: Queries for season grants, user leaderboards, and portfolio notifications filter out `owner_kind = 'bot'`.
- **Per-Market Tracking Table (`bot_markets`)**:
  ```sql
  create table bot_markets (
      bot_id          uuid not null references accounts(id),
      market_id       uuid not null references markets(id),
      season_id       uuid not null references seasons(id),
      allocated       bigint not null check (allocated >= 0),
      used            bigint not null default 0 check (used >= 0),
      status          text not null check (status in ('QUOTING', 'PULLED_STALE', 'PULLED_CAP', 'PULLED_DRAWDOWN', 'PULLED_MARKET', 'PAUSED_MANUAL', 'PAUSED_ALL')),
      status_reason   text not null default '',
      params_version  int not null default 1,
      last_quote_at   timestamptz,
      created_at      timestamptz not null default now(),
      updated_at      timestamptz not null default now(),
      primary key (bot_id, market_id)
  );
  ```

---

## 2. Quoting (A Pure Function)

### 2.1 Interface & Data Structures

The quoting core is completely decoupled from system runtime and network I/O:

```slang
pub struct QuoteInputs {
    V: int,                           // Redemption payout (e.g. 100)
    min_price: int,                   // Minimum price (e.g. 1)
    max_price: int,                   // Maximum price (e.g. 99)
    tick: int,                        // Minimum price tick (e.g. 1)
    ref_price: int,                   // Yes-terms reference price
    ref_age_ms: int,                  // Age of reference price in milliseconds
    book_top: BookTop,                // Best bid and ask on current book
    inventory: Inventory,             // yes_qty, no_qty, cost_yes, cost_no
    cash_free: int,                   // Available unreserved Sedi balance
    allocation: int,                  // Total allocated budget for this market
    params: BotParams,                // Risk and spread parameters
    recent_fills: [FillRecord],       // Fills in last 2 minutes for adverse selection
    market_status: str,               // 'OPEN', 'SUSPENDED', 'CLOSED', etc.
    trading_halted: bool,             // Global emergency circuit breaker
    global_pause: bool,               // Admin global pause flag
    manual_pause: bool                // Per-bot manual pause flag
}

pub struct DesiredOrder {
    outcome: str,                     // "YES" or "NO"
    side: str,                        // "BUY" or "SELL"
    price: int,                       // Own-terms limit price
    qty: int                          // Share quantity
}

pub struct QuoteResult {
    status: str,                      // QUOTING, PULLED_STALE, etc.
    status_label: str,                // "Quoting", "Pulled · old data", etc.
    status_reason: str,
    r_prime: int,                     // Skewed reference price
    spread_ticks: int,                // Total spread in ticks
    util: int,                        // Inventory utilization (basis points 0-10000)
    worst_case_loss: int,             // Calculated worst-case loss
    orders: [DesiredOrder]            // Target resting orders
}
```

### 2.2 Quoting Mathematics Step-by-Step

#### Step 1: Reference Price ($r$)
- **Initial Reference**: The market's approved `opening_price` (defaults to $V/2$).
- **Dynamic EWMA**: Once trading begins, $r$ tracks the Exponentially Weighted Moving Average of executed trade prices:
  $$r_t = \alpha \cdot P_{\text{trade}} + (1 - \alpha) \cdot r_{t-1}$$
  Excludes trades where maker or taker was in the `house` group. Half-life is set to 5 minutes ($\Delta t = 300\text{ s}$). $r$ is clamped to $[\text{min\_price}, \text{max\_price}]$.

#### Step 2: Inventory Skew ($r'$)
The bot counters adverse inventory build-up by shading its midpoint against its position:
- **Net Inventory**: $\text{net} = \text{yes\_shares} - \text{no\_shares}$
- **Utilization**: $\text{util} = \frac{|\text{net}|}{\text{params.max\_net\_shares}}$ (clamped to $[0.0, 1.0]$)
- **Shift Calculation**:
  $$\text{shift} = \text{sign}(\text{net}) \times \left\lceil \text{params.skew\_ticks} \times \text{util} \right\rceil \times \text{tick}$$
- **Skewed Midpoint**:
  $$r' = \text{clamp}(r - \text{shift}, \text{min\_price} + 1, \text{max\_price} - 1)$$
  *Intuition*: When long Yes ($\text{net} > 0$), $r'$ decreases. The bot lowers its quotes, discouraging further Yes purchases and encouraging Yes sales.

#### Step 3: Spread Calculation ($s$)
- **Base Spread**: $s = \text{params.base\_spread\_ticks}$.
- **Volatility Bump**: If the trade EWMA moved more than 3 ticks within the past 5 minutes, add $\text{params.vol\_ticks}$.
- **Inventory Skew Bump**: Add $+1\text{ tick}$ for every 25% of inventory utilization:
  $$\text{spread\_ticks} = s + \text{vol\_ticks} + \left\lfloor \frac{\text{util}}{0.25} \right\rfloor$$
- **Adverse Selection Back-Off**: If the bot experienced 4 or more fills on the same side within the last 60 seconds, add $+2\text{ ticks}$ to that side for 120 seconds.

#### Step 4: Bid & Ask Boundaries (Yes Terms)
Given skewed midpoint $r'$ and spread $s$:
$$\text{half\_spread} = \left\lceil \frac{s}{2} \right\rceil \times \text{tick}$$
$$\text{bid} = \text{clamp}(r' - \text{half\_spread}, \text{min\_price}, \text{max\_price} - 1)$$
$$\text{ask} = \text{clamp}(r' + \text{half\_spread}, \text{min\_price} + 1, \text{max\_price})$$
$$\text{Invariant: } \text{bid} < \text{ask}$$

#### Step 5: Order Layering & Sizing
The bot constructs $\text{params.levels}$ (default 3) on each side, spaced 1 tick apart:
- Layer $i \in \{0, 1, 2\}$:
  - $\text{bid}_i = \text{bid} - (i \times \text{tick})$
  - $\text{ask}_i = \text{ask} + (i \times \text{tick})$
- Base size multipliers: $M = [1.0, 0.6, 0.35]$.
  $$\text{raw\_qty}_i = \left\lfloor \text{params.base\_size} \times M_i \right\rfloor$$
- **Budget Scaling**: If cumulative budget used exceeds 70% of allocation, sizes taper linearly to zero at 100%:
  $$\text{scaling} = \begin{cases} 1.0 & \text{if } \frac{\text{used}}{\text{allocation}} \le 0.70 \\ \frac{1.0 - \frac{\text{used}}{\text{allocation}}}{0.30} & \text{if } 0.70 < \frac{\text{used}}{\text{allocation}} < 1.00 \\ 0.0 & \text{if } \frac{\text{used}}{\text{allocation}} \ge 1.00 \end{cases}$$
  $$\text{qty}_i = \left\lfloor \text{raw\_qty}_i \times \text{scaling} \right\rfloor$$

#### Step 6: Native Share Conversion (Capital Efficiency)
To minimize Sedi hold consumption and avoid unneeded minting, the bot prioritizes selling resting shares it already owns before placing orders that mint complementary sets:

| Desired Action | Condition | Emitted Order (Own Terms) | Notes |
|---|---|---|---|
| **Bid (Yes terms @ $P$)** | Holds $\text{No} \ge \text{qty}$ | `SELL NO @ (V - P)` | Releases No share hold; consumes 0 cash |
| **Bid (Yes terms @ $P$)** | Holds $\text{No} = 0$ | `BUY YES @ P` | Consumes $P \times \text{qty}$ cash hold |
| **Ask (Yes terms @ $P$)** | Holds $\text{Yes} \ge \text{qty}$ | `SELL YES @ P` | Releases Yes share hold; consumes 0 cash |
| **Ask (Yes terms @ $P$)** | Holds $\text{Yes} = 0$ | `BUY NO @ (V - P)` | Consumes $(V - P) \times \text{qty}$ cash hold |

If the bot holds a partial quantity, the level splits into a `SELL` for the owned shares and a `BUY` for the remainder.

---

### 2.3 Hard Stops & Risk Circuit Breakers

The quoting function inspects conditions in priority order. If any trigger, quotes are either suppressed entirely or constrained to risk-reducing orders:

```
[Trigger Condition]                                    [Action & Status]
Global Pause Flag = True                           ──► Cancel all; Status = PAUSED_ALL
Manual Bot/Market Pause = True                     ──► Cancel all; Status = PAUSED_MANUAL
Market != 'OPEN' or trading_halted = True          ──► Cancel all; Status = PULLED_MARKET
ref_age_ms > 30,000 or stream degraded/gap         ──► Cancel all; Status = PULLED_STALE
Season Drawdown > params.season_max_drawdown       ──► Cancel all; Status = PULLED_DRAWDOWN
Worst-Case Loss > params.max_loss                  ──► Only allow risk-reducing orders; Status = PULLED_CAP
```

#### Worst-Case Loss Definition
$$\text{loss}_{\text{if YES wins}} = (\text{cost\_yes} + \text{cost\_no}) - (\text{yes\_shares} \times V)$$
$$\text{loss}_{\text{if NO wins}} = (\text{cost\_yes} + \text{cost\_no}) - (\text{no\_shares} \times V)$$
$$\text{worst\_case\_loss} = \max(\text{loss}_{\text{if YES wins}}, \text{loss}_{\text{if NO wins}})$$

If $\text{worst\_case\_loss} > \text{params.max\_loss}$:
- The bot evaluates whether a side strictly reduces $\text{worst\_case\_loss}$.
- For example, if long excess Yes, only selling Yes or buying No reduces risk. The bot suppresses the Yes bid and emits **only the ask**.
- If neither side reduces risk or sizing cannot satisfy risk constraints, zero orders are emitted (`PULLED_CAP`).

---

### 2.4 Worked Quoting Example (Golden Test)

Here is the exact reference scenario that forms the baseline for unit tests and simulation validation:

#### Inputs
- Contract payout: $V = 100$ Sedis
- Min / Max price: $\text{min} = 1$, $\text{max} = 99$, $\text{tick} = 1$
- Reference price: $r = 57$ (Yes terms, age = 1,200 ms)
- Current inventory:
  - $\text{yes} = 140\text{ shares}$, $\text{cost\_yes} = 7,700\text{ Sedis}$ (avg cost = 55.0)
  - $\text{no} = 0\text{ shares}$, $\text{cost\_no} = 0\text{ Sedis}$
  - $\text{net} = +140\text{ shares}$ (Long Yes)
- Bot configuration:
  - $\text{max\_net\_shares} = 400$
  - $\text{skew\_ticks} = 4$
  - $\text{base\_spread\_ticks} = 2$
  - $\text{vol\_ticks} = 0$ (no recent price jump)
  - $\text{levels} = 3$
  - $\text{base\_size} = 10$
  - $\text{max\_loss} = 15,000$
  - Multipliers: $[1.0, 0.6, 0.35]$
- Financials:
  - Budget allocated: S 50,000
  - Budget used: S 7,700 (15.4% utilized $\le 70\% \implies \text{scaling} = 1.0$)
  - Free cash: S 42,300

#### Calculation Walkthrough

1. **Inventory Utilization**:
   $$\text{util} = \frac{140}{400} = 0.35\text{ (35.0\%)}$$

2. **Skew Shift**:
   $$\text{raw\_shift} = 4 \times 0.35 = 1.4\text{ ticks}$$
   $$\text{shift} = \lceil 1.4 \rceil = 2\text{ ticks}$$
   Since $\text{net} > 0$ (long Yes), shift against position:
   $$r' = 57 - 2 = 55$$

3. **Spread Calculation**:
   $$\text{util\_bump} = \left\lfloor \frac{0.35}{0.25} \right\rfloor = 1\text{ tick}$$
   $$s = \text{base\_spread\_ticks} + \text{vol\_ticks} + \text{util\_bump} = 2 + 0 + 1 = 3\text{ ticks}$$
   $$\text{half\_spread} = \left\lceil \frac{3}{2} \right\rceil = 2\text{ ticks}$$

4. **Base Bid & Ask (Yes terms)**:
   $$\text{bid}_0 = r' - \text{half\_spread} = 55 - 2 = 53$$
   $$\text{ask}_0 = r' + \text{half\_spread} = 55 + 2 = 57$$
   Check: $53 < 57$ (valid inside $[1, 99]$).

5. **Layer Prices (3 levels, 1 tick spacing)**:
   - Yes Bids: Level 0 = 53, Level 1 = 52, Level 2 = 51
   - Yes Asks: Level 0 = 57, Level 1 = 58, Level 2 = 59

6. **Layer Quantities**:
   - Level 0: $\lfloor 10 \times 1.0 \rfloor = 10$
   - Level 1: $\lfloor 10 \times 0.6 \rfloor = 6$
   - Level 2: $\lfloor 10 \times 0.35 \rfloor = 3$

7. **Inventory Conversion (Own Terms)**:
   - **Asks (Yes 57, 58, 59)**: The bot owns 140 Yes shares. It sells existing shares directly:
     - Level 0: `SELL YES @ 57, qty 10`
     - Level 1: `SELL YES @ 58, qty 6`
     - Level 2: `SELL YES @ 59, qty 3`
     - Total Yes offered = $10 + 6 + 3 = 19\text{ shares} \le 140$ available.
   - **Bids (Yes 53, 52, 51)**: The bot owns 0 No shares. It mints by purchasing Yes:
     - Level 0: `BUY YES @ 53, qty 10` (Hold cost: $53 \times 10 = \text{S } 530$)
     - Level 1: `BUY YES @ 52, qty 6` (Hold cost: $52 \times 6 = \text{S } 312$)
     - Level 2: `BUY YES @ 51, qty 3` (Hold cost: $51 \times 3 = \text{S } 153$)
     - Total cash hold required = $\text{S } 995 \le \text{S } 42,300$ free cash.

8. **Worst-Case Loss Check**:
   - If YES wins: $\text{payout} = (140 \times 100) - 7,700 = +6,300$ (Gain)
   - If NO wins: $\text{payout} = 0 - 7,700 = -7,700$ (Loss)
   - $\text{worst\_case\_loss} = 7,700 \le 15,000$ (`max_loss`). Hard stop does not trigger.

#### Resulting Desired Orders
```json
[
  { "outcome": "YES", "side": "BUY",  "price": 53, "qty": 10 },
  { "outcome": "YES", "side": "BUY",  "price": 52, "qty": 6  },
  { "outcome": "YES", "side": "BUY",  "price": 51, "qty": 3  },
  { "outcome": "YES", "side": "SELL", "price": 57, "qty": 10 },
  { "outcome": "YES", "side": "SELL", "price": 58, "qty": 6  },
  { "outcome": "YES", "side": "SELL", "price": 59, "qty": 3  }
]
```

---

## 3. The Bot Runner (`apps/say-bots`)

### 3.1 Architecture & Task Model

The bot runner is a standalone daemon binary executing concurrently with the exchange:

```
                  ┌───────────────────────────────┐
                  │       say-bots process        │
                  └───────────────┬───────────────┘
                                  │
         ┌────────────────────────┼────────────────────────┐
         ▼                        ▼                        ▼
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│ Market Task (M1) │    │ Market Task (M2) │    │ Market Task (MN) │
│ (1s loop + event)│    │ (1s loop + event)│    │ (1s loop + event)│
└────────┬─────────┘    └────────┬─────────┘    └────────┬─────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
         ┌───────────────────────┼───────────────────────┐
         ▼                       ▼                       ▼
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│   Stream Client  │    │   Order Client   │    │  Heartbeat Task  │
│  (WebSocket WS)  │    │ (Pool + Idem-Key)│    │ (POST /internal) │
└──────────────────┘    └──────────────────┘    └──────────────────┘
```

1. **Market Worker Tasks**: One spawned Slang task per active `(bot_id, market_id)`. The task maintains local order state, receives stream updates, and runs `quote()` on every tick (1 Hz) or significant book event.
2. **WebSocket Ingestion Task**: A single multiplexed WebSocket client connecting to `/v1/stream` with API key authentication. It tracks sequence numbers and outbox deltas. If a sequence gap or disconnect occurs, it instantly sets `stream_degraded = true`, which pulls quotes until resynchronized.
3. **Order Client Pool**: Bounded HTTP client workers issuing `Place`, `Cancel`, and `CancelAll` requests to the core exchange API. Every `Place` request carries a deterministic `Idempotency-Key` (e.g. `bot:{bot_id}:{market_id}:{level}:{hash}`).
4. **Heartbeat Worker**: Every 2 seconds, posts operational status to `POST /v1/internal/bots/heartbeat`:
   - Bot status label, current inventory (`yes`, `no`), budget utilized, spread, and last quote timestamp.
5. **Decision Log Batcher**: Receives `bot_decisions` records over a bounded channel (`chan[BotDecision]`, capacity 1,000) and commits them to Postgres every 500 ms in a single batch insert.
6. **Pause Watcher**: Subscribes to Redis/WebSocket broadcast channel `bots.pause` for instant kill-switch signals.

---

### 3.2 Order Diffing & Churn Prevention

To minimize order churn, network roundtrips, and matching engine load, the executor computes a diff between **Desired Orders** and **Live Resting Orders**:

1. **Keep Rule**: If an existing live order has the **exact limit price** and its quantity matches the desired quantity within **20% tolerance**, it is left resting on the book.
2. **Cancel-and-Replace**: If price shifts, size drifts beyond 20%, or the order is no longer desired, it is cancelled and replaced.
3. **Requote Throttling**: Quotes are requoted at most once every `params.min_requote_ms` (default 250 ms), except when a hard stop fires.
4. **Emergency Pull**: When any hard stop triggers (stale data, holding cap, admin pause), throttling is bypassed and orders are cancelled immediately.

---

### 3.3 Core `CancelAll` Command (Prompts 04/05 Addition)

To guarantee the < 2-second kill switch SLA without issuing dozens of individual cancel requests, the matching engine adds atomic mass cancellation:

1. **Domain Command**: `Command { kind: "CancelAll", account_id: "...", ... }`.
2. **Matching Engine Execution**: Scans the order book levels and touches all open slots belonging to `account_id`, cancelling each with reason `CANCELLED_USER` (or `CANCELLED_ADMIN`), releasing all holds in the single transition.
3. **HTTP API**:
   - `DELETE /v1/markets/{id}/orders?mine=true`
   - Authenticated via session cookie (players) or API key (bots).
   - Core returns `{ "cancelled_count": N }`.

---

### 3.4 Decision Audit Table (`bot_decisions`)

Every material change in quoting state is preserved for 7 days to answer "Why did the bot do that?":

```sql
create table bot_decisions (
    id              uuid primary key default gen_random_uuid(),
    bot_id          uuid not null references accounts(id),
    market_id       uuid not null references markets(id),
    at              timestamptz not null default now(),
    inputs_digest   text not null,
    r               int not null,
    r_prime         int not null,
    spread          int not null,
    util            int not null,
    worst_case_loss int not null,
    status          text not null,
    actions         jsonb not null
);

create index bot_decisions_lookup_idx on bot_decisions (bot_id, market_id, at desc);
```
- **Sampling Policy**: A row is written **only when desired orders or status change**, eliminating redundant steady-state log spam.

---

## 4. Treasury APIs and Admin Screen

### 4.1 Endpoint Specifications

#### 1. Treasury Summary
- **Endpoint**: `GET /v1/admin/treasury/summary?season={season_id}`
- **Auth**: `treasury` or `super_admin`
- **Response**: `200 OK`
```json
{
  "given_to_players": 3180000,
  "bot_budget": {
    "allocated": 502000,
    "cap": 750000
  },
  "collateral_held": 1420500,
  "fees_collected": 34200,
  "season_grants_next": {
    "at": "2026-11-01T00:00:00Z",
    "approx_players": 3180,
    "approx_total": 3180000,
    "approval_id": "appr_019283",
    "status": "WAITING_SECOND_APPROVAL"
  },
  "books_balanced": true,
  "incident_banner": null
}
```

#### 2. Bot Table Overview
- **Endpoint**: `GET /v1/admin/bots`
- **Auth**: `treasury` or `super_admin`
- **Response**: `200 OK`
```json
[
  {
    "bot_id": "b0a12e34-5678-4901-abcd-ef0123456789",
    "name": "mm-football-01",
    "market": {
      "id": "m1a12e34-5678-4901-abcd-ef0123456789",
      "question": "Will Remo Stars defeat Sporting Lagos?"
    },
    "budget": 50000,
    "used": 45500,
    "holding": {
      "yes": 140,
      "no": 0
    },
    "spread_ticks": 3,
    "last_quote_age_ms": 420,
    "status": "QUOTING",
    "status_label": "Quoting",
    "params_version": 2
  }
]
```

#### 3. Exact Status Labels
To match the UI design specifications:
- `QUOTING` $\to$ **"Quoting"**
- `PULLED_STALE` $\to$ **"Pulled · old data"**
- `PULLED_CAP` $\to$ **"Pulled · holding cap"**
- `PAUSED_MANUAL` $\to$ **"Paused by you"**
- `PAUSED_ALL` $\to$ **"Paused · all bots"**

#### 4. Control Endpoints
- `POST /v1/admin/bots/{bot_id}/markets/{market_id}/pause` `{ "reason": "..." }`
- `POST /v1/admin/bots/{bot_id}/markets/{market_id}/resume` `{ "reason": "..." }`
- `POST /v1/admin/bots/pause-all` `{ "reason": "..." }` (requires `super_admin` or `treasury`)
- `POST /v1/admin/bots/resume-all` `{ "reason": "..." }`
- `PATCH /v1/admin/bots/{bot_id}/markets/{market_id}/params` `{ "params": { ... }, "version": 2 }`
- `POST /v1/admin/bots/{bot_id}/markets/{market_id}/topup` `{ "amount": 25000, "reason": "..." }`
- `POST /v1/admin/treasury/season-budget` `{ "season": "...", "amount": 750000, "reason": "..." }`
- `POST /v1/internal/bots/heartbeat` (Authenticated via Bot API Key)

---

## 5. Review & Next Implementation Phases

Upon approval of this design doc, implementation proceeds across the remaining phases:
- **Phase 2: Migrations & Ledger Kinds** (`015_treasury_and_bots.sql`, ledger entry kinds `BOT_FUNDING`, `BOT_ALLOCATION`, `BOT_SWEEP`, `markets.opening_price`).
- **Phase 3: Core CancelAll** (exchange command, `DELETE /v1/markets/{id}/orders?mine=true`, golden test).
- **Phase 4: apps/say-bots & Quoting Core** (pure math unit tests, executor diffing, stream ingestion, heartbeat).
- **Phase 5: Treasury Service & Admin Server** (`src/treasury/`, `/v1/admin/treasury/summary`, `/v1/admin/bots`).
- **Phase 6: Simulation Harness & Chaos Validation** (`tools/sim`, informed trader scenario, random noise scenario, kill switch latency verification).
