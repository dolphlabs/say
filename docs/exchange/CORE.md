# Implemented matching core contract

The prompt 04 implementation lives in `src/exchange/domain`. It owns no
connection, task, clock, environment reader, mutex or global mutable state.
`tools/oracle` is the independent flat-list Python reference; `bench/go-ref`
is a separate Go implementation with price arrays, intrusive queues and a
bounded open-addressed order index.

A `Book` and its `Workspace` are plain owning values. Create them with
`new_book(policy, slot_capacity, backed_pairs)` and
`new_workspace(&book, transition_capacity)`. The constructor validates
policy, checked backing and capacities. Slot capacity is bounded at100,000.
All fees are one sedi; the minimum original notional is two. An initial
nonzero pair count represents validated pre-existing collateral/inventory,
not authority to mint unbacked wallets. Runtime restoration must reconcile
it against durable ledger and supply facts.

`plan(&book, command, &mut workspace)` returns an empty string on success
and sets `workspace.ready`; another static string is an error. Successful
plans describe both accepted commands and ordered business rejections such
as a suspended market, with verified incoming holds released. Invalid
sequence, identifiers, economics, hold facts or an internal failure produce
no applicable transition. A failed capacity/invariant plan clears tentative
fills and postings. No live book, queue, slot, index, free-list, generation
or backing value is changed by planning.

`apply(&mut book, &mut workspace)` verifies the base sequence/hash, slot
identities/generations, order/hold arithmetic, backing, output levels,
fill identity/prices/modes, balanced postings and canonical transition hash
before any live mutation. It applies already-decided deltas without
matching again. After success it clears `ready`; repeated application fails.
The caller must first commit all durable economic effects. If commit fails,
discard the workspace or plan over it again. No database commit is implied
by a successful plan or apply in these pure APIs.

An order carries complete original/consumed/released hold budgets and
filled/cancelled quantities. Admission supplies verified holds, stable
user/bot owner kind and effective beneficial-owner group. The core cannot
prove wallet ownership without that admission boundary. Active SELL
reservations per outcome cannot exceed issued pairs. Fresh order sequence
must equal the command sequence, making normal tail insertion FIFO.

`NEED_CAPACITY` is a slow-path retry. Increase the output workspace and
retry against the unchanged book. If the slot pool is full and no maker is
retired by the candidate, call `grow(&book, larger_capacity)` and create a
workspace for the replacement. Growth snapshots and restores logical state;
it allocates. A full pool can reuse a maker slot retired by the same planned
command without growth. Never replace the live book while a durable commit
for its old prepared transition is unresolved.

`record(&book, &mut workspace)` in exchange/service materializes owned
journal/event DTOs outside the hot path. Its `decision` field represents
the contract's `result`; the Python comparison explicitly maps that one
wire field. Every economic field, posting, trade, level and order update
participates in the canonical hash. Metadata is the fixed empty JSON
object. Ledger integration must map these descriptions through the ledger
service/store API and post the complete ordered set in one transaction.

`prepare_replay` reconstructs scratch instructions from a durable decided
record, resolves order identities to the restored slots, verifies its hash
and projected optional snapshot hash, and checks the re-materialized full
record. It does not rematch. Apply it only after all checks pass.

`snapshot(&book)` exports logical orders in bid-price ascending/FIFO then
ask-price ascending/FIFO order. `restore` sorts by that explicit priority,
validates all orders/queues/backing and rebuilds the physical index and
free-list. Slot positions and generations are process-local. Durable
snapshot envelopes must also store and verify the full-state checksum;
loading a syntactically valid rolling hash alone proves no historical
journal chain.

`full_hash(&book, projected, &mut workspace)` writes a digest at offset64
in the workspace hash buffer. The book chain is at offset0 and the next
planned chain at32. Ordered Snapshot advances metadata and the rolling
chain, but has no economic effect. Its projected full-state hash is excluded
from the transition encoding to avoid recursion. Genesis commits the policy
and initial checked pair/collateral state; it is not an all-zero hash.

Canonical fields use UTF-8 byte lengths and decimal integer payloads:
`<length>:<payload>`. Booleans are `1:0` or `1:1`. Transition hashing prepends
the previous32 raw digest bytes. Full-state hashing uses its version tag,
policy, mode/sequence/rolling hash, backing, optional last price and canonical
active orders. No struct padding, hash-table iteration, capacities or
transient relinking instructions enter either hash.

`depth_at` and `top_levels` expose the single Yes-price book; the latter
fills a caller-owned `depth_buffer`. The No view is derived by clients.
`verify` additionally checks queue reachability, FIFO, free-list uniqueness,
index mappings, quantities, exact hold budgets, noncrossing best prices and
supply. It leaves a pending plan usable. Workspace shape checks reject
buffers created for incompatible slot or price dimensions.

Snapshot/export/restore/growth, JSON conversion and durable-record replay
may allocate. Ordinary pre-sized plan/apply, depth reads and hashing use
fixed buffers and preallocated plain records. BENCH.md records actual
instrumented allocation and latency results and their limits.

Runtime admission/commit gates may reject an already-admitted Place while
the local book is still OPEN. The internal `RejectPlace` resolved command
carries the original verified order and a bounded authoritative reason:
MARKET_NOT_OPEN, MARKET_SUSPENDED, MARKET_CLOSED, TRADING_HALTED,
SEASON_NOT_ACTIVE, MARKET_DEGRADED or ACCOUNT_DISABLED. It releases every
unused incoming hold, charges no fee, advances the ordered hash/sequence,
and leaves all makers, supply and mode unchanged. Invalid reasons cannot
create an applicable transition. This resolves runtime design R4 without
hand-editing transitions or temporarily mutating live market mode. It must
never be exposed as a caller-chosen HTTP order type.
