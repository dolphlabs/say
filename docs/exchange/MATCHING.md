# Matching core: model, accounting and implementation design

Status: **implementation in progress**. Design date: 2026-10-26.

The user authorized implementation of prompts 03–10 on 2026-10-27. The
independent Python oracle, Slang domain core, record/replay bridge and
comparison harnesses now exist. This is their PRD and technical contract;
../IMPLEMENTATION.md tracks verified progress and remaining gates. References
below to unavailable registry APIs describe the design-time baseline.

## 0. Product requirements and project integration

### Purpose and acceptance contract

The core decides what one ordered command does to one binary market. Its
inputs contain all necessary facts. It reads no clock or environment,
performs no database/network/logging/random operations and creates no
tasks, locks or shared mutable state. The actor introduced in prompt 05
serializes commands, commits economic effects, then applies decided book
changes. A planned fill is not a committed trade.

| Consumer | Required result |
|---|---|
| Exchange actor | Deterministic transition with exact fills, order changes, holds and journal descriptions; planning cannot change live book state |
| Buyer/seller | Best eligible price before time priority, maker receives its own limit, taker gets improvement, one fee on first fill |
| Ledger adapter | Balanced, hold-backed transactions with stable business keys and no ambiguity about currency versus share units |
| Market-data adapter | Canonical Yes-price trades and changed levels; mirrored No view derived outside the core |
| Recovery worker | Versioned snapshots and decided transitions reproduce identical logical state and hashes |
| Maintainer | Independent oracle, differential tests, invariants and honest allocation/latency comparison with Go |

Requirements are correctness and deterministic recovery first, followed by
measured speed. The release gate requires golden A–J tests, exhaustive and
differential comparison, at least 1M commands in CI and 100M nightly,
plan-without-apply immutability, snapshot/tail replay and all four accounting
modes. No throughput advantage or proof of correctness is claimed here.

### Existing code and layout

- `src/ledger/domain/posting.sl` defines `LedgerTx`, `Entry`, `Owner` and
  `HoldOp`, validates per-asset balance, and canonicalizes postings.
- `src/ledger/domain/money.sl` has checked arithmetic, SEDI and
  `YES:<market>` / `NO:<market>` asset names. Native slang integer arithmetic
  can wrap, so no unchecked economic arithmetic is permitted.
- `src/ledger/store/posting.sl` exposes `post_many` on the caller's
  connection. Calling `post`/`post_many` twice in one DB transaction is
  deliberately refused to preserve wallet lock ordering.
- System owners already exist as `system:collateral:<market>`,
  `system:shares:<market>` and `system:fees`; users and bots use different
  `Owner.kind` values. An account UUID alone does not encode that kind.
- `docs/markets/DESIGN.md` proposes the policy shape, symmetric bands,
  maximum payout 1,000, terms versions and lifecycle integration. There is
  no callable market policy service yet.
- `docs/auth/slang-notes.md` is the established concurrency/language
  baseline. Additional local language-source checks are recorded in §3.

Follow AGENTS.md's feature layout, which explicitly overrides illustrative
`internal/exchange/{domain,book,match}` paths:

```text
src/exchange/domain/    policy, commands, book, matching, postings, hashes
src/exchange/service/   pure public contracts and ledger-description bridge
src/exchange/store/     prompt 05 transaction/recovery adapter
src/exchange/server/    prompt 05 admission and registered HTTP errors
tools/oracle/          independent Python oracle and generators, after review
bench/go-ref/          independent Go implementation for the comparison
docs/exchange/         this contract; BENCH.md only after measurements
```

Use `zokor add feature exchange` after review. Keep the book and matcher in
the same pure domain package, split into ordinary `.sl` files rather than
introducing a second architecture. Every implemented package has adjacent
tests. No HTTP routes or persistence are added by this design stage.

Features meet through service contracts. Do not import ledger/domain into
exchange/domain to reuse types. Define equivalent pure journal descriptions
in the core and materialize real ledger types through a ledger service
bridge. Adding that bridge is a small explicit integration change because
the current ledger service does not export its domain journal types.
The exchange store may call ledger store on the same transaction connection,
as AGENTS.md permits; the core never imports either store.

## 1. One book, price/time priority and economics

### 1.1 Normalize once into Yes prices

Let `V` be the fixed winning-share redemption in integer sedis. Admission
passes a validated immutable policy; constructor validation is repeated
once before a book is usable. Require 10 ≤ V ≤ 1,000, fixed fee F=1,
minimum original notional 2, positive quantity bound, and all registry
band/tick checks. No chance/probability floats enter the core.

| Own-terms order | Book side | Yes-price |
|---|---|---|
| BUY YES at p | bid | p |
| SELL NO at r | bid | V − r |
| SELL YES at a | ask | a |
| BUY NO at q | ask | V − q |

Exactly one slot in one queue represents a resting order. There is no
separate complementary-liquidity index and no second No book. A bid b
crosses an ask a iff b ≥ a. Own-terms execution is x for YES and V−x for
NO, irrespective of whether the order buys or sells.

| Bid type | Ask type | Mode | Quantity-k settlement at execution Yes-price x |
|---|---|---|---|
| BUY YES | SELL YES | TRANSFER_YES | Buyer pays x·k to seller; k existing YES moves seller → buyer |
| SELL NO | BUY NO | TRANSFER_NO | No buyer pays (V−x)·k to No seller; k existing NO moves seller → buyer |
| BUY YES | BUY NO | MINT | Buyers contribute x·k and (V−x)·k; collateral +V·k; new YES +k and NO +k |
| SELL NO | SELL YES | MERGE | Sellers surrender NO k and YES k; collateral −V·k; Yes seller receives x·k, No seller (V−x)·k |

