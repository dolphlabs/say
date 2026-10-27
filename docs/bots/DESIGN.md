# Treasury and market-making bots

Status: **proposed; awaiting review**. Date: 2026-10-26.

This is prompt 09's design deliverable. Stop before migrations, runner or
quoting implementation, CancelAll, simulations and new feature tests.
Prompt 09 takes precedence over older treasury/agent proposals.

## 0. PRD, current project and architecture

| User/system | Required outcome |
|---|---|
| Player | Ordinary limit orders provide explainable liquidity; house accounts never trade with one another |
| Treasury operator | Approve bounded capital, inspect commitments/inventory/P&L, change safe parameters and pause bots |
| Approver | Decide an immutable allocation/cap/top-up request independently of its requester |
| Bot runner | Derive deterministic desired quotes, use normal order/hold APIs, recover without duplicates and pull unsafe quotes |
| Incident operator | See authoritative reconciliation/deficit/control health and confirm actual cancellations after a kill switch |

The goal is capped and explainable liquidity, not a prediction advantage.
Risk controls cannot establish that the reference price is correct. A
paused bot leaves ordinary player trading available unless market/global
exchange controls independently halt it.

Inspected implementation:

- Auth and ledger are implemented. Prompts 03–08 currently exist as proposed
  designs; their registry, exchange, stream, positions, approvals and
  settlement APIs must not be described as running dependencies.
- Migration 004 already permits accounts.kind=BOT and wallet
  owner_kind=bot. **accounts.owner_kind does not exist**: use the existing
  accounts.kind as account classification, preserving wallet owner_kind;
  do not introduce two conflicting bot flags to match prompt shorthand.
- BOT_FUNDING already appears in ledger domain and DB kind allow-lists.
  BOT_ALLOCATION and BOT_SWEEP do not. There are no implemented bot capital,
  keys, market envelopes, parameters, telemetry or runner services.
- Grant queries explicitly require accounts.kind=USER. Preserve that
  exclusion and extend portfolio/notification cohort filters to exclude
  bots without excluding their financial settlement entitlements.
- platform/auth currently authenticates opaque sessions, including Bearer
  session tokens. It has no API-key verifier or bot principal. Ordinary
  ledger reads currently identify human wallets; bot-aware projections are
  required rather than passing bot IDs to hardcoded user-wallet reads.
- beneficial_owner_group is a nullable UUID. The shared `house` group is
  a stable configured/seeded group UUID, not a text value inserted there.
- System balances are journal sums, optionally checkpointed in
  system_balances with as_of. System wallet cached fields stay zero.
  post_many locks the complete non-system wallet set once per transaction.

Use `src/bots/{domain,service,store,server}` and
`src/treasury/{domain,service,store,server}`, scaffolded with zokor after
review. Bot domain owns pure quote/reference/risk/diff rules; treasury
domain owns capital/approval rules. Services use ports; stores handle PG,
HTTP, stream transport and secret/storage adapters. Features meet through
services, with transaction-sharing store calls where AGENTS.md permits.
No tenant arguments or direct cross-feature domain imports.

`apps/say-bots/main.sl` is a separate executable's composition/startup root.
It wires the same layered bot feature and reads configuration through
platform/config. The runner gets no PG credentials. Exchange, admission,
holds, matching and financial writes remain in the API process; bot
decisions use a narrowly scoped telemetry API, not direct batch SQL.

## 1. Treasury, approvals, identities and per-market money

### 1.1 Capital authority and ledger flows

Capital is season-scoped, integer SEDI. Every external capital credit to a
bot comes from an applied allocation/top-up approval. Trading proceeds,
fee reversals and settlement returns are earned/recovered money from the
ordinary ledger, not fresh capital allocations.

| Operation | Approval and guards | Balanced movement / business key |
|---|---|---|
| Season cap | bot_season_budget; two distinct authorized operators, neither requester under prompt 03's generic approval rules | issuance −cap, treasury +cap; BOT_FUNDING; bot_funding:{season}:{budget_revision} |
| Initial market allocation | liquidity; treasury approver distinct from liquidity requester; exact season/market/bot/amount/terms binding | treasury −amount, bot +amount; BOT_ALLOCATION; bot_allocation:{approval_id} |
| Top-up | bot_topup; same independent treasury approval rule, required reason and current subject hash | treasury −amount, bot +amount; BOT_ALLOCATION; bot_topup:{approval_id} |
| Final sweep | Verified SETTLED and completed bot accounting; no new discretionary approval to recover existing capital | bot −remaining_market_cash, treasury +remaining_market_cash; BOT_SWEEP; bot_sweep:{bot_market_id}:{decision_id} |

Each posting references the immutable approved subject/revision in
ref_type/ref_id and the season/market where applicable. The ledger hashes
refs but not metadata; an approval ID only in metadata is insufficient.
Claims, counters, ledger posting, audit and outbox commit together. Same
key/same canonical payload replays; a changed payload conflicts. Resolve an
unknown COMMIT from claims/journal before resubmitting a different key.

The season budget is a separate subject from player issuance policy. Use
the generic approvals feature proposed in prompt 03, with two slots for
bot_season_budget and one for liquidity/top-up. No parallel approvals
table or reinterpretation of the player-grant cap. Proposed eligible
operators are treasury or super_admin; bare admin has no treasury power.
The generic non-self rule means a cap request can require three people.

Approve a future SCHEDULED season in advance, but initially post funding
only when that season is ACTIVE. Effective cap/funded_at are explicit;
an approved unfunded cap is not spendable treasury cash. Initial scope has
one funded immutable cap per season. Raising/replacing a funded cap needs
an explicit separately approved delta policy; repeatedly minting its full
replacement amount is forbidden and is outside this initial command set.

The allocated total is **gross initial allocations plus approved top-ups**
across the season. Sweeps/profits/losses never decrement it or replenish
the authorization cap. Under a locked season-budget control row:

```text
gross_allocated + requested_amount <= approved_funded_cap
sum(unique applied BOT_ALLOCATION capital) = gross_allocated
BOT_FUNDING amount = approved initial cap
```

Concurrent approvals cannot both consume the same remainder. Refuse
BUDGET_CAP_EXCEEDED without a partial allocation. Unapplied pending requests
may be shown as commitments, but are not allocated or funded capital.
Do not spend system:collateral or system:fees to create bot capital.

Applying liquidity creates/funds the bot-market assignment and advances
FUNDING→OPEN in the same authoritative workflow only if all prompt 03
guards still pass: open_at due, active unexpired season, close_at future,
approved source/terms and matching original approval. Early funding waits
for scheduled opening; expired/stale requests cannot bypass the registry.
Approved allocation alone never forces OPEN against time/market controls.

BOT_FUNDING/BOT_ALLOCATION initially post in ACTIVE seasons only. BOT_SWEEP
must work in ACTIVE/CLOSING/CLOSED after verified settlement. Season
finalization must wait for required bot sweeps, otherwise prompt 08 could
FINALIZE before the new recovery posting is permitted. Take season share
locks for admitted financial work; FINALIZED blocks new bot movements.
Keep mandatory recoveries possible during a trading halt.

### 1.2 Shared wallet, separate market envelopes

One logical bot has an ordinary BOT account per season, with one SEDI
wallet and per-market outcome wallets. This fits one authenticated
WebSocket principal per runner; no multi-account credential is invented.
bot_markets identifies each account/market allocation envelope, not just
an unconstrained display bar.

For a market m define C_m as the bot's journal-attributed cash, including
allocation/top-up, trades, fees, payout/refunds and sweeps, with that
market_id. H_m is its outstanding SEDI order holds. Its spendable market
cash is C_m−H_m. Across its assignments, sum(C_m) must equal the account's
SEDI free+held; sum(H_m) must equal its held SEDI. All bot cash entries
must have an approved capital or ordinary trading/settlement provenance
and unambiguous market attribution. No anonymous bot adjustment or grant.

The ordinary order admission path checks both the actual wallet and this
market envelope under the transaction's existing locks. Cached envelope
counters are projections with claims/reconciliation against the journal,
not money transfers outside it. Admission reserves its market capacity
atomically with real holds; fills/releases/rejections update the same
projections with their ledger transaction. Include PENDING commands.
Orders for an unallocated market fail, even if another market has cash.

This additional restrictive bot risk policy is part of ordinary admission,
not a special matching route or a way around holds. Without it, bookkeeping
on a shared wallet cannot enforce "bot money is per market". If review
chooses physical isolation instead, use a dedicated account per assignment
and revisit runner/private-stream partitioning; do not silently sweep a
shared account as though it belongs to one market.

After SETTLED and no remaining admissions/orders/holds/shares for m,
sweep **C_m**, never the shared wallet's whole cash. Under the bot-market
guard and global wallet order, post sweep, zero its envelope, and insert
immutable bot_market_results with allocated, topups, swept and
`pnl = swept - allocated - topups`, final decision and journal reference.
Zero cash records completion without an invalid zero-entry posting. Replay
cannot sweep again or overwrite results. Payouts/void fee refunds finish
before this step, including sold-out fee-only bot entitlements. Other
markets retain their money and may continue quoting.

### 1.3 Treasury deficits and reconciliation

Bot budget authority and treasury's current cash are distinct. Void policy
can create a treasury deficit; it does not grant permission to mint another
bot cap or raid collateral. Show gross cap use, funded amount, treasury
cash, outstanding obligations and void shortfall separately.

Proposed conservative funding guard: no new allocation/top-up when
spendable treasury cash cannot cover it. Because system wallets do not lock
a cached balance, a bare SUM followed by a debit is racy. Treasury control
must reserve committed obligations under a dedicated spend/commitment
guard, shared with other treasury-spending workflows. For void, reserve
the full frozen refund obligation before parallel account batches, then
consume that reservation; do not acquire a global balance lock on every
settlement payout. Approval-authorized void shortfalls can exceed cash
under prompt 08; they reduce uncommitted capital and block new bot spending.
Define this contract with resolution before implementation, including
unknown commits, release and journal-backed projection reconciliation.

Global lock order amendment for these workflows: season, treasury
commitment guard when needed, season bot-budget control, market, approval/
bot-market work guards, existing command budget and sorted wallet union.
Do not acquire a treasury/budget guard after a wallet. Normal fills need no
global treasury lock; the low-frequency capital workflow must not serialize
player matching. One post_many per transaction remains mandatory.

Prompt 08 delegates shortfall funding to this stage, but prompt 09 does not
specify a separate issuance approval kind/threshold for it. Expose amount,
decision, approval/progress and incident detail; flag its financing command
for review. Do not misuse BOT_FUNDING or the existing player grant policy
to mint a void bailout. A separately authorized treasury funding policy is
needed before implementing such a credit.

Reconcile cap/funding/allocation/sweep claims, per-market envelope cash and
holds, bot wallet owner kinds, approved capital provenance, share supply,
collateral and settled results alongside prompts 02/05/08. Failed financial
checks use trading_halted and incident alerts. A stale/missing recon run is
"Unknown/stale", never a green "Books balance?". Treasury totals include
as_of and a coherent snapshot/reconciliation identity.