Mode follows the two actual order types; it is never a priority input.

### 1.2 Maker price, priority and self-trade

An incoming bid visits asks in ascending Yes-price; an incoming ask visits
bids in descending Yes-price. At each price, visit one FIFO ordered by
`(accepted_seq, canonical UUID bytes)`, mixing both applicable order types.
The execution Yes-price is always the resting maker's normalized limit.
Thus the maker's own execution price equals its own limit exactly, and the
taker's own execution price improves or equals its own limit.

New placements have `accepted_seq == command.seq`, making tail insertion
valid under gap-free sequencing. Snapshot restoration rebuilds each FIFO
by the explicit tuple; it never trusts slot allocation order. If equal
accepted sequence values are supported by imported fixtures, UUID ordering
breaks ties; reject an out-of-order insertion instead of silently appending.

Before each fill, reject self-matching when account IDs are equal or when
both effective owner-group values are nonempty and equal. Null/empty groups
do not make all ungrouped accounts related. Admission supplies a stable
effective owner-group identifier, falling back to the account identity.
The actor must define how changed beneficial ownership updates resting
orders before further matching; the core cannot refresh it with I/O.

At a self-match, cancel the entire incoming remainder with
SELF_TRADE_PREVENTED; do not skip the maker to reach a later order. Preserve
fills already planned earlier in the command and charge fees only for
orders that actually filled. Maker quantity and its queue position remain.
A partially filled self-prevented command is Accepted with a cancelled
remainder, rather than Rejected with misleading zero-fill semantics.

### 1.3 Symmetric band as an invariant

The policy requires:

```text
1 <= min_price <= max_price < V
min_price + max_price = V
tick >= 1
min_price % tick = 0
(max_price - min_price) % tick = 0
V % tick = 0
```

For any legal own price p, its complement V−p is in the same band. Both p
and V are tick multiples, so V−p is a tick multiple. Matching at a maker
price therefore cannot create an out-of-band/off-tick complementary price.

Keep the defensive INTERNAL_PRICE_OUT_OF_BAND guard. If it fires during
planning, discard **all** tentative fills, fees, releases and book updates
for that command, including earlier tentative matches. Return the internal
rejection, never clamp or publish partial fills. An independently valid
incoming admission hold can be released in the rejected-command cleanup;
never release a corrupt/unverified maker hold. The actor must halt or
quarantine the faulty book and reconcile, rather than continually trading
through a failed invariant. No core logging is involved.

Ordinary invalid limit/notional/quantity input is a validation rejection,
not this internal-invariant error. Overflow also aborts the whole candidate;
none of its earlier tentative effects may survive.

### 1.4 Golden scenarios and corrections

Each row becomes an exact-transition fixture including journal entries,
hold operations, order/level changes, supply and both hashes where relevant.

| Case | Expected principal outcome |
|---|---|
| A | SELL YES 1@60 then BUY YES 1@75: TRANSFER_YES at x=60; buyer improvement release 15; one fee from each first-filling order |
| B | BUY NO 1@45 then BUY YES 1@70: MINT at x=55; buyer principal 55/45; improvement release 15; collateral +100, supply +1/+1 |
| C | SELL NO 1@40 then SELL YES 1@50: MERGE at x=60; proceeds YES 60, NO 40; collateral −100, supply −1/−1 |
| D | BUY NO 2@40 then SELL NO 2@35: TRANSFER_NO at x=60; principal 80; seller receives 10 more than its original minimum |
| E | SELL YES 3@58 seq10, BUY NO 5@42 seq11, then BUY YES 6@60: transfer 3 then mint 3 at x=58; NO buyer retains 2; buyer improvement release 12 |
| F | Asks 58×80, 59×110, 61×180, then BUY YES 250@61: fills 80/110/60 in that order; buyer improvement release 460 |
| G | Self-trade at best price: cancel incoming remainder, maker unchanged; no fee if nothing filled; earlier successful fills, if any, stand |
| H | V=200, band 2…198: BUY YES 3@120 costs principal 360 plus fee 1; later winning redemption is 600, net +239, outside this core |
| I | BUY YES IOC 10@58 with 4 available: fill 4, cancel 6; release 348 for unfilled principal plus any improvement on the 4; no fee refund after the first fill |
| J | Same resting order fills 2 then 3 in later commands: exactly one fee total; a never-filled cancellation returns its entire unused fee hold |

Case C needs an initial backed pair; construct it with prior balanced mint
history or an explicitly validated snapshot. An empty book with zero supply
cannot merge a fictitious pair. Cases containing sells need verified share
holds; fixtures must not silently invent inventory.

**Prompt conflict:** A's "leftover fee hold" cannot mean refunding the S 1
just charged. The buy initially holds 76, consumes 60 principal and 1 fee,
and releases 15. There is no fee remainder. This follows the prompt's
fee-once and complete-hold-accounting rules.

## 2. Commands, plan/apply, holds and transition format

### 2.1 State and admission facts

Logical state contains policy identity/economics, market mode
OPEN/SUSPENDED/CLOSED, `last_seq`, rolling hash, last trade price if any,
YES supply, NO supply, issued pairs, collateral, and active orders/levels.
It is owned exclusively by one actor. Scratch/output buffers are separately
owned; mutable aliases into live state must never escape planning.