### 1.4 API keys and the house group

bot_api_keys stores public key ID, bot/account/season identity, high-entropy
secret hash, allowed scopes, created/expires/revoked timestamps and rotation
lineage. Generate secrets with verified crypto.rand; compare hashes with
constant-time equality. Show the secret once; never log/store it in audit,
decisions, URLs or heartbeat payloads. Rotation has a bounded overlap;
revocation invalidates HTTP and existing authenticated stream access.

Scopes authorize trade admission/cancel, own orders/positions/bootstrap,
stream, heartbeat and decision telemetry only. They confer no admin,
funding, grants or params mutation rights. Server resolves account and
owner_kind from the key; it never trusts bot/account/group supplied in JSON.
Bot accounts have no password/session login path or season grant, and no
leaderboard or player-notification delivery. Financial postings remain.
Provision BOT accounts from inception; do not convert a funded player
account and falsely attribute its old grant/cash to approved bot capital.

Extend platform/auth with a typed session-or-bot trading principal; admin
routes still require human session and role. A bot key is not a session
token: separate parsing/lookup paths, reject conflicting credentials, bind
expiry/revocation/season and require TLS. Stream upgrade uses Authorization
for this native client, not a query-string API secret.

zokor.rules currently requires the literal require_session guard on signed-in
server routes. Support the new authenticated trade guard explicitly in
the checker/framework contract before adding bot routes. Do not label an
authenticated bot endpoint zokor:public just to silence the rule. Preserve
session authentication for players and verify equivalent coverage of both
principal types. No API-key implementation is claimed from current auth.

All bots and every staff/admin role proposed in prompt 03 belong to house:
admin, super_admin, curator, resolver and treasury. Effective house identity
is authoritative, not runner-provided. Map existing staff/bots before bots
can quote. Role/group changes must fence and cancel/revalidate affected
resting and PENDING orders before becoming effective; stale snapshot group
IDs cannot permit a house fill. Commit validates identity/group versions
of both sides. Preserve prompt 04's cancel-incoming-remainder STP behavior,
including mint/merge/secondary paths, rather than skipping a house maker.
House grouping does not itself change human grant eligibility.

## 2. Deterministic quoting and risk

### 2.1 Inputs, reference and freshness

quote(inputs) returns DesiredOrders plus status/reason and a diagnostic
summary. It performs no I/O. Include the prompt's V, band, tick, reference,
age, book, inventory/basis, cash, allocation, params, fills, market/global
flags. Also supply verified free/held inventory, live/PENDING orders and
unpaid fees, market-attributed cash/realised P&L, manual/drawdown latches,
stream health, control/params versions and an explicit evaluation time.
Digest the canonical versioned input, not arbitrary JSON map ordering.

opening_price is an approved immutable Yes price, defaults to V/2, and is
included in the market form/terms hash/history. Proposed off-grid default:
nearest legal tick to V/2, ties to the lower tick. An explicitly supplied
off-grid/out-of-band value fails validation. Add this to prompt 03's freeze
rules; opening is not permitted to change a bot's approved anchor silently.

After opening use a time-based trade EWMA, half-life300,000ms, excluding any
fill in which this logical bot is a participant. Replay canonical Yes prices
and stable fill IDs in exchange order; an out-of-order/duplicate event
cannot move the reference twice. Define pure recurrence
`r_new = d*r_old + (1-d)*trade_price`, d=2^(-elapsed/300000), clamped to band.
Group trades at the same timestamp deterministically before applying the
time update, using their quantity-weighted Yes price. With no eligible
trades, retain opening_price. Other market volume is not proof of a new
eligible reference observation.

There is no installed math package/exp API to assume. Proposed numeric
contract: Q24 fixed-point reference/decay, checked wide products, full
half-life shifts plus a versioned fixed table for remainder-time decay;
deterministic rounding and approximation bounds become golden vectors
against an independent high-precision reference after review. Preserve
fractional reference until bid/ask tick rounding. No wall clock, random
jitter or external calls inside the pure function. External reference is a
future port with value/source/as_of/health; ship no odds-feed adapter.

**Freshness clarification for review:** track both last eligible trade time
and the age of the last authoritative, contiguous reference/market snapshot.
Proposed ref_age_ms is the latter observation age for the internal reference,
so a fresh validated opening anchor can quote a quiet new market. The value
may be unchanged while the observation is new; expose both ages. A socket
pong or runner heartbeat alone must not refresh it. Requires a server
snapshot/reference checkpoint carrying real as_of and stream sequence.
If ref_age instead means last trade age, an idle market necessarily pulls
after30s; that conflicts with continuous opening liquidity and must be
chosen explicitly, not hidden by resetting a local timer.

Gap/degraded/disconnected stream makes data untrusted immediately, even if
the last value is recent. Pull and rebuild from coherent REST snapshot and
sequenced deltas. Prompt 06's twenty-second transport ping and sixty-second
timeout are too slow for the one-second stale-stream pull target; use
source progress/health deadlines and the server quote lease in §3.

### 2.2 Price, layers and inventory preference

All ticks below are price distances, not raw sedi. Let t=tick, n=yes−no,
u=abs(n)/max_net_shares (max_net_shares>0), and sign(0)=0:

```text
shift_ticks = ceil(skew_ticks * u)
r_prime = r - sign(n) * shift_ticks * t
vol_add = vol_ticks if eligible five-minute high-low > 3*t else 0
s = base_spread_ticks + vol_add + floor(4*u)
h = ceil(s/2)
bid = floor_to_tick(r_prime - h*t)
ask = ceil_to_tick(r_prime + h*t)
```

Clamp the central bid/ask to the legal grid. If clipping collapses them,
use the adjacent inner tick where available; otherwise return no quotes
with PULLED_MARKET and a price-grid diagnostic. A bot-funded market needs
at least two legal ticks; prompt 03 permits a one-price band generally, so
reject that funding configuration without changing unrelated markets.
For odd s the resulting width may exceed s: two ceil halves of3 give4.
Never force a crossed pair just to satisfy a two-sided uptime measurement.

Adverse-selection state counts deduplicated fills hitting the canonical
Yes bid or ask. Four hits on the same side within the last60s add2 ticks
outward on that side for120s; another qualifying burst extends from its
latest trigger. BUY YES/SELL NO are bid-side, SELL YES/BUY NO ask-side.
Partial fills count by distinct committed fill ID, not socket messages.
Persist/rebuild trigger history on restart; expose the active side/expiry.

For levels i=0..levels−1, move bid down i ticks and ask up i ticks. Initial
safe config limits levels to1..3 with exact weights 1,3/5,7/20. Drop an
out-of-band level rather than clamp several orders onto the same price.
Merge duplicate own-outcome/side/price intents deterministically.

Let A=initial allocation+topups and M=spendable market cash. Proposed capital
use `a=clamp((A-M)/A,0,1)`; include cash holds/unrecovered spending, fees and
realised cash in M, not just remaining position basis. A must be positive.
Shrink factor is1 through70%, then `(1-a)/0.3` to zero at100%.
Layer quantity=floor(base_size*weight*factor), checked arithmetic. Zero-size
or below-minimum-notional orders disappear. At>90% use the amber budget
bar. Holdings' face value is not the cash-utilization definition.

Consume existing *unreserved* inventory first across the whole desired set:
canonical bid q maps to SELL NO at V−bid for available NO, then BUY YES for
any residual; canonical ask maps to SELL YES at ask for available YES, then
BUY NO at V−ask for residual. Splitting is permitted and can create up to
twelve orders across three layers; honor max_open_orders after splitting.
Both own-term prices must be legal/on tick. Symmetric bands and V divisibility
in prompt 03 make complements legal; still validate every emitted order.

All layers share one resource budget. BUY reserves limit*qty plus unpaid
S1 fee; SELL reserves shares plus its unpaid cash fee. Enforce original
minimum notional2, max_order_qty, actual free cash and shares, and available
market envelope. Prefer inner levels, then bid/ask in a fixed documented
tie order; trim/revalidate outer quantities until the full set is feasible.
Use whole-share integers and checked arithmetic, never negative/overflow
sizes or rounding a positive unavailable quantity up.

For stable repricing, planning can include the resources in this bot's
own cancellable quote holds, explicitly distinguished from current free
resources. Existing retained orders consume that budget once. A desired
post-cancel plan confers no immediate spending permission: executor waits
for confirmed releases before placing any replacement. No double-counting
old holds as free cash. Property tests check the full target reservation
and every executable action against its corresponding actual state.

### 2.3 Loss caps include pending fills and fees

The requested inventory diagnostic is
`worst_case_loss = max(B_yes+B_no-yes*V, B_yes+B_no-no*V)`.
Keep it in decisions, but **it alone cannot guarantee the simulation loss
bound**: it omits realised losses, fees and unfilled orders.

For hard limits use market cash C including both free and held, approved
capital A, quantities y/n and realised cash already reflected in C:

```text
L_yes = A - (C + y*V)
L_no  = A - (C + n*V)
effective_loss = max(0, L_yes, L_no)
```

Evaluate every live/PENDING order and candidate fill subset conservatively.
At its worst permitted price p, quantity q and unpaid first-fill fee f:

| Order | Change in L_yes | Change in L_no |
|---|---:|---:|
| BUY YES | (p−V)*q+f | p*q+f |
| SELL YES | (V−p)*q+f | −p*q+f |
| BUY NO | p*q+f | (p−V)*q+f |
| SELL NO | −p*q+f | (V−p)*q+f |

For each outcome, add each outstanding order's maximum adverse change over
no fill/partial/full fill, including a fee only if not previously charged.
Independent maxima are conservative even when not simultaneously fillable.
Use actual remaining quantities and no hypothetical simultaneous offsetting
fills. Likewise bound net shares over all subsets, not only after both
quote sides fill. Re-run with retained orders, tolerance differences and
in-flight unknown admissions. Own-terms limit bounds any execution price
improvement, preserving the conservative calculation.

Permit fresh orders only when both outcome losses and worst-case net
exposure remain within max_loss/max_net_shares. At/beyond a cap emit only
orders that strictly reduce the binding worst-case risk without worsening
the other bound; otherwise none, status PULLED_CAP. Recheck all valid
partial-fill quantities, not just a full hedge. If no whole share is safe,
stop. Prevent breaches **before** orders rest; detecting a breach after
an informed trader fills the book cannot satisfy max_loss.

Enforce this admission/commit policy on the API side too, under bot-market
guards and ordinary wallet/hold locks. Runner estimates can be stale or a
runner can malfunction. Reducing params below current/pending exposure
fences new admission and drains/replans orders before adopting the new
version. Risk bounds permit existing positions to remain; they do not
authorize forced loss-making liquidation or direct transfers.