An order carries all prompt fields: UUID, account, owner group, outcome,
BUY/SELL, own limit, original quantity, remaining, TIF, accepted sequence,
fee-paid flag, sedi hold ID and optional share hold ID. Add explicit
user/bot owner kind, cumulative filled/cancelled quantities and hold
accounting facts: original held, consumed, released and outstanding amount
per hold. These are needed to produce exact releases and verify quantities
without querying a wallet. Immutable account/asset/hold identity is retained
for each active slot.

A fresh Place requires `remaining == qty`, filled/cancelled zero,
`fee_paid == false`, positive qty ≤ max, own limit in band/on tick and
checked `qty*limit >= min_order_notional`. BUY starts with a verified sedi
hold of `qty*limit+1`; SELL starts with its outcome share hold of qty and a
separate sedi hold of 1. Hold owner, asset, market/season association and
remaining amount must match. Core checks supplied facts; only admission
and the commit transaction can establish that the holds really exist.

No fresh Place may masquerade as snapshot restoration by supplying
`fee_paid=true`, a reduced remaining quantity or already-consumed holds.
Restoration is a distinct verified constructor. Order IDs are globally
unique at admission; the core also rejects active-ID duplicates. Durable
terminal-ID/idempotency protection belongs to prompt 05, avoiding an
unbounded in-core history table.

### 2.2 Command behavior and sequencing

| Command | Behavior |
|---|---|
| Place | Revalidate supplied facts; walk opposite levels; fill until remainder zero, no crossing maker remains or self-prevention stops it; rest GTC remainder or cancel IOC remainder |
| Cancel(order, by, reason) | User cancellation requires a trusted caller identity matching the owner; system cancellation is preauthorized by actor. Cancel active remainder and release outstanding holds; no new fee |
| Suspend | OPEN → SUSPENDED; retain orders and holds; Place rejected; Cancel allowed |
| Resume | SUSPENDED → OPEN; registry/time eligibility checked outside core; core has no clock |
| Close | OPEN/SUSPENDED → CLOSED; cancel every resting order in a canonical order and release holds; do not redeem shares or collateral |
| Snapshot | Read book state through a full canonical snapshot view; no order, hold, supply or mode changes |

Unknown/terminal Cancel returns ORDER_NOT_OPEN with no invented release.
Closed books reject every later business command except Snapshot. Invalid
Suspend/Resume edges return INVALID_TRANSITION. A Close is not suspension:
it empties queues; a later Resume cannot reopen it. Close does not require
or assume Redis delivery.

**Sequencing interpretation for review:** every well-formed ordered command,
including business rejections and Snapshot, has `seq == last_seq+1` and
advances sequence/rolling hash after commit. "Snapshot: no change" means no
economic/book mutation, not unchanged protocol metadata. This preserves the
prompt's universal sequence assertion. Snapshot returns the full hash of
the resulting state. A separate read-only `snapshot_view(state)` helper,
without an ordered command, can hash without consuming a sequence.

Wrong/gapped/duplicate sequence is a protocol failure outside the committed
command stream; it must not advance `last_seq`. A retry of an already
committed command is answered from the actor's durable command record,
not planned a second time. Sequence overflow halts safely. Rejected Place
with verified admission holds includes deterministic release cleanup;
malformed/untrusted hold facts cannot generate journal movement and require
actor reconciliation rather than fabricated refunds.

Core failures are pure typed values; transport code registration belongs
to exchange/server when prompt 05 adds endpoints. Distinguish business
codes such as MARKET_SUSPENDED, MARKET_CLOSED, ORDER_NOT_OPEN and invalid
order fields from protocol/invariant/capacity failures. An invalid price
does not get misreported as insufficient funds, and NEED_CAPACITY does not
consume a command sequence. Rejected Place can emit terminal CANCELLED
cleanup for its verified holds while the command result remains Rejected;
the admission/HTTP projection must preserve the rejection reason.

### 2.3 Plan without mutation, then apply decided deltas

Logical interfaces, not unverified slang syntax:

```text
plan(state, command, separate_workspace) -> Transition or protocol failure
apply(state, transition) -> success or precondition failure
replay(snapshot, transitions) -> restored state or verification failure
verify(state) -> invariant result
top_levels(state, n, output_buffer) -> Yes bid/ask levels
depth_at(state, side, yes_price) -> aggregate remaining quantity
```

The workspace argument makes ownership/preallocation explicit; `plan(state,
cmd)` in the prompt is the semantic shorthand. Exactly one transition per
book can await commit. Planning peeks at free slots and existing queues;
it cannot pop the live free list, change a best pointer, reserve an index
bucket, adjust a quantity or lazily update a live hash/cache. Workspace
records used quantities, projected holds/fee flags and changed levels.

Before returning Accepted, validate the entire candidate's arithmetic,
capacity, hold budgets, supply and posting balance. Internal failure drops
the complete tentative economic plan. GTC remainder is staged in the
transition, not inserted during planning. Snapshot planning hashes an
overlay/view rather than applying and undoing changes.

The transition binds base sequence, previous rolling hash, policy identity
and schema version. Before any apply write, validate those preconditions,
all slot generations and required capacities. `apply` performs no matching,
economic recomputation, clock lookup or allocation; it installs already
decided values and relinks queues. The same transition cannot be applied
twice. Fail all preconditions before touching state. If a committed
transition cannot be applied because of a process/runtime fault, discard
the instance and recover from durable state; do not re-plan a different
trade for that committed sequence.

After failed DB commit, discard the transition and its workspace. After
successful commit, apply before reusing either workspace or freed handles.
An uncommitted plan can be repeated and must produce the same canonical
bytes and leave live state byte-identical. `apply` changes actor-owned
state only; no subscriber may share mutable buffers with that state.

### 2.4 Transition fields and canonical order

The transition includes the prompt's sequence/command reference/result,
fills, order updates, resting remainder, postings, supply/collateral deltas,
book deltas, public trades, optional last price and rolling `state_hash`.
Add base metadata, mode change, cumulative quantities/hold deltas,
prevalidated queue/index operations and optional `full_state_hash` for
Snapshot. Precomputed structural operations are internal; public and
persistent canonical records use UUIDs, never process-specific slots.

| Collection | Deterministic ordering |
|---|---|
| Fills/trades | Actual matching visitation; fill_index starts at 0 and increases by one |
| Order updates | Makers in first-touch fill order, then incoming; coalesce repeated changes to one final update per order |
| Close cancellations | Bid prices ascending then ask prices ascending, FIFO within each level; no map iteration |
| Postings | Fill principal/share postings in fill order; then first-fill fees by first-touch order (maker then taker); then aggregated releases by that same order; Close uses its cancellation order |
| Book deltas | Bid before ask, price ascending within side; exactly one final new_level_qty per changed level, including zero for removed levels |
| Resting snapshot | Bids ascending then asks ascending, queues in accepted_seq/UUID order |

Terminal updates use remaining=0 and explicit cumulative filled/cancelled
counts, so `qty=filled+remaining+cancelled` holds. PARTIAL means positive
remaining and positive cumulative filled; an IOC or self-prevented remainder
ends CANCELLED even if part already filled. `fee_charged_now` records this
command's event, while persistent `fee_paid` remains true thereafter.
The database adapter must preserve these semantics when projecting the
existing orders table; the baseline table lacks several of these fields.

### 2.5 Exact postings and hold operations

Notation: `A.free(asset)` and `A.held(asset,hold)` denote ledger buckets;
all equations below are integer quantities. Every listed held debit has a
matching `consume` HoldOp. Release is a separate balanced posting with a
`release` HoldOp. No zero entries/zero HoldOps are emitted.

For quantity k, let `Y=YES:<market>`, `N=NO:<market>`, `C=system:collateral:<market>`,
`S=system:shares:<market>`, `T=system:fees` and `cash=SEDI`.

| Mode | Entries in one fill posting |
|---|---|
| TRANSFER_YES | YES buyer held cash −xk; YES seller free cash +xk; YES seller held Y −k; YES buyer free Y +k |
| TRANSFER_NO | NO buyer held cash −(V−x)k; NO seller free cash +(V−x)k; NO seller held N −k; NO buyer free N +k |
| MINT | YES buyer held cash −xk; NO buyer held cash −(V−x)k; C free cash +Vk; S free Y −k; YES buyer free Y +k; S free N −k; NO buyer free N +k |
| MERGE | YES seller held Y −k; NO seller held N −k; S free Y +k; S free N +k; C free cash −Vk; YES seller free cash +xk; NO seller free cash +(V−x)k |

Transfers use ledger kind FILL, mint MINT and merge MERGE. `system:shares`
is the balanced share-issuance offset, not another user's inventory; its
negative balance after issuance is deliberate. Fees are distinct FEE
postings: first-filling order held cash −1, T free cash +1, consume 1 from
that order's sedi hold. The maker and taker each owe their own first-fill
fee; already-paid orders owe none. This flag is updated in scratch so an
incoming order spanning many makers is charged once.

For an incoming buyer with own limit L and own execution e, release
`(L−e)*k` improvement. Maker buyers have e=L, hence no improvement release.
Seller improvement is higher credited proceeds, not release of imaginary
cash principal. A seller's sedi hold is only its fee budget.

Aggregate all improvement and terminal releases per affected order into
one ORDER_RELEASE transaction for that command; it may contain separate
sedi and share release pairs, one HoldOp per distinct hold ID. Its entries
are held asset −r / own free asset +r. Do not give multiple postings the
same release business key or combine consume/release of the same hold in
one posting in a way that breaks the ledger's held-entry validation.

Business keys are exactly:

```text
fill:<market_uuid>:<command_seq>:<fill_index>
fee:<order_uuid>
release:<order_uuid>:<command_seq>
```

Set season/market IDs, valid kind, ref_type/ref_id and deterministic JSON
metadata in every description; the empty object is sufficient metadata.
Account owner kind is supplied, not assumed to be user. The prompt 05
adapter materializes these descriptions and invokes `post_many` **once**
for the whole command, inside the same transaction as order/fill/sequence
and outbox persistence. It must not loop over `consume`/`release` wrappers,
because each wrapper invokes `post` and a second call is refused.

### 2.6 Hold budgets and quantity conservation

For an active BUY of own limit L and remaining R, its outstanding cash
after all decided effects must be `R*L + (fee_paid ? 0 : 1)`. For an active
SELL, outstanding shares must equal R and cash must equal its unpaid fee.
Every end state has zero outstanding holds. Price improvement release
maintains the BUY formula even when the incoming GTC rests after some fills.