Season drawdown is a sticky latch per logical bot/season. Proposed season
P/L is sum(C+y*r+n*(V−r)−A) over unswept assignments plus completed
bot_market_results.pnl; do not include a swept assignment twice. This
subtracts approved capital flows so a top-up cannot reset losses. Compare
with its flow-adjusted high-water P/L; >season_max_drawdown latches
PULLED_DRAWDOWN. Define/record mark source, reference freshness and peak in
server state; stale marks cannot unlock it. An authorized explicit resume
acknowledges the latch with a new checkpoint/audit, and all other guards
still apply. Restart or resume-all does not silently reset drawdown.

### 2.4 Hard stops and worked quote

Status precedence: PAUSED_ALL, PAUSED_MANUAL, PULLED_MARKET,
PULLED_STALE, PULLED_DRAWDOWN, PULLED_CAP, QUOTING. Preserve all concurrent
reason flags even though the table shows one primary label. Every hard
stop cancels existing quotes immediately, bypassing min_requote_ms and the
normal churn limiter; PULLED_CAP alone may retain a proven reducing side.

| Guard | Required behavior |
|---|---|
| Global/manual pause | No desired orders; pause latch/version persists |
| Market not OPEN, season expired, trading_halted | No desired orders; cancellations/releases remain allowed |
| ref_age_ms>30,000 or any stream gap/degradation | No desired orders, revoke quote readiness and resync |
| Net/loss cap | Only proven risk-reducing orders; none if no safe side |
| Season drawdown | No desired orders until explicit authorized latch reset |

Worked example, with the prompt's V100, r57, net+140, max_net400,
skew_ticks4 and base_spread2. Additional inputs needed to get exact orders:
tick1, band1..99, YES140/basis7000, NO0, allocation20,000, cash12,999 after
one historical fee1; no outstanding holds/orders, no volatility/backoff,
three levels, base_size20, max_loss12,000, max_open_orders≥6. Market OPEN,
data fresh and no pauses/drawdown.

```text
u = 140/400 = 0.35
shift = ceil(4*0.35) = 2 ticks; r_prime = 57−2 = 55
s = 2 + floor(4*0.35) = 3; h=2
bid=53, ask=57; actual central spread=4 ticks
allocation_use=(20000−12999)/20000=35.005%; size factor=1
sizes=20,12,7
```

| Canonical level | Exact ordinary order | Principal/share hold | Unpaid fee hold |
|---|---|---:|---:|
| bid0=53 | BUY YES20@53 | S1060 | S1 |
| bid1=52 | BUY YES12@52 | S624 | S1 |
| bid2=51 | BUY YES7@51 | S357 | S1 |
| ask0=57 | SELL YES20@57 | YES20 | S1 |
| ask1=58 | SELL YES12@58 | YES12 | S1 |
| ask2=59 | SELL YES7@59 | YES7 | S1 |

All six use S2047 cash holds and YES39 shares; cash left free10,952,
YES left free101. No NO is held, so bids buy YES; asks consume YES before
buying NO. With no YES inventory, those asks would BUY NO at43/42/41.
All prices/notionals and complements pass the band/tick rules.

Diagnostic inventory loss before quotes is7000, effective fee-inclusive
loss7001. Worst outstanding subset is all three buys filling without sells:
capital loss7001+2041+3=9045, netYES179, below both caps. Three sells add
potential YES-state loss and reduce NO-state loss; their combined adverse
YES change1654 gives a YES-state bound of−6999+1654=−5345, so the overall
loss bound remains9045. This is not approval to
ignore different resting quantities in the executor's20% tolerance.
The arithmetic is a design check; golden quote/ledger tests follow review.

## 3. Runner, ordinary execution, CancelAll and kill switch

### 3.1 Process, transport and bounded tasks

| Task | Responsibility |
|---|---|
| One market loop per active bot-market | Consume ordered events, maintain pure reference/risk state, quote then diff |
| One WebSocket per runner | One bot-account principal; book/trades/private order/control fanout; bounded offers |
| HTTP order client pool | Bounded ordinary API requests, deadlines and stable idempotency keys |
| Heartbeat every2s | Bounded batched bot-owned assignment status/last-quote/inventory/use telemetry |
| Decision writer every500ms | Batch changed decisions to scoped API; bounded queue, no runner SQL |
| Pause/control watcher | Highest-priority control events plus authoritative boot/periodic checks |
| Runner supervisor | Join failures, recover state, renew ownership/readiness leases and shut down cleanly |

Use top-level spawn functions with explicit arguments. There is no native
try_send: nonblocking fanout uses select with send/default, per slang-notes.
Overflow on a book/private update marks that market degraded and pulls;
silently dropping a required delta is not a healthy mirror. Coalesce safe
latest snapshots/status hints only; immutable fills/order changes require
gap recovery. Bounded channels, byte budgets, client pool and timer tasks;
no task for every delta or unbounded retry.

One runner owns one bot-season account and a bounded assignment set.
Prompt 06 permits50 channels/socket and rate-limits subscriptions. Count
all channels, including private/control, then partition bot accounts/runners
to stay inside that limit. Fifty bot-markets may need multiple runners;
do not silently raise gateway limits or multiplex unrelated private
accounts on one principal. Stagger resubscription within limits, with all
quotes pulled until each assignment's coherent mirror is ready.