For each hold:

```text
original_held = consumed + released + outstanding
```

For each order: `qty = filled + remaining + cancelled`, with nonnegative
components and remaining never increasing. Track these counters only for
active records; transition history/audit in prompt 05 and the test harness
retain terminal evidence. Reusing an active slot cannot erase an output
needed by an uncommitted transition.

Mint changes issued pairs and each outcome supply by +k, collateral by
+V*k. Merge changes them by −k and −V*k, refusing insufficient backed
supply. Transfer/fees/releases change none of those counters. Test harness
shadow wallets establish that supplied shares/holds and core counters agree
with the ledger; the core cannot prove external inventory ownership by
examining order IDs alone.

## 3. Data structures, ownership and allocation plan

### 3.1 Fixed price domain and intrusive queues

Use two indexed vectors of `V+1` plain level records, one per side. They
are logically fixed after constructor setup: unused prices/ticks are empty.
Each level stores head slot, tail slot and checked total remaining quantity.
The price is its array index, not a tree key. Maintain best bid/max and best
ask/min with explicit empty sentinels outside the legal band.

Each active order occupies one preallocated plain slot with prev/next
integer links, normalized side/price, immutable order/hold metadata and
current counters. An intrusive doubly linked queue permits O(1) unlink
once its slot is found. A ring per level would require shifting or separate
holes for arbitrary cancellation, so it is not selected. A deterministic
free-slot stack and slot generation prevent stale handles after recycling.

An incoming command walks monotonically across opposing prices. When apply
empties a best level, scan toward the next nonempty legal tick; do not scan
the whole order pool. Worst price scanning is bounded by 1,001 entries.
Maintain totals incrementally and verify them from queues in debug/tests.

| Operation | Intended cost, excluding output serialization/hash bytes |
|---|---|
| Rest a validated GTC | Expected O(1) index insert and O(1) queue append |
| Cancel | Expected O(1) lookup/unlink, plus at most O(V/tick) best-pointer scan |
| Match | O(makers visited + price indices crossed + emitted records) |
| Close | O(active orders + price indices + emitted records) |
| top_levels(n) | O(V/tick) bounded scan, stop after n nonempty levels per side |
| Full snapshot/verify | O(V + active orders), with identity/queue cross-checks |

### 3.2 UUID index and handles

Slang's built-in map preserves insertion order and its deletion is linear
in map size in the inspected docs. It therefore does not satisfy the
desired cancel-storm cost. Use a market-local open-addressed UUID → slot
index over preallocated scalar arrays, capped below a chosen load factor
(proposed 0.5), with backward-shift deletion; do not retain ordered-map
semantics. Probe collisions compare full canonical UUIDs, never hashes alone.

Admission parses UUIDs once and supplies immutable canonical bytes plus
display string. Use a deterministic bounded hash over those bytes, e.g.
reduce `h*257+byte` modulo index capacity at each step, with capacity capped
so that the intermediate cannot exceed signed 64-bit range. No wrapping
arithmetic or hidden random salt is needed. Index order is never output.
Lookup/delete is expected O(1), not a worst-case guarantee; benchmark probe
lengths and adversarial collisions. Rebuild/grow the index on the slow path.

The actor may cache a `(slot,generation)` handle, but durable commands and
snapshots use UUIDs. The core validates any hinted handle against the UUID
and generation. Slot selection/free-list order may change after recovery;
it must not change semantic transitions, priority, canonical bytes or hashes.

### 3.3 Workspace, bounds and transition lifetime

Allocate slot/index/level storage and workspaces before processing a book.
Pre-size output to conservative bounds derived from current active order
capacity N: at most N fills on one Place, N+1 affected orders/fee/release
slots and one change per touched price/side. Reserve separate bounded
storage for principal entries, HoldOps, public trades and canonical bytes.
Close requires capacity for every active order's release, not max_order_qty.
Checked sizing covers byte lengths of UUIDs, numbers and metadata.

Insufficient workspace returns NEED_CAPACITY without a command result or
live-state mutation. Grow only outside plan/apply, then retry the same
command. This is infrastructure backpressure, not an economic rejection.
Resource limits for number of active orders and output size are supplied
by the actor/configuration, not inferred from the share quantity limit.
Do not permit an unbounded allocation just because Close must cancel all.

Workspace scratch records quantities/hold use by slot and a touched-slot
list; no mutation to live state is used to mark visitation. Scratch resets
only after apply/discard and after no consumer can reference output. The
transition view is caller-owned and stable across the DB wait; durable
serialization copies or writes it before reuse. References into a freed
arena or reused slot are forbidden. Each concurrently driven independent
book has its own workspace.

### 3.4 What slang actually provides

Local sources were inspected without inventing language APIs:

| Capability | Evidence and consequence |
|---|---|
| Indexed `[T]`, plain value structs, list assignment | `../slang/docs/guide/data.md`: prefill vectors during setup and update by index; do not assume an undocumented `[T; N]` fixed-array syntax or reserve builtin |
| Shallow copying of list/map fields | Same document: copying a State struct is not a deep copy and cannot make plan safe; keep independent workspace and immutable metadata |
| Insertion-ordered maps, linear-time del | Same document: use only point lookup if used at all; custom cancel index avoids ordered deletion and no map traversal supplies output |
| Arenas | `../slang/src/codegen/expr.c` and `../slang/runtime/sl_core.c`: arena_new, alloc/alloc_bytes, wire, reset and left exist in the sibling source; allocation panics beyond capacity, so size first and probe installed compiler support before use |
| Heap behavior | `../slang/docs/limitations/index.md`: string concatenation allocates; `gc struct` is a heap object; plain records avoid one object per element |
| SHA-256 | `../slang/runtime/sl_crypto.c`: crypto.sha256 returns newly allocated bytes; it is not an allocation-free into-buffer API |
| Allocation statistics | `../slang/runtime/sl_gc.c`: SLANG_GC_STAT emits process allocation counts/bytes and GC pauses; no public proc allocation-counter API was found |
| Inline functions | No source-level inline annotation is assumed; inspect emitted C/compiler flags and measure instead of inventing one |
| Spawn/join | `docs/auth/slang-notes.md`: use only in independent-book test/benchmark workers, explicit top-level functions and checked join results |

Sibling source describes available mechanisms, not proof that the installed
0.2.3 binary supports every current source feature. Tiny capability probes
and emitted-C inspection are required during implementation before choosing
an arena representation. This design does not require a compiler change
or native C matching implementation as an unannounced dependency.

### 3.5 Zero-allocation contract and representation decision

Simply preallocating the order pool is insufficient: concatenated business
keys, builder output, crypto.sha256 results and the ledger's gc structs all
allocate. Calling those constructors in ordinary plan/apply would violate
the prompt. The proposed no-allocation path is:

1. Preallocated plain transition/posting/entry/HoldOp records and byte
   buffers with explicit used counts; no push/growth/slicing that copies
   on the timed path.
2. Fully specified ledger descriptions represented as views over these
   buffers. Each required field, including exact business-key bytes, is
   decided by the core. A pure bridge later materializes existing ledger
   GC DTOs without making any pricing or allocation-of-funds decisions.
3. Encode canonical bytes directly into provided storage. Compute SHA-256
   into provided digest storage using a pure, tested implementation if no
   verified into-buffer primitive exists. SHA's specified 32-bit modular
   operations must be explicit masks/bit operations with bounded wider
   intermediate sums; never rely on slang signed integer overflow.
4. Persisting/materializing a transition can allocate outside plan/apply;
   report those allocations separately as well as in an end-to-end row.
   Do not advertise the whole exchange/ledger path as zero allocation.

**Review gate:** this is a logical LedgerTx-compatible description, not an
already allocated `ledger.domain.LedgerTx` object. Approval is needed for
that representation interpretation. If exact current GC DTO objects must
be returned directly, zero allocation cannot be promised with the inspected
constructors; the design must change explicitly. No stock `sha256_into`,
list reserve API or mutable-string API is assumed. Custom SHA-256 needs
known-answer/differential tests before it is trusted.

The oracle may allocate freely. An allocating correctness prototype, if
used, must be clearly labeled and cannot satisfy the final no-allocation
performance requirement. Measure actual command-loop allocations including
hashing; a decision-only microbenchmark is an additional metric, not a
substitute for complete `plan+apply`.

## 4. Invariants, canonical hashes and replay

### 4.1 verify(state) and transition checks

Run after every step in differential tests and in explicit debug builds:

1. Empty-side sentinels are valid; otherwise best bid < best ask and both
   pointers identify the actual best nonempty levels. Suspended books also
   remain uncrossed because placements are refused.
2. Every active slot appears exactly once in one matching side/price queue;
   remaining >0; prev/next/head/tail agree; free slots are disjoint; UUID
   index points to exactly the same active records and generation.
3. Every level total equals a checked sum of its order quantities; total
   additions, supply, collateral and sequence increments cannot overflow.
4. Per order, qty=filled+remaining+cancelled. Compare prior state/transition
   to prove remaining never increases, including partial and terminal paths.
5. Matching visits prices in the taker's best direction and FIFO at each
   level. No later eligible same-level maker skips an earlier one.
6. Maker own execution equals its limit; buyer execution ≤ own limit and
   seller execution ≥ own limit; x and V−x are legal band/tick prices.
7. YES supply=NO supply=issued pairs ≥0 and collateral=V*issued pairs ≥0.
   Verify aggregate counters against shadow share/currency postings in tests.
8. Each LedgerTx independently balances to zero per asset, has valid
   owners/buckets/hold identities and unique deterministic business key.
9. First fill changes fee_paid false→true exactly once; one matching fee
   posting exists; never-filled orders have none. Historical fee-once proof
   uses transition history, not just active slots after terminal recycling.
10. Every consumed/released hold amount is nonnegative and covered by an
    original verified budget. Ended orders leave zero; active orders obey
    §2.6. No same hold is spent twice across fills within one transition.
11. No fill joins equal accounts or related effective owner groups.
12. Identical semantic input yields identical canonical transitions and
    hashes, even with different slot layouts/index capacities. No float,
    wall time, randomness, pointer address, unused scratch bytes or map
    iteration order enters output.

The local state verifier cannot inspect past fills or real wallets. The
transition verifier and independent harness check temporal/accounting
properties with full history; prompt 05 checks actual database ownership
and solvency. Calling verify does not prove those external facts.

### 4.2 Canonical encoding and hashes

Specify a versioned binary encoding shared as a protocol, not shared oracle
matching code: explicit tags, length-prefixed UTF-8 strings, canonical UUID
bytes, fixed byte order and signed integer width, explicit optional-value
tags and deterministic array ordering from §2.4. Use only populated buffer
prefixes; never hash struct padding, transient slots or unused capacity.