Current zokor's public new_conn/receive and inspected frame code are server
oriented; default input expects masked client frames. No installed generic
WebSocket client/dial API was found. Before runner implementation, verify
or add a tested outbound-client transport (TLS/upgrade validation, masked
client writes, unmasked bounded server reads, fragmentation/control frames
and deadlines). Verified net.tls_dial_until/crypto primitives are building
blocks, not an already complete client. Do not feed server frames into the
server codec and assume compatibility or import private package internals.
Port the prompt 06 mirror's sequencing/resync semantics with shared vectors;
there is no implemented say-stream module in this workspace to reuse yet.

### 3.2 Diff, idempotency and recovery

Compare own-outcome/side/price and deterministic level identity. Retain a
live order only if the price matches and remaining size differs by≤20% of
desired size (integer cross-products), and the **retained actual size**
still passes all resource/risk/control guards. Desired qty0 never retains
an old order. Favor existing valid priority; duplicate extra levels cancel.
Otherwise cancel then replace, after committed cancellation/release.

Maintain at most max_open_orders across resting, PENDING and unknown
placements; count split inventory intents separately. Bound normal actions
by max_ops_per_sec and requote no faster than min_requote_ms (default250).
Do not defer a hard-stop cancellation behind ordinary placement traffic;
reserve cancellation/control capacity. A pending cancel still holds funds
and can fill until authoritative commit. Never place its replacement
against an anticipated release or try a new ID after an HTTP timeout.

Order identity is derived from durable runner ownership generation,
assignment, plan generation and action ordinal. Retry the same uncertain
request with the same order ID and Idempotency-Key. New plan generation is
durably checkpointed through the scoped runner service before placement;
a restarted process cannot reuse an ID for different economics. Ordinary
admission replay returns its actual prior result without creating holds.

Bootstrap under a single active runner lease/fence per account/assignment:
read control/params/allocation/quote readiness; page GET /v1/me/orders and
positions/balances (including PENDING outcomes); recover request identities;
subscribe and reconcile snapshot/stream epochs; cancel unknown/orphaned
quotes before issuing a fresh plan. Use bot-aware normal read APIs.
Leases fence a replaced runner on admission and lease renewal, not just in
the new runner's memory. Lost leases stop new quotes and trigger server
cancellation even if the old process continues running.

### 3.3 CancelAll semantics and durable pause

Proposed core command CancelAll{account_id} cancels this account's resting
orders in the same canonical order as Close (bid prices ascending, asks
ascending, FIFO per level). It changes no other account's orders, charges
no new fee and releases exact residual holds through normal output.
Keep state hashes/replay deterministic; an empty set is successful no-op,
not a fabricated journal transaction.

DELETE /v1/markets/{id}/orders?mine=true authenticates a human or bot trading
principal, ignores/rejects caller-supplied account overrides, and admits a
durable command with standard idempotency, owner fencing and command
capacity. It returns committed counts or202 with command identity, not a
false immediate guarantee. Players get the same command/ownership checks.
It is available for cancellation when trading/placements are blocked.

Define its cutoff in durable admission order. Cancel all caller orders
admitted before that cutoff, including PENDING places that would otherwise
rest after the sweep; order the account's pending work or terminally reject
covered placements and release their holds. Future ordinary placements are
allowed unless a bot pause/fence separately blocks them. Tests cover both
admission/actor orderings, already-partial orders and timeout replay.
Capture the cutoff under the account/market admission guard; a bigserial
ID alone is not commit order and cannot define this barrier correctly.

Pause-all transaction writes durable global pause=true plus monotonic
control epoch, audit/outbox and cancellation work for every funded active
assignment. New bot admission/commit checks the authoritative pause epoch;
it cannot rely on a delayed event or cached flag. A concurrently committing
fill linearized before pause stands; no placement under the old epoch may
rest after the pause fence. A server cancellation coordinator dispatches
ordinary CancelAll through the reserved control path, even if runners or
Redis have died. A paused bot never needs privileged matching access.

Use a short-lived server quote-readiness lease, proposed renewal every200ms
and expiry after500ms, carrying assignment/owner/control epoch and validated
stream/snapshot progress. Expiry/gap schedules CancelAll. Heartbeat every2s
feeds UI and is **not** a lease fast enough to implement stale-data safety.
Wall-time timers use monotonic clocks locally and DB deadlines/epochs for
authority; never compare clocks from different hosts without a protocol.
The remaining500ms of the one-second stale target budgets detection,
dispatch and committed cancellation; tune against actual50-assignment tests.

Staleness/degradation detection→all affected quotes cancelled target≤1s;
pause-all durable commit→every bot resting quote cancelled target≤2s.
These include coordinator dispatch/actor persistence/hold release, not
just event receipt or HTTP acceptance. Reserve and measure enough command,
PG and control capacity. During API/DB outage these are targets that can
fail; declare incident, block new bot placements and report uncancelled
orders. Never claim network-independent instant cancellation of a
previously committed resting order.

Resume-all clears only the global latch. It cannot clear manual pause,
drawdown, stale data, cap or market/global trading halt. Per-market resume
clears the specified authorized manual/drawdown latch with reason/version,
then reboots readiness; it does not promise QUOTING immediately.

### 3.4 Decisions, telemetry and observability

bot_decisions records bot/market, at, inputs_digest, reference/reference
prime, actual spread, utilization, requested/effective loss, status and
planned actions. Add params/control/reference/runner/plan versions,
reason flags and linked accepted/rejected order results. Record only when
desired orders or status change; sort canonical desired orders before
comparison. Actual action failures are distinct execution/audit facts,
not rewritten old decisions. Store sufficient sanitized input snapshot or
immutable input references to explain the digest; a hash alone cannot
explain a decision once transient stream data expires.