The genesis rolling hash commits schema version, market/season identity,
policy economics/terms identity and initial logical state, excluding the
not-yet-defined hash fields themselves. Per ordered command:

```text
rolling_hash_next = SHA256(rolling_hash_previous || canonical_transition)
```

Canonical transition covers result/reason, economic effects, order/mode
updates, public deltas and next sequence; excludes its own state_hash,
optional full_state_hash and process-local relink/index instructions. Include
all state-changing logical facts so an omitted fee flag/hold change cannot
escape the chain. The rolling hash measures history; it is not the full
book hash and must not be described as one.

The full hash is SHA-256 of canonical complete logical state: versioned
policy, mode, last_seq, rolling hash, last price, supply/collateral and
ordered active orders including current fee/hold counters. Redundant level
totals may be included only after verifier agreement. Exclude the stored
full hash itself. For ordered Snapshot, first compute its next rolling
hash, then compute the full state hash against projected metadata; excluding
full_state_hash from transition encoding avoids a recursive hash definition.

A durable snapshot stores full state, covered sequence, rolling hash and
full-state checksum. Validate it before restoration, rebuild queues/index
from UUID/order facts and replay only strictly contiguous decided tails.
For each transition, verify base and resulting rolling hashes and all
preconditions; never match historical commands again to recover their
effects. Verify final full state against an uninterrupted run. Corruption,
gaps or unsupported schema fail recovery explicitly.

## 5. Independent verification plan

### Oracle and differential protocol

After review, write the Python oracle first as a deliberately slow flat
list scan/sort. It uses its own matching/accounting code, no price-array or
intrusive-index structures, and integer arithmetic with explicit signed
64-bit bounds despite Python's unbounded integers. Cases exchange canonical
commands/transitions over a versioned harness protocol; parsing and I/O
remain outside the slang core. Validate posted entries, not just fill
prices or a checksum. Do not obtain expected outputs by calling slang.

Compare after every command: result, exact ordered fills, order states,
remaining/filled/cancelled counts, fees, principal and release postings,
hold budgets, supplies, collateral, book deltas/trades and hashes. Include
negative cases, invariant injection, overflow, cancelled/unknown IDs,
already-paid maker fees, all own-term directions, user/bot owners and linked
accounts. SHA-256 implementation tests compare standard vectors and
independent implementations separately from matching tests.

Fuzz fixed seeds and persist the first failing sequence with schema,
policy, initial inventory/holds and versions. Shrink only while preserving
the failing behavior. Cases reach 10,000 commands each across V=10/50/100/200,
20 accounts, GTC/IOC, cancels, suspend/resume and close. Ensure useful
pre-close traffic; a run of mostly rejected commands after Close cannot
stand in for matching coverage. Record actual counts by mode/action.
Run independent books through bounded spawned workers; each owns its
state/workspace. Check every join/panic and deterministically order failure
reports. No core concurrency is introduced.

### Exhaustive gate feasibility

The literal Place alphabet alone contains
`4 order types * 9 prices * 3 quantities * 2 TIFs * 3 accounts = 648`
symbols before cancel choices. Exactly four placements give
**176,319,369,216 sequences**; lengths zero through four give
176,591,887,561. Some symbols violate minimum notional and should be
exercised as rejections, not silently pruned from the requested space.

**Review decision required:** retain a resumable, deterministically sharded
full enumerator with coverage manifests, but use a separately named reduced
exhaustive alphabet for routine CI plus complete pairwise price/type/qty/TIF
coverage and long differential fuzzing. The reduced alphabet should cover
cross/equal/noncross price relations, both accounts and linked ownership,
both TIFs, quantities 1/2/3, cancellation positions and all four modes.
The full four-command request remains an unmet release gate until its
manifest completes or its scope is explicitly revised at review. Do not
call a sampled, reduced or symmetry-pruned run literal full enumeration
without a proof of the pruning equivalence and published coverage counts.

### CI, replay and immutability

Add deterministic unit/golden tests to normal package tests. Add dedicated
CI oracle/differential checks, a reproducible 1M-command budget, and a
scheduled 100M nightly with retained failure artifacts after review. No
existing `.github` workflow was found in this workspace, so CI wiring is
new work, not an already functioning gate. Runtime/build failures must fail
or explicitly mark a run blocked rather than counting it as passing fuzz.

For every prefix k, or a documented deterministic selection for long runs,
snapshot/replay tails and compare both rolling and full hashes. Plan and
discard commands at every relevant case and compare all live state bytes,
including arrays, free/index metadata, not merely a hash that omits scratch
or cached fields. Run replay with altered slot layouts to catch hidden
handle dependence. Duplicate apply and malformed transitions must fail
before any state change.

## 6. Benchmark contract and honest comparison

After correctness gates, benchmark a warm single market on one core:
rest-only Place, Cancel, filling one level, walking ten levels, and 10,000
resting orders followed by a cancel storm. Separately run 1,000 independent
markets with spawned tasks and compare worker/core scaling. One active
market remains single-threaded; the harness times outside the core.

Report commands/s, p50/p99/p999 for complete plan+apply including canonical
encoding/hashing, plus allocations/command, bytes/command and memory per
resting order. Publish fixture sizes, fill count per operation, repetitions,
warmup, capacity/preallocation, GC behavior and raw samples/histograms.
Measure setup/growth/Close separately; do not hide them or include setup
cost in only one language's results. A separate bridge-inclusive row shows
LedgerTx materialization cost. No database latency belongs in these core
numbers; prompt 05 will measure that separately.