Keep decision telemetry seven days, partitioned/cleaned in bounded work;
financial journals, approvals, capital/results and operator audit are
retained. Idempotent batch IDs prevent telemetry replay duplicates. If a
bounded decision queue stays full, mark telemetry degraded and pull rather
than silently run indefinitely without required explanations.

Heartbeat inventory/use/age is untrusted runner telemetry. Cross-check
wallets/orders/positions for the treasury view; absent heartbeat marks
runner unhealthy even if its last reported status said QUOTING. A quote's
age is the last confirmed valid/live plan, not the last attempted POST.
Retained quotes can remain healthy while their price is unchanged; expose
plan confirmation age and last actual replacement time separately.

## 4. Treasury/admin APIs, copy and permissions

Human admin APIs require session plus treasury/super_admin authorization;
bare admin does not imply money rights. Proposed same role set may read,
pause/resume, request caps/top-ups and update bounded params. Funding votes
obey independent approval roles/slots. Bot keys access only their scoped
internal/read/trade endpoints. Every command validates versions, reason,
subject hash, limits and identity in its transaction.

| Endpoint | Contract |
|---|---|
| GET /v1/admin/treasury/summary?season= | given_to_players; gross bot allocated/cap/funded/pending; collateral_held; fees_collected; next grant estimate/approval; as_of/recon/treasury obligations/deficit |
| GET /v1/admin/bots | Paginated assignment rows: bot/name/market, used/budget, actual YES/NO, spread_ticks, quote age, status/label/reasons, versions and heartbeat health |
| GET /v1/admin/bots/{bot}/markets/{market}/decisions?cursor= | Bounded keyset history, diagnostics and linked actions; no secrets |
| POST .../{bot}/markets/{market}/pause | reason,expected version; durable manual latch, audit/event and cancel work |
| POST .../{bot}/markets/{market}/resume | reason,version,latch to acknowledge; cannot bypass other guards |
| POST /v1/admin/bots/pause-all | reason,global version; treasury/super_admin; durable fence and cancellation tracking |
| POST /v1/admin/bots/resume-all | reason,global version; clear global latch only |
| PATCH .../{bot}/markets/{market}/params | Full validated params,version; immutable version history and safe drain/activation |
| POST .../{bot}/markets/{market}/topup | amount,reason,version; create bot_topup request, never credit immediately |
| POST /v1/admin/treasury/season-budget | season,amount,reason,version; create two-slot cap request |
| POST /v1/internal/bots/heartbeat | Bot-owned assignment batch, lease generation/telemetry time/version; bounded body/rate |

Required supporting contracts, proposed additions rather than claimed APIs:
independent cap/liquidity/top-up approve/reject subject commands; bot key
issue/rotate/revoke; runner bootstrap/checkpoint/readiness renewal; scoped
decision batch ingest; authoritative pause/cancel progress. Each goes
through the relevant service with audit and outbox. Approval inbox UI in
prompt10 does not substitute for backend commands in this stage. No key
creation through ordinary public signup. API documentation follows review.

Summary definitions:

- Given to players is gross applied SEASON_GRANT journal credits, excluding
  BOT capital; not the sum of current cash wallets or system:issuance's
  total debit, which also includes BOT_FUNDING.
- Bot budget allocated/cap uses cumulative capital including top-ups.
  Assignment budget=A, used=clamped unavailable capital under §2.2; expose
  cash/holds/basis/profit separately rather than imply budget use is P/L.
- Collateral held sums SEDI system:collateral:* balances for the selected
  season at a declared checkpoint. Never sum their zero cached fields.
- Fees collected shows gross FEE credits; expose FEE_REFUND and net fee
  balance separately after voids. A negative fee balance is an incident,
  not a negative count of charged orders.
- Next season grants uses the existing player issuance policy/approval
  round and eligible USER estimate. Approximate counts/totals are labelled;
  request status distinguishes waiting second approval from funded/active.

| State | Exact primary label |
|---|---|
| QUOTING | Quoting |
| PULLED_STALE | Pulled · old data |
| PULLED_CAP | Pulled · holding cap |
| PAUSED_MANUAL | Paused by you |
| PAUSED_ALL | Paused · all bots |
| PULLED_MARKET | Proposed additional label: Pulled · market paused |
| PULLED_DRAWDOWN | Proposed additional label: Paused · drawdown |

Required five labels are preserved. The last two states need distinct copy
because the prompt's five strings cannot truthfully describe them all.
Last quote age amber threshold is configurable; >30s/data gap is already
a pull condition, not merely an amber warning. Show cancellation pending
separately from confirmed pulled. Footnote retains the stated stale/holding/
market pulls and house STP promise only when corresponding controls exist.

Register BUDGET_CAP_EXCEEDED plus typed approval-required/stale, insufficient
treasury, allocation/risk/key-scope/lease/control-version failures. Reuse
existing auth/order/conflict/unavailable errors. Unexpected store/transport
details are logged, never returned to clients. Every human/internal state
write has transactional audit and outbox, including failed-risk actions as
appropriate; high-volume unchanged heartbeat rows can be batched/coalesced
without implying a new quote decision per tick. Redact key material.
Pause, resume, parameters, allocation, key revocation and incident events
use versioned admin/bot-authorized channels; private bot state is not a
public market broadcast. Events are hints over durable state/work.

## 5. Migration, simulation, tests and review decisions

Forward migrations after review add bot_api_keys, bot_markets/envelopes,
immutable bot_params versions, seven-day bot_decisions, bot_market_results,
budget subjects/claims/control, runner fences/checkpoints/readiness,
capital/treasury commitments and key/group constraints; reuse generic
approvals. Add BOT_ALLOCATION/BOT_SWEEP and guarded sweep season eligibility,
plus opening_price/terms binding. BOT_FUNDING and BOT accounts already
exist. Preserve real history; no dev reset or edits to applied migrations.
Financial results, parameter/capital/approval history and audit are
append-only for runtime writes; decision retention has an explicit bounded
cleanup authority without permitting journal/history deletion.

All bounds/URLs/pools/scopes/leases/retention/operator-safe param ranges
come from platform/config once. Pure domain validates positive quantities,
safe grid, ≥2 ticks for quoting, levels1..3, max limits and checked products.
Document exact initial safe numeric defaults before exposing admin editing;
reject unsupported combinations instead of relying on UI controls.

Required gates after implementation:

- Property/golden quote vectors: worked example, V200/tick>1, extreme/skew/
  band edges, empty/one-price grids, zero sizes, exact70/90/100% use,
  splitting holdings, fee buffers, all resources and partial-fill risk.
- Reference replay/own-fill exclusion, half-life, same-time grouping,
  volatility/backoff exact thresholds, stale/gap clocks and fixed-point
  approximation bounds against an independent reference.
- Loss-cap regression where current positions pass but pending buys would
  breach, fees push over a cap, realised losses survive rebuy/topup, and
  only one risk-reducing side is safe. Net and seasonal drawdown tests.
- Minimal diff with20% retained-size risk recheck,1000-delta bursts, order/
  ops/requote limits, unknown commit/cancel responses and zero duplicates.
- Parallel budget approvals/allocations/top-ups, gross cap not replenished
  by sweeps, exact per-market/shared-wallet sums, cross-market spending
  refusal, simultaneous settlement/sweep/finalization and ledger P/L.
- Bot grants/leaderboard/notifications excluded; bot settlement included;
  BOT versus USER wallet selection, key scopes/rotation/revocation and
  authenticated-route checker coverage.
- Bot↔bot and bot↔all staff STP across every fill mode; role/group change
  races with makers and pending commands, no fee on never-filled STP.
- Deterministic CancelAll golden: canonical order, exact hold releases,
  PENDING cutoff, partial fills, idempotent empty/repeated commands and
  ordinary player ownership protection.
- Kill runner mid-quote, restart/takeover, denied old fence, orphan cleanup,
  stale stream pull≤1s; pause-all50 assignments across runners≤2s measured
  through journal/order completion. Include Redis outage, slow DB and a
  down runner; report failures/limits rather than omit hard cases.
- Treasury aggregates against journal/checkpoint, void fees/deficit,
  commitments, next grants and never-green stale/failed reconciliation.

tools/sim is a test-only client harness, no production bypass. Spawn many
simulated ordinary traders against an isolated test exchange with seeded
capital and deterministic scenario seeds/clock inputs. An informed trader
knows the final outcome and targets every executable quote: final cash/
settlement fee-inclusive loss≤max_loss, including live/pending worst cases.
Noise traders exercise both sides; measure >90% eligible-open two-sided
uptime, spread kept, inventory/net, worst-case loss, turnover/fees and final
P/L. Declare what "near flat" means before measuring; report ineligible
pause/stale/cap time separately and as total time, without removing adverse
periods to inflate uptime. Report hardware/compiler/DB/config, fees,
seeds, warmup/duration and confidence/noise. No simulation or kill-switch
performance is claimed by this design.

Design-stage baseline checks (2026-10-26): whitespace and independent exact
worked-example arithmetic passed. `zokor check` passed for the existing
eighteen packages, and `make build` passed with existing generic-instantiation
and OpenSSL deprecation warnings. Required `make check` stopped at the
existing `test_should_time_out_a_send_to_an_unreachable_provider`: the
sandbox returned `dial 10.255.255.1: Operation not permitted` instead of a
timeout. DB/Redis integration and opt-in ledger load tests skipped without
their test settings. These checks validate no bot implementation, strategy,
client transport, simulation or kill-switch timing.

| Review | Proposed clarification / dependency |
|---|---|
| R1: Identity | Use existing accounts.kind=BOT; authoritative house UUID and group-change fencing |
| R2: Capital | Two independent cap votes; gross allocations+topups count forever; no implicit cap reuse or replacement mint |
| R3: Market money | Shared season wallet plus enforced journal-backed market envelopes; sweep only that market's cash |
| R4: Treasury | Reserve obligations consistently with void; separate approval policy needed for shortfall financing |
| R5: Risk | Fee/realised/pending-fill loss envelope enforced server-side in addition to requested inventory diagnostic |
| R6: Quote maths | Tick-scaled skew, floor quartiles, ceil half spreads, deterministic grid/size/split/resource rules |
| R7: Reference | Define authoritative observation freshness separately from last trade; opening tick rounding and fixed-point EWMA vectors |
| R8: Runner safety | One bot principal per bounded runner, verified client transport, durable fence/readiness and server CancelAll fallback |
| R9: Authentication | API-key trading/stream scope and checker support; no false public markers or session-token overloading |
| R10: Completion/UI | Sweep before season finalization; additional market/drawdown copy; backend approvals/key/control contracts before UI |

After review: finalize dependency/auth/client/treasury contracts, migrate and
wire capital/identity, add risk admission and CancelAll, pure quote/mirror/
runner/executor, admin telemetry, then simulate/fault-test and report actual
results. Prompt10 adds the approvals inbox UI; an external reference adapter
remains later work. This document authorizes no funding, issuance or bot
activation by itself.