Allocation measurement uses supported runtime diagnostics/profiling outside
the core. SLANG_GC_STAT is process-wide: isolate the benchmark, report setup
and empty-harness baselines, use command-count scaling to distinguish fixed
cost from per-command growth, and account for native/arena allocations
separately. Do not divide total process allocations by commands and claim
that is an exact per-command count, or call non-GC allocations free.
If an exact scoped counter is unavailable, state the method's limits.

**Scenario conflict:** one incoming BUY YES can transfer YES or mint;
SELL YES can transfer YES or merge; BUY NO can transfer NO or mint;
SELL NO can transfer NO or merge. One command cannot exercise transfer,
mint and merge together. Use separate ten-level mixed transfer/mint and
transfer/merge cases, report both, and optionally a sequence combining them.

Implement `bench/go-ref/` independently from the oracle and slang code,
following this same contract, including fees/holds, output and hash work.
Use identical scenario traces, correctness checks and allocation policy;
do not compare a minimal Go matcher against a full slang planner or omit
hashing from one language. Publish side-by-side results in BENCH.md with
hardware, OS, compiler versions/commits, actual flags, CPU/worker affinity,
GOMAXPROCS, GC settings and disadvantages. No baseline Go or slang numbers
are available from this design stage.

## 7. Review decisions and prompt 05 handoff

| Decision | Proposed resolution |
|---|---|
| D1: Paths and dependency state | Use src/exchange/domain under AGENTS.md; registry is still a proposed dependency, so introduce no fake live MarketPolicy service |
| D2: Fee release | A filled order retains its paid fee; only never-consumed fee budget can be released |
| D3: Sequence/Snapshot | All ordered commands advance protocol metadata, Snapshot changes no book/economic state; read-only snapshot helper does not consume seq |
| D4: Journal integration | Pure complete journal descriptions, one ledger-service conversion and one post_many per commit transaction; no repeated post wrappers |
| D5: No-allocation representation | Preallocated plain records/byte views and into-buffer hashing, with GC DTO materialization outside the core; validate compiler capabilities and measure all costs |
| D6: Exhaustive coverage | Full resumable enumerator retained as a distinct gate; review feasibility before treating reduced CI coverage as acceptance |
| D7: Benchmark modes | Split ten-level transfer/mint and transfer/merge cases; do not claim one incoming command exercises three modes |
| D8: Self-trade and rejected input | Same account always linked; no skipping own maker; preserve earlier legitimate fills; verified admission holds get explicit rejection cleanup |
| D9: Lifecycle scope | Core mirrors Suspend/Resume/Close, with clock/roles/market authority supplied by actor; no settlement, payout or funding execution |

Older specification candidate-ranking/four-book prose is superseded by the
single Yes-book rules. The older out-of-band "cancel affected execution"
wording is superseded by whole-command internal rejection. Preserve the
maker-price/taker-improvement, fee-once, per-asset ledger and no-self-fill
requirements. Hash chain and full-state hash are deliberately distinct.

Prompt 05 must supply:

- Admission: actual policy, account status/owner kind/effective group,
  verified holds, canonical order UUIDs, bounded capacity and sequence.
  Re-check market status/deadline/season/terms/ownership epoch inside commit;
  a clockless core cannot enforce deadline eligibility itself.
- Market buys: proposed rule is a configurable number of legal ticks above
  the best own-outcome ask, capped at max_price; reject if no ask exists.
  Compute qty as floor((spend_cap−unpaid_fee)/protection_price), cap by
  max_order_qty, require positive/minimum-notional-valid size and reserve
  no more than available spend. Use IOC; do not broaden protection when
  depth moves. Derive NO ask from the mirrored Yes view, not the Yes ask.
  Rounding keeps unspent money free; it never increases the caller's budget.
- Commit: ledger post_many plus orders/fills/command sequence, supply and
  durable outbox in one fenced transaction. Failed commit discards plan;
  successful commit followed by process crash recovers the decided tail.
- Persistence: extend baseline orders for group/hold/fee/accepted-sequence
  and quantity facts as needed, without inventing an accounting side table
  that bypasses ledger. Exact migration belongs to prompt 05.
- Events: publish book_deltas/trades only after commit, maintain bounded
  fanout and restore from validated snapshots plus contiguous transitions.
  No process-local integer handle is a durable order identity.
- Reconciliation: compare core supplies/collateral/hold budgets with actual
  ledger and holdings; enforce group changes and owner-fencing policy.

After review: oracle and generators, pure slang core and bridge,
differential/golden/replay/CI gates, then Go comparison and benchmarks.
Do not claim review, exhaustive completion, zero allocations or speed
improvements until the corresponding evidence exists.

### Design-stage validation

Only MATCHING.md was added for this prompt; the earlier proposed market
design was left unchanged. Whitespace checks passed. `make check` passed
`zokor check` for 18 packages, then failed the existing
`test_should_time_out_a_send_to_an_unreachable_provider` in platform/email:
the sandbox denied its dial with "Operation not permitted", whereas the
test requires a timeout message. Database/Redis integration cases skipped
without their test URLs and load cases skipped without LEDGER_LOAD=1.
A separate `make build` succeeded. These are project baseline checks, not
verification of an implemented matcher, oracle or performance target.
