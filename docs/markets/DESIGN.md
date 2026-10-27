# Market registry and admin market lifecycle

Status: **implementation in progress**. Design date: 2026-10-26.

The user authorized implementation of prompts 03–10 on 2026-10-27. The
registry, migrations, routes and workers now exist. This remains the PRD and
technical contract; API.md, PERFORMANCE.md and ../IMPLEMENTATION.md track
actual implementation, measurements and remaining integration work.

## 0. Product requirements and current project

### Goal and boundary

The registry defines a binary market's question, resolution terms and
economics; controls submission, independent approval, opening, suspension
and closing; and supplies public market cards and details. PostgreSQL is
authoritative. Redis is an optional delivery accelerator, never authority
for permissions, approval, time boundaries or trading eligibility.

| User | Required outcome |
|---|---|
| Public visitor | Browse categories, featured and filtered markets; search; see truthful prices, rules, source, closing time and status |
| Creator | Save incomplete drafts, validate the live form, submit and inspect only their own markets |
| Curator | Review submissions, give reasons for changes/rejection, approve another author's submission, suspend/resume trading |
| Super admin | Curator capabilities plus reasoned clarification of an open market without changing economics |
| Exchange | Read a UI-independent policy and a fast trading-state hint, with authoritative checks at commit |
| Operator | Recover overdue closes after restart and measure closure delay, cache freshness and read latency |

The module does not match orders, cancel exchange orders, move sedis, fund
bots, decide outcomes or settle positions. Those effects belong to prompts
05, 09 and 08. Emitting an event records work for those consumers; it does
not establish that those later effects have occurred. No frontend is
included in this backend prompt.

### Repository evidence

Inspected sources, rather than the illustrative schema, determine the
integration points:

| Existing source | Confirmed behavior and implication |
|---|---|
| `migrations/001_initial_schema.sql` | `markets` exists with `statement`, `cutoff_at`, `resolution_at`, economics and exchange sequence fields; no registry feature exists |
| `migrations/004_ledger.sql` | Roles are only `admin`/`super_admin`; issuance uses `issuance_policy_approvals`; runtime `say_app` has broad default table privileges with explicit journal restrictions |
| `src/ledger/store/grants.sl` | Two distinct operators approve issuance; the proposer can currently be one; adapter and CLI read the specialized approval table |
| `src/ledger/store/postgres.sl`, `src/ledger/service/jobs.sl` | Session advisory locks use a held connection, close it on error, and coordinate season work; existing lock keys are 7310001–7310004 |
| `src/platform/db/db.sl`, `src/platform/app/app.sl` | Shared outbox publishes at least once to Redis `say:events`; bounded ledger kicks supplement a five-second poll; there is no event consumer yet |
| `src/ledger/service/ports.sl` | `open_seasons` store port already supplies season data to ledger jobs; add a public ledger-service projection for the picker |
| `src/platform/auth/auth.sl`, `src/accounts/service/login.sl` | Session guard exists; role grants currently validate only the two operator roles |
| `src/platform/web/web.sl` | Shared error renderer currently emits `fields: [{field, reason}]`; it cannot yet express a distinct code per validation field |
| `src/main.sl`, `src/platform/app/app.sl` | Startup mounts accounts and ledger; platform/app owns wiring and starts long-lived workers |

Architecture remains `src/markets/{domain,service,store,server}`. Domain and
service perform no I/O. Store adapters implement service ports; HTTP DTOs
and registered error codes belong in server. `platform/app` supplies stores,
clock, configuration, account-role and ledger-season service dependencies.
Use `zokor add feature markets` and `zokor add route` during implementation.
Only store/platform/db imports pg, and every value is a bound SQL parameter.

### Acceptance requirements

- Every market mutation uses `version` CAS and commits its audit and outbox
  records atomically. Approval races and edit races have exactly one winner.
- Drafts can be incomplete; submission requires complete, approved terms,
  valid season/times and symmetric, tick-aligned integer economics.
- No actor, including a super admin, approves their own submission.
- PostgreSQL prevents economics changing after opening, including after
  suspension, closure and later resolution states.
- Boot catches up overdue markets; healthy deployment closes all 1,000
  markets in the specified five-second burst within one second each.
- Every application instance refreshes public snapshots and trading hints;
  an opened market appears in under two seconds.
- Warm list and detail p99 are each under 5 ms in a reported load profile.
  These are acceptance targets, not measurements made in this design stage.
- Unavailable exchange stats remain JSON null, rather than fabricated
  prices, zero volume or an assumed 50% chance.

## 1. Market model, validation and immutable terms

### 1.1 Tables and migration strategy

Add a forward-only migration after 004; never edit applied migrations.
Retain market UUIDs, foreign keys, `owner_epoch`, `committed_seq` and
`book_seq`. Registry `version` is independent of exchange sequence numbers.

Rename `statement` to `question` and `cutoff_at` to `close_at`. Keep
`resolution_at` as the future actual-resolution timestamp; add `resolve_by`
for the deadline, which is a different fact. Update fixtures and any raw SQL
references together. A database preflight must inspect existing rows before
adding constraints. Do not repeat migration 004's destructive reset: if
legacy markets lack required provenance or violate the new bands, stop
with a remediation report rather than invent terms, authors or approvals.

| Table | Proposed columns and constraints |
|---|---|
| `categories` | UUID `id`; unique `name`; `icon` key; integer `sort_order`; `created_at`. Seeds include Football, Music, Tech, Culture, Weather |
| `resolution_sources` | UUID `id`; `name`; `url_pattern`; `kind`; `approved` default false; `created_by`, `created_at`; approval provenance `approved_by`, `approved_at` |
| `markets` identity | Existing UUID `id`; unique URL-safe `slug`; nullable `question`, `category_id`, `season_id`, `rules`, `resolution_source_id` for incomplete drafts; `created_by` and `created_at` required |
| `markets` scheduling | Nullable `close_at`, `resolve_by`; new `open_at` nullable until submission, then defaults to submission time; existing `resolution_at` retained |
| `markets` economics | Nullable `redemption_units`, `min_price`, `max_price` until supplied; `tick` defaults 1; `max_order_qty` defaults 10,000; `fee_units` fixed 1; `min_order_notional` fixed 2; optional positive `liquidity_request` |
| `markets` lifecycle | `status`; `version` bigint initially 1; `terms_version` bigint initially 0; nullable `terms_hash` until first submission; `submitted_by`, `submitted_at`, `approved_by`, `approved_at`, `opened_at`, `closed_at`, `suspended_at`, `suspend_reason`; `updated_at`; nullable positive `featured_rank` |
| `market_terms_versions` | Composite PK `(market_id, terms_version)`; `rules`, `question`, `source_id`, `close_at`, `resolve_by`, `hash`, `created_by`, `created_at`; add `reason`, `source_snapshot`, `policy_snapshot` and `canonical_payload` for reproducible history |
| `approvals` | Shared workflow/decision rows described in §2.4; no second market-only approval table |
| `market_stats` | PK/FK `market_id`; nullable integer `last_price`, `yes_bid`, `yes_ask`, `no_bid`, `no_ask`, `volume_units`, `players`; nullable display `change_24h`; nullable `updated_at`; add nullable `volume_24h_units` for trending |

Foreign keys reference existing accounts, seasons and markets. No tenant
columns or tenant arguments are introduced. Bound values use integer sedis
and whole shares. `change_24h` will mean percentage-point change in implied
chance, with precision defined in prompt 05, not a currency amount.

Generate a lowercase ASCII slug from the question plus an immutable UUID
suffix; an empty draft gets `market-<uuid>`. Refresh it while drafting when
the question changes, then freeze it on first submission so existing links
survive clarifications. Slug uniqueness is a DB constraint, not a prior
availability query.

Incomplete fields can be NULL only in `DRAFT` or `CHANGES_REQUESTED`.
Presence/shape, length, range and band checks are conditional on supplied
values for drafts and mandatory otherwise. `CHANGES_REQUESTED` may carry a
previous submitted snapshot while its working fields are incomplete. Once
submitted, `terms_version >= 1` and its hash/history row must exist. Changes
requested and rejected markets retain that history.

Revoke UPDATE/DELETE/TRUNCATE on terms history and DELETE/TRUNCATE on
markets and approvals from `say_app`; override broad default privileges.
Approval updates are constrained to valid decisions/staling. Audit history
must be append-only for runtime writes; this tightening needs regression
checks against auth's batched audit inserts. Grant only required access to
new tables and preserve all ledger privilege restrictions.

### 1.2 Full validation

One pure validator returns ordered `{code, field, message}` entries. Create
and PATCH use draft mode, allowing missing fields while rejecting malformed
supplied values. Submission and dry-run full mode apply all checks. UUID,
JSON, time and numeric parsing failures are boundary `BAD_REQUEST` errors.
Read-only validation never creates a market, terms version or approval.

| Field | Rule |
|---|---|
| `question` | 10–140 Unicode characters after trimming; one yes/no question identifying event, parties and day. Mechanical checks enforce length and question structure; curator review confirms semantic clarity |
| `rules.yes_if`, `rules.no_if`, `rules.edge_cases` | All required strings, each 20–600 Unicode characters. Curator must confirm postponement/cancellation coverage; do not pretend a keyword match proves adequate rules |
| `category_id` | References a known category |
| `resolution_source_id` | Existing, approved curated source; re-check at submission and approval/opening |
| `season_id` | Season is `SCHEDULED` or `ACTIVE` for submission; `ACTIVE` for opening |
| `close_at` | Strictly before season `ends_at`; also after proposed `open_at` and current submission/opening time |
| `resolve_by` | Inclusive `[close_at + 1 hour, close_at + 48 hours]`; may cross season end while retaining the old season's ledger namespace |
| `open_at` | Default now; may be scheduled but must precede `close_at` and be eligible within the season when actually opened |
| `redemption_units` | Integer 10–1000 |
| `min_price`, `max_price`, `tick` | Every check in §1.3 |
| `max_order_qty` | Positive integer, default 10,000; checked products for configured maximum exposure |
| `fee_units`, `min_order_notional` | Exactly 1 and 2 respectively; clients cannot override the policy |
| `liquidity_request`, `featured_rank` | Null or positive integer; overflow/malformed numbers refused |

Application validation obtains season/source facts through ports. A market
write re-reads those mutable facts within its transaction. Opening takes
`FOR SHARE` on the season before locking the market, consistent with the
ledger's season boundary exclusion. Do not open if season time has expired
even if its scheduler has not yet changed the status.

All timestamps are UTC instants; human error messages use the configured
Africa/Lagos zone. The season-close error uses the actual ordinal/end and
suggests the next eligible season if present, for example:
"That's after Season 01 ends (Mon 26 Oct, 00:00). Pick an earlier close or
move it to Season 02." The equality boundary also fails. Dates in this
example are copy examples, not a hardcoded current-season rule.

### 1.3 Price band checks and display arithmetic

Each is a separate application validation check with a DB equivalent once
all operands exist:

1. `1 <= min_price <= max_price < redemption_units`.
2. `min_price + max_price = redemption_units`.
3. `tick >= 1`.
4. `min_price % tick = 0`.
5. `(max_price - min_price) % tick = 0`.
6. `redemption_units % tick = 0`.

Default missing band endpoints to `1` and `V_m - 1` when a payout is
provided; this default assumes tick 1. An incompatible explicitly supplied
tick is an error, not permission to silently alter the band. Equal endpoints
are allowed if all checks pass. Symmetry and divisibility ensure a legal
Yes price has a legal, tick-aligned complement `V_m - p` for No.

| `V_m` | Default band/tick | Example Yes | Chance | No complement |
|---|---|---|---|---|
| 10 | 1…9 / 1 | 6 | 60% | 4 |
| 50 | 1…49 / 1 | 30 | 60% | 20 |
| 100 | 1…99 / 1 | 60 | 60% | 40 |
| 200 | 1…199 / 1 | 120 | 60% | 80 |

`chance_pct = 100 * last_price / V_m`, computed only for display, returning
null if no last price exists. Preserve fractional display precision rather
than integer-dividing before scaling. Test that S 60 means 60% for V=100
and 30% for V=200; the form example is not a universal S-to-percent rule.
Use the ledger's checked-integer arithmetic through its service contract
or a market-local pure equivalent; never import another feature's domain
directly. Do not clamp an invalid exchange price into the band.

### 1.4 Terms hashes, approvals and post-open locks

Submission increments `terms_version`, freezes a history row and computes
a SHA-256 hex hash over a deterministic, versioned canonical payload.
Use a fixed field order, explicit nulls, integer decimal encoding and UTC
timestamp precision. Do not hash arbitrary JSON serialization order.

The payload includes market ID, question, category, all three rule strings,
source ID and frozen source definition, season, `open_at`, `close_at`,
`resolve_by`, every policy field and `liquidity_request`. Exclude status,
row version, actors, audit timestamps, stats and featured rank. Persist
the canonical payload and economics/source snapshots so historical hashes
remain reproducible after reference-data updates. Any submitted content
change must be resubmitted with a new version/hash and a new approval.

The PostgreSQL BEFORE UPDATE trigger compares old/new values using
`IS DISTINCT FROM` for `redemption_units`, `min_price`, `max_price`, `tick`,
`max_order_qty`, `fee_units`, `min_order_notional`, `season_id` and `close_at`.
It rejects changes if OLD or NEW is a post-APPROVED status, or OLD has
`opened_at` set. The explicit protected set is FUNDING, OPEN, SUSPENDED,
CLOSED, RESOLUTION_PENDING, DISPUTED, RESOLVED, SETTLING, SETTLED and VOIDED.
Status text has no lexical lifecycle ordering. The transition into OPEN
cannot combine a hidden economics change, and resetting a status cannot
unlock a market. Make `opened_at` immutable once set; add a DB transition
guard to forbid regressions into draft/review states.

`max_order_qty` is additionally locked because it is in immutable
`MarketPolicy` and the schema spec requires it. Freezing at FUNDING is
slightly stronger than "once open" and matches "past APPROVED" in the
prompt. Application permissions already prohibit ordinary edits after
REVIEW submission.

Clarification is an OPEN → OPEN mutation available only to super admins.
It accepts only question/rules plus a required reason and expected version.
Full text validation runs, economics remain unchanged, both versions
increment, and new immutable terms history, audit and
`market.terms_clarified` outbox rows commit together. The event includes
old/new terms versions and reason for the later holder-notification
consumer; this stage cannot claim holders were contacted. Source,
`resolve_by`, season and economics cannot change through clarification.

## 2. Lifecycle, authorization and generic approvals

### 2.1 One table-driven state machine

One pure `transition(current, action, actor, facts)` table describes allowed
edges, role/ownership checks and required effects. `authorize(actor,
action, market)` is the single permission decision; public/admin views and
commands use it. The service executes a returned plan synchronously via a
transaction port. There are no detached approval/edit/transition tasks.

| From → To / action | Actor | Guards and effects beyond common CAS/audit/outbox |
|---|---|---|
| Absent → DRAFT / create | creator, curator, super_admin | Draft validation; actor is immutable author; version 1; `market.created` |
| DRAFT or CHANGES_REQUESTED → same / edit | author with create capability | Expected version; draft validation; stale outstanding approvals if payload changed; `market.updated` |
| DRAFT or CHANGES_REQUESTED → REVIEW / submit | author with create capability | Full validation, terms snapshot/hash; pending `market_open` approval; `market.submitted` |
| REVIEW → APPROVED / approve | curator, super_admin | Actor differs from submitter; pending hash equals current hash; update approval and market; `market.approved` |
| REVIEW → CHANGES_REQUESTED / request changes | curator, super_admin | Nonempty reason; pending approval becomes stale; `market.changes_requested` |
| REVIEW → REJECTED / reject | curator, super_admin | Nonempty reason; pending approval becomes rejected; `market.rejected`; terminal |
| APPROVED → FUNDING / prepare | internal system | If requested, create pending liquidity approval; `market.funding` |
| FUNDING → OPEN / open | internal system | `now >= open_at`, `now < close_at`, active unexpired season, still-approved source and valid original open approval; any requested liquidity has a matching approved allocation; set `opened_at` once; `market.opened` |
| OPEN → SUSPENDED / suspend | curator, super_admin | Reason; save suspension time/reason; `market.suspended` |
| SUSPENDED → OPEN / resume | curator, super_admin | Reason; current time before close and season end, active season; clear current suspend note, preserve history; `market.resumed` |
| SUSPENDED → CLOSED / expired resume | curator, super_admin | Reason; deadline or season end reached; close instead of reopening; `market.closed` |
| OPEN or SUSPENDED → CLOSED / close | internal system | Deadline reached or authoritative season closure; set `closed_at`; `market.closed` |
| CLOSED → RESOLUTION_PENDING / handoff | internal system | Durable handoff for prompt 08; `market.resolution_pending` |
| OPEN → OPEN / clarify | super_admin | §1.4; required reason; `market.terms_clarified` |

REVIEW is the origin of changes-requested, per the transition table; the
prompt's drawn branch under APPROVED is ambiguous. DRAFT, CHANGES_REQUESTED
and REJECTED are never publicly listed. Later states are defined now, but
RESOLVED/SETTLING/SETTLED/DISPUTED/VOIDED transitions have no public or admin
mutation path in prompt 03. Every unlisted pair returns INVALID_TRANSITION
or FORBIDDEN_ROLE, with no writes.

No liquidity request means FUNDING does not wait on treasury. Immediate
approval/opening can perform successive state-machine steps in the same
request transaction, each with its own version increment, audit and event;
future open times and scheduled seasons remain in FUNDING. The close
scheduler also drains due APPROVED/FUNDING opening work using a separate
deadline index. At boot it repairs any interrupted pipeline. Requested
liquidity stays blocked until prompt 09 implements its approval/funding
contract; never approve or fund it implicitly. If its opening deadline
becomes impossible, leave it nontradable and expose the reason to operators;
do not create an unlisted lifecycle transition to a resolved state.

CLOSED is committed with its own event before an idempotent handoff pass
advances it to RESOLUTION_PENDING. Handoff retries after a crash; it does
not decide an outcome or erase the CLOSED history.

### 2.2 Permission matrix

Permissions are explicit capabilities, not a numeric role hierarchy. For
multiple roles, use the union, while ownership and self-approval restrictions
still apply. Internal system actor is not a grantable account role.

| Action | creator | curator | treasury | resolver | admin | super_admin |
|---|---|---|---|---|---|---|
| Read published markets | Public | Public | Public | Public | Public | Public |
| Admin list / history | Own only | All | No | No | No | All |
| Create | Yes | Yes | No | No | No | Yes |
| Edit / submit | Own only | Own only | No | No | No | Own only |
| Approve | No | Other submitter | No | No | No | Other submitter |
| Request changes / reject | No | Yes | No | No | No | Yes |
| Suspend / resume | No | Yes | No | No | No | Yes |
| Clarify OPEN terms | No | No | No | No | No | Yes |
| Read curated sources / eligible seasons / validate | Yes | Yes | No | No | No | Yes |
| Add unapproved resolution source | No | Yes | No | No | No | Yes |
| Approve curated source | No | No | No | No | No | Operator process proposed below |
| Issuance-policy decisions | No | No | No | No | Existing capability | Existing capability |

This prompt assigns no market mutation capability to bare `admin`, treasury
or resolver. Preserve their existing unrelated privileges. Extend the DB
role CHECK, accounts service allowlist, CLI usage and tests together.
`require_admin` cannot guard the new routes because it would exclude creators
and curators. Apply `auth.require_session` then load roles through accounts
service and run market authorization. Re-check write authorization against
current database facts in the transaction.

Creator isolation is applied in SQL before fetching list/history rows;
ignore `mine=false` for creator-only actors. Looking up another author's
unpublished market/history yields NOT_FOUND. Out-of-scope mutation returns
no draft content. Never rely on UI filtering or loading all drafts into a
public cache. Anonymous detail/search/featured also enforce publication.

### 2.3 Mutation transaction and CAS

1. Resolve identity, expected version and syntactically valid input. Use a
   consistent lock order: season if needed, then market, then its approval
   rows. If an edit changes season, lock involved season IDs in stable order.
2. Read/lock the market using author scope; verify version before lifecycle
   evaluation, so the loser of concurrent approvals gets STALE_VERSION even
   after the winner progressed past APPROVED.
3. Re-read roles, source and relevant season facts; authorize and evaluate
   the transition plan. Never trust `created_by`/`submitted_by` from a DTO.
4. Execute `UPDATE ... WHERE id=$id AND version=$expected AND status=$from`,
   with `version=version+1`; zero returned rows is STALE_VERSION. A new row
   uses INSERT and starts at version 1.
5. Persist immutable terms, matching approval decisions/staling, audit and
   outbox rows on that connection. Failure of any write rolls everything
   back. System actions use null audit actor plus a system action identity.
6. Commit before invalidating caches or kicking delivery. Cache/metric hints
   are bounded, optional and nonblocking; PostgreSQL carries durable work.

Every edit, clarification, approval decision and lifecycle step has an audit
entry and event with event ID, market ID, from/to status, registry version,
terms version/hash, season and applicable timestamps/reason. Lifecycle
events leave `market_seq`/`book_seq` null; they must not forge exchange
command positions. Consumers use registry version, never event arrival
order, to prevent a delayed OPEN event undoing CLOSED.

### 2.4 Merge issuance into generic approvals

The shared `approvals` table contains the prompt's fields:
`id`, `kind`, `subject_type`, UUID `subject_id`, `payload_hash`,
`requested_by`, `status` (pending/approved/rejected/stale), `decided_by`,
`decided_at`, `reason`. Add `created_at`, `updated_at`, CAS `version` and
`approval_round`/`slot` to represent the existing two-operator issuance
threshold without a second specialized table.

Put reusable approval rules/ports/adapters in an `approvals` feature, also
scaffolded with `zokor add feature`, rather than making the ledger depend on
market UI concepts. It owns approval rows; markets and ledger own their
subject policies and thresholds. Features call its service contract;
their stores may call its store adapter on the same transaction connection,
as the project explicitly permits. No generic approval HTTP mutation route
is introduced here. Each subject's authorized command remains the entry
point and supplies the subject hash, requester and expected version.

- `CHECK (decided_by IS NULL OR decided_by <> requested_by)` applies to
  all decisions. Pending rows have no decider/time; approved/rejected rows
  require both. Stale rows preserve any earlier decision provenance.
- Market opening uses one slot per submitted terms version. Issuance uses
  two slots per policy approval round. A partial unique index prevents two
  approved slots for the same subject/round/decider; a unique slot key
  prevents duplicate pending requests. Request hash and requester remain
  immutable.
- Subject binding is explicit by supported kind/type pair. Market approvals
  reference immutable terms; issuance approvals reference an existing policy
  and a canonical hash of amount/cap. A constraint trigger verifies these
  polymorphic references; arbitrary dangling subject UUIDs are refused.
- The decision transaction locks the subject and pending slot, verifies
  current hash, actor and expected version, then performs approval CAS.
  Subject edits stale pending approvals whose hash differs. Previously
  approved decisions remain historical; effective approval always requires
  the current hash. Request-changes invalidates the old open request even
  before an edit. A rejected row needs a decision, so the same self-decision
  check also applies to rejection.
- Market `CHECK (approved_by IS NULL OR approved_by <> submitted_by)` adds
  defense on the subject row; require a nonnull submitter when approved.
  A constraint trigger verifies the applied approval's subject/hash and
  approver match the market, preventing a mismatched requester bypass.
- Migrate ledger adapter reads/writes, PolicyView projections, CLI flow and
  tests to this table; retain the two-distinct-operator threshold and policy
  replacement/grant-retry transaction. Add policy `version` for its CAS.
  Audit/outbox accompany policy proposal, decision and status changes.

**Conflict requiring review:** prompt 02 explicitly allowed the proposer to
be one issuance approver; this prompt's universal DB CHECK forbids that.
Proposed rule: future issuance requires two distinct non-proposers, which
can require three accounts. Existing approved policies remain effective;
any legacy self-vote stays preserved in the old table as historical evidence,
not rewritten into a compliant decision under a false requester. Import
non-self decisions with original timestamps/provenance; stale pending
rounds that cannot satisfy the new rule and request fresh decisions.
After cutover, the old table is read-only legacy evidence with no live
application dependency, not a second active approval mechanism. Do not
drop that evidence or silently revoke active issuance. Actual existing
rows must be reported by migration preflight before selecting the backfill.

## 3. Close scheduler, events and recovery

### 3.1 Leadership and deadlines

Run one long-lived close-scheduler task per application instance. Use the
existing held-session advisory-lock pattern with a new key (proposed
7310005), acquired per work pass and held through its transactions. Only
the lock holder scans/executes due work; followers retry within the poll
cap. This means one active scheduler across instances while allowing
failover. Execute leader work on the pinned connection so losing that
session stops its transactions; unlock or close before pool release.

At boot, catch up immediately before sleeping. Find the earliest close for
OPEN/SUSPENDED markets and cache it in memory. Sleep only until that
deadline or a short configurable cap, proposed 100 ms with an absolute cap
of one second. Re-query on market opened/suspended/resumed events. The short
poll also repairs dropped pings and remote events. Do not add the season
scheduler's fixed 50 ms post-boundary delay.

The prompt's illustrative bulk UPDATE is the candidate condition, not a
single transaction over 1,000 markets. Read bounded due IDs ordered by
`close_at, id`, then close **each market in its own small transaction**:

1. Lock eligible season/market facts consistently; verify current version.
2. CAS OPEN/SUSPENDED to CLOSED where `close_at <= database time`, or the
   authoritative season is closing/closed/finalized/expired.
3. Increment version; write `closed_at`, audit and `market.closed` event.
4. Commit, record lateness and move to the next due market without sleeping.

Database time decides actual eligibility; injected time drives deterministic
unit tests. Wall-clock deadlines are converted to bounded monotonic sleeps
and re-evaluated after waking. A backward/forward wall-clock change cannot
permit a transaction to trade beyond the DB deadline.

Proposed indexes:

- `(close_at, id) WHERE status IN ('OPEN','SUSPENDED')`.
- `(season_id, close_at, id) WHERE status IN ('OPEN','SUSPENDED')`.
- `(open_at, id) WHERE status IN ('APPROVED','FUNDING')` for opening recovery.
- `(id) WHERE status = 'CLOSED'` for handoff recovery.
- Market category/status/created-time, author/status/updated-time and all new
  foreign-key access paths; unique slug; partial featured-rank index.
- `pg_trgm` GIN index on `question`, plus category/source/terms/approval
  lookup indexes and audit `(target_type, target_id, created_at, id)`.

The close path does not wait for Redis, notification delivery, snapshot
rebuilds or order cancellations. A serial per-market transaction loop must
prove the burst target on real Postgres; if it misses, report measured
lateness and optimize before considering a bounded synchronous fan-out.
Never hide a miss by moving transitions into fire-and-forget tasks.

### 3.2 Season closure and durable event delivery

Reuse `outbox_events` and the existing publisher; do not create another
outbox. Generalize publisher kicks to accept market and ledger signals,
and reduce the five-second fallback poll to a configurable short interval
(proposed 100 ms). This work is a shared platform change requiring ledger
regression coverage.

The trading-state subscriber is also the market event dispatcher. A store
port reads Redis stream events using bounded blocking deadlines when
available. Every application instance needs its own fanout position;
instances must not compete in one consumer group that gives an event to
only one cache. Deduplicate event IDs and ignore lower aggregate versions.
On reconnect/stream trim, capture a stream position first, rehydrate from
PostgreSQL, then replay buffered events after that position with version
checks. This closes the snapshot/subscription gap. Redis loss never loses
the authoritative outbox rows or close work.

On `season.closing`, wake the leader to close every remaining OPEN/SUSPENDED
market of that season; event handling schedules idempotent work rather than
declaring it completed. Startup and short polling also query authoritative
season status/end times, so published-but-lost Redis messages cannot strand
a market. Outbox rows are not treated as unprocessed merely because
`published_at` is set or unset: that flag tracks delivery, not consumption.

Periodic snapshot hydration is the independent repair path for all market
cache state. No timestamp/UUID high-water mark is assumed to encode commit
order; concurrent outbox transactions can commit out of creation order.
Redis is ephemeral and safe to rebuild. Holder notification persistence and
exchange cancellation consumers remain later-prompt work.

### 3.3 Timing evidence

Record scheduler candidate count, work-pass duration, failures, leader
acquisition/failover, overdue count and maximum lateness. Measure each
close at confirmed commit completion against its `close_at`, rather than
the assigned `closed_at` or poll start. Report maximum and p50/p95/p99, DB
pool wait, server/DB hardware, concurrency and runtime/compiler version.
With 1,000 deadlines spread over five seconds **every** healthy-run close
must commit within one second, not merely p99. Catch-up downtime is
reported separately from healthy scheduling latency.

## 4. Exchange contracts and process caches

The markets service exports these logical contracts; this notation is not
unverified slang source:

```text
policy(market_id) -> MarketPolicy {
  market_id, season_id, redemption_units, min_price, max_price, tick,
  max_order_qty, fee_units, min_order_notional, close_at, terms_version
}
trading_state(market_id) -> OPEN | SUSPENDED | CLOSED | NOT_TRADABLE
```

Unknown market is a typed not-found failure. Known pre-open, rejected or
other nontrading state maps to NOT_TRADABLE; OPEN/SUSPENDED map explicitly,
and CLOSED plus resolution/settlement/dispute/void states map to CLOSED.
An overdue OPEN/SUSPENDED row maps to CLOSED even before the scheduler
updates it. An ended/nonactive season never produces OPEN. A DB failure on
a cache miss is unavailable, never an assumed OPEN state.

### Policy cache

Do not cache mutable draft policies forever. Once first opened, retain
immutable entries keyed by `(market_id, terms_version)` for process life.
Maintain a current-terms pointer from authoritative hydration/versioned
events; a miss loads the current version from Postgres, with single-flight
per key. Clarification creates a new key and updates the pointer, retaining
the old entry. Economics are identical across these keys; the returned
`terms_version` is intentionally different. This resolves the prompt's
claim that the whole object never changes despite clarifications changing
one of its fields. Never memoize an unknown ID permanently.

### Trading-state cache

Keep a mutex-protected map of status, registry version, close instant and
season status/end. Apply updates only from committed facts. Any `market.*`
event invalidates/refreshes the corresponding entry; keep CLOSED tombstones
so delayed events cannot reopen it. The local clock deadline check always
overrides a stale OPEN hint. Subscriber gaps/disconnection mark hints stale;
rehydrate via ports and use Postgres on a miss/invalid entry. The snapshot
builder's periodic hydration repairs missed state events too.

This is an acceleration contract, not authorization for a fill. Prompt 05
must check market status, deadline, season eligibility, terms and owner
fencing again in its committing transaction. A stale hint can never be
the final trading decision.

### Confirmed slang concurrency and layering

Reuse `docs/auth/slang-notes.md`, especially its later ledger corrections:
`spawn` takes top-level functions with explicit arguments; channels are
bounded; `select` has a default arm but no timeout arm; `join_wait` wraps
the worker result and can return panic failure. Mutexes are explicit and
must unlock on every exit. No closures, async/await, cancellation, sorting
builtin or `spawn_blocking` is assumed.

Long-lived tasks are the close scheduler, snapshot/stats builder,
trading-state/event subscriber and shared outbox publisher. Existing auth
and ledger workers remain. Coalesced cache/metrics pings may be spawned
after commit; transitions, approvals and edits never are. A timer channel
may wake workers using the existing bounded ticker pattern. No lock is
held across port I/O, sorting, network delivery or serialization.

## 5. Public read model and snapshots

### 5.1 API contract planned for implementation

| Route | Behavior |
|---|---|
| `GET /v1/categories` | Sorted `{id,name,icon,open_count}` list; open count uses actually tradable OPEN markets |
| `GET /v1/markets` | Category, `filter=trending|ending_soon|new`, `status=open|resolving|all`, cursor and limit; default new/open/24, proposed maximum 100; `{items,next_cursor}` |
| `GET /v1/markets/featured` | Highest-priority published featured card, then deterministic tie-break; adds `series_7d: null` until an actual series exists; NOT_FOUND if absent |
| `GET /v1/markets/search?q=` | Parameterized pg_trgm search over published questions, bounded query length/result count; empty query returns empty array |
| `GET /v1/markets/{id_or_slug}` | Public detail from UUID or frozen slug; unpublished markets yield NOT_FOUND |

Register static `/featured` and `/search` before the dynamic route. Public
route intent uses the repository's `zokor:public` convention; signed-in
admin routes still explicitly apply `require_session`.

MarketCard fields are exactly `id`, `slug`, `question`, nested category
`{id,name,icon}`, `status`, `closes_at`, `closing_soon`, `redemption_units`,
`last_price`, `chance_pct`, `yes_ask`, `no_ask`, `volume_units`, `change_24h`
and `status_note`. MarketDetail adds `rules`, resolution source `{name,url}`,
`resolve_by`, price band `{min,max,tick}`, season `{ordinal,ends_at}`,
`fee_units`, `terms_version` and `created_at`. API `closes_at` maps to DB
`close_at`. Absent stats and series are null, including volume and change;
do not synthesize asks as complements of last trade.

Proposed filters: `open` includes OPEN/SUSPENDED, so paused cards remain
discoverable; `resolving` includes CLOSED, RESOLUTION_PENDING, DISPUTED,
RESOLVED and SETTLING; `all` includes published states including SETTLED
and VOIDED but excludes all unpublished statuses. Status note is the
current suspend reason for SUSPENDED and null for resolving until prompt
08 supplies it. `closing_soon` means `0 < close_at-now < 3 hours`, computed
at response time; formatting relative/weekday time belongs to the frontend.

Trending orders by `volume_24h_units` descending/null last, then players,
then created time and ID descending; without stats, newest first. Lifetime
`volume_units` must not substitute for a 24-hour window. Ending-soon orders
by upcoming close then ID; new orders by created time then ID. Definitions
and null ordering are stable and tested. Suggested feature priority is
smallest positive featured rank, then newest and ID.

Resolution sources currently define a URL pattern, not per-market concrete
URLs. Until a deterministic, validated expansion scheme is defined, detail
`url` is the curated pattern itself and consumers treat it as source
metadata; do not manufacture a clickable evidence URL or fetch arbitrary
URLs. The source snapshot preserves the terms the approver reviewed.

### 5.2 Single-flight snapshot builder

Build bounded variants for each known category plus all categories × three
filters × three status filters. No per-user/public cache and no arbitrary
query-string keys. Publish immutable vectors, ID/slug indexes, source and
season maps, and stats as one generation. Rebuild via one process-local
worker; readers keep the old generation while it runs. Swap under a short
mutex, then release before readers serialize.

The builder reads market, stats and season data in a consistent read
transaction through store ports. It refreshes normally no slower than
every two seconds; proposed baseline is one second to leave time for DB
work. An event requests immediate rebuild with a capacity-one dirty signal.
Interpret "at most every 2 seconds" as the maximum periodic interval;
events can rebuild sooner. Events arriving during a build leave dirty set
and trigger another pass. There is never a second concurrent rebuild or
per-reader database stampede.

Merge the matching immutable stats map at serve time; all prices and
ranking derive from the same published generation. Query filters/cursors
index preordered vectors; warm list requests make no DB calls. Compute
deadline-sensitive visibility/open counts at response time so a close does
not depend on the next build. Cap result size and bound category variants;
measure snapshot size/build time and retained generations rather than
promising unbounded memory.

Cursor proposal: encode generation, normalized filter key and next offset;
retain a small bounded number of recent generations for stable paging.
Reject mismatched/expired cursors with BAD_REQUEST and an instruction to
restart. A query cannot silently page into an unrelated new ordering.

Detail uses the same warmed ID/slug/season/stats/source caches to meet its
p99 target. On a cold miss, resolve the market/season ID, launch market,
stats and season reads together with verified spawn/join primitives and
await all handles, unwrapping both result layers. Unknown slug may require
one lookup first; do not claim dependent lookups are parallel. Revalidate
the assembled row version/season association if it changed during reads.
Search remains an indexed Postgres query and is reported separately from
the zero-round-trip list target. Featured/categories use the snapshot.

Boot completes initial hydration before marking market reads ready.
Failed refresh keeps the previous generation and emits failure/freshness
metrics. Bound acceptable snapshot age (proposed ten seconds); beyond it
return UNAVAILABLE instead of indefinitely presenting stale states. Detail
may use an authoritative fallback. Events improve freshness, periodic
Postgres hydration supplies recovery, and no benchmark is inferred from
the in-memory design alone.

## 6. Admin contract and field errors

All routes below require a session and §2.2 authorization:

| Route | Input / result |
|---|---|
| `GET /v1/admin/markets?status=&mine=&cursor=` | Author-scoped for creators; cursor page with version and draft completeness |
| `POST /v1/admin/markets` | Partial fields; returns DRAFT and version |
| `PATCH /v1/admin/markets/{id}` | Partial fields plus required version; draft/change-requested author only |
| `POST /v1/admin/markets/{id}/submit` | `{version}` |
| `POST /v1/admin/markets/{id}/approve` | `{version}` |
| `POST /v1/admin/markets/{id}/request-changes` | `{version,reason}` |
| `POST /v1/admin/markets/{id}/reject` | `{version,reason}` |
| `POST /v1/admin/markets/{id}/suspend` | `{version,reason}` |
| `POST /v1/admin/markets/{id}/resume` | `{version,reason}`; may return CLOSED |
| `POST /v1/admin/markets/{id}/clarify` | `{version,rules?,question?,reason}`; reject other changed fields |
| `GET /v1/admin/markets/{id}/history` | Paginated immutable terms, approvals and audit, creator scope applied |
| `GET /v1/admin/resolution-sources` | Curated definitions with approval flag |
| `POST /v1/admin/resolution-sources` | Curator/super admin creates unapproved source; no payload can self-set approved |
| `POST /v1/admin/markets/validate` | Partial/form fields, optional mode default full; returns valid flag and field errors without mutation |
| Proposed `GET /v1/admin/markets/seasons` | New ledger-service projection over its `open_seasons` port, filtered to ACTIVE/SCHEDULED, with ordinal/start/end |

Source approval is not exposed by the prompt. Proposed initial policy:
approved sources come from reviewed migration/seed/operator provisioning;
new API-created sources remain unapproved until a separately authorized
operator workflow is implemented. Do not quietly expose an extra approval
route or make new sources approved by default.

Keep the shared `{error: ...}` envelope. Extend its field records
backwards-compatibly with optional `code`/`message`, retaining `reason` for
existing auth clients. Market failures expose `{code,field,message}` in
`error.fields`; top-level code is the first validation code. Register every
market code and render it through zokor; no raw store errors reach clients.
Dry-run validation returns the same field-entry shape in its success body.

| Code | Field(s) | HTTP |
|---|---|---|
| CLOSE_AFTER_SEASON_END | `close_at` | 422 |
| RESOLVE_BY_INVALID | `resolve_by` | 422 |
| PAYOUT_INVALID | `redemption_units` | 422 |
| PRICE_RANGE_INVALID | `min_price`, `max_price` | 422 |
| BAND_NOT_SYMMETRIC | `min_price`, `max_price` | 422 |
| TICK_INVALID | `tick` (message names failed divisibility) | 422 |
| RULES_INCOMPLETE | Specific `rules.yes_if`, `rules.no_if`, `rules.edge_cases` | 422 |
| QUESTION_INVALID | `question` | 422 |
| SOURCE_NOT_APPROVED | `resolution_source_id` | 422 |
| SEASON_NOT_OPEN | `season_id` | 422 |
| SELF_APPROVAL_FORBIDDEN | `approval` | 403 |
| STALE_VERSION | `version` | 409 |
| INVALID_TRANSITION | `status` | 409 |
| FORBIDDEN_ROLE | `actor` | 403 |
| LOCKED_AFTER_OPEN | Each attempted locked field | 409 |
| BAD_REQUEST (existing) | Parsing/unknown category/open_at/quantity/reason/cursor field | 400 |
| NOT_FOUND, UNAUTHENTICATED, UNAVAILABLE (existing) | No field unless relevant | 404/401/503 |

Required reasons are trimmed, nonempty and bounded (proposed 20–600
characters); multiple supplied invalid fields yield deterministic errors.
Map trigger immutability failures to LOCKED_AFTER_OPEN only for recognized
constraint identity; unexpected constraint/storage errors log internal
detail and return UNAVAILABLE. `docs/markets/API.md` will document exact
examples and complete DTOs after review, alongside implementation.

## 7. Verification and development seed plan

| Area | Required evidence after implementation |
|---|---|
| State machine | Enumerate every status pair/action for each role, ownership and system identity; all unlisted edges fail without writes; self-approval fails even for super admin |
| Terms | Submission freezes reproducible hashes; edits invalidate pending approval; reject/request changes require reasons; clarification increments terms and row versions with identical economics |
| Database | Raw SQL attempts to change payout/band/tick/season/close/quantity on OPEN, SUSPENDED and later states fail; transition-into-open bypass and status regression fail; generic and market self-approval constraints fail |
| Validation | V=10/50/100/200; default/narrow/equal symmetric bands; asymmetric/range failures; each tick check independently; close at season end ±1 second and equality; resolution at 1h/48h endpoints and outside; display maths for variable V |
| Approval migration | Two distinct non-proposers still required for new issuance; duplicate vote never counts twice; legacy approved policies retain meaning; existing grant and policy replacement tests pass |
| Concurrency | Two parallel approvals on one version: one succeeds, one STALE_VERSION; ten same-version edits: one succeeds; failed audit/outbox write rolls back all state/history/approval changes |
| Scheduler | Real PostgreSQL 1,000-close burst, each commit within one second; overdue boot catch-up; two instances have one leader per pass; kill leader/connection; missed Redis event repaired from season/deadline facts |
| Season | `season.closing` closes all OPEN/SUSPENDED markets of just that season; event duplicated/reordered/lost; concurrent opening cannot cross a season end |
| Reads | Open visible under two seconds, pause note present, null stats, filters/cursor behavior, slug handling, price chance, warm list makes zero DB queries; cold detail joins all spawned results |
| Isolation | Creator-only actor cannot list/read/history/edit another creator's draft; role unions do not bypass author/self-approval checks; public search/detail never leak drafts |
| Cache recovery | Per-instance fanout, subscriber restart/trim, Redis outage, out-of-order version events, single-flight under load, stale data limit and timer-sensitive close behavior |

Use deterministic clocks and fakes only in `*_test.sl`. Each new package
has a neighboring test file. Integration runs use the owner and `say_app`
URLs from the existing isolated test stack, not a live database. Run
`zokor check`, targeted tests, integration tests and `make check` after
implementation. Documentation-only review does not establish new feature
test results.

Performance report must separate list/detail warm hits, cold fallback and
indexed search. Record load duration, requests/concurrency, market count,
errors, p50/p95/p99, cache hit/miss and rebuild time, RSS/GC behavior,
database pool sizing and compiler/runtime version. Test while closes and
snapshots run, not just on idle cache lookups. A local machine benchmark
does not prove deployment latency.

Proposed `bin/say seed:markets` dispatches before starting workers and is
accepted only for explicit dev/test profiles, refused for all others.
Seed relative to injected current time/eligible seasons so "closing soon"
does not expire with the example dates. Use deterministic IDs and idempotent
fixture keys; never overwrite user-authored data. Record fixture provenance
in audit/outbox; any fixture bootstrap for later states is confined to
dev/test and is not an extra production lifecycle transition.

Seed categories and curated sources plus these eight markets, without fake
exchange prices/volume:

| Market | Required fixture behavior |
|---|---|
| Enyimba v Rivers United | Featured, V=100 |
| Lagos rain over 20 mm | Closing soon |
| 3+ goals Arsenal v Man City | Football |
| Afrobeats No. 1 in the UK | V=200 |
| New MacBook Pros | V=50 |
| Nollywood ₦100m | RESOLUTION_PENDING |
| Super Falcons friendly | SUSPENDED with reason |
| Remo Stars v Shooting Stars | SETTLED fixture only; no pretend settlement posting |

Supply complete dated yes/no questions and all rule/source fields in each
fixture. These are demo markets, not assertions about real fixtures or
outcomes. Approval/funding/settlement provenance must not claim real money
movement or later-prompt execution that has not occurred.

## 8. Review decisions, conflicts and later work

Implementation prompt 03 wins over the older specs. The proposed decisions
below are deliberately visible before any migration is written.

| Decision | Proposal / conflict resolved |
|---|---|
| R1: Draft schema | Conditional completeness instead of baseline NOT NULL fields; preserve existing IDs/history and preflight legacy data |
| R2: Immutable economics | Protect max_order_qty as well as the prompt's explicit locked list; start DB lock at FUNDING, cover entry into OPEN and every later state |
| R3: Issuance approvals | One generic active workflow, two non-proposer votes going forward; preserve legacy policy decisions/evidence without falsifying requester identity |
| R4: Schedule | Add missing `open_at`; use the scheduler for due funding/opening and closed handoff recovery; requested liquidity waits for prompt 09 |
| R5: Permissions | Bare admin/treasury/resolver get no new market privileges; curator/super admin edit only their own drafts; no self-approval override |
| R6: Terms/cache | Clarification changes terms_version and adds a permanent cache entry, while immutable economics stay identical; fixed canonical hash includes the approval-relevant policy |
| R7: Reads | Open filter includes paused markets; all never includes drafts; add nullable 24h-volume stat; use warm detail cache plus parallel cold reads |
| R8: Delivery/freshness | Reuse shared outbox with shorter poll/kicks; each instance receives events; one-second hydration repairs Redis loss; no UUID/timestamp commit cursor |
| R9: Supporting admin data | Add an eligible-season read route; API-created sources remain unapproved pending an explicit operator workflow; expose source pattern as metadata |
| R10: Validation | Preserve shared error envelope with richer field entries; semantic question/cancellation quality is curator-reviewed; reasons bounded at 20–600 characters |

Other resolved spec conflicts: proposed `internal/exchange` paths are not
used; redemption's old `>=3` becomes 10–1000; symmetric/tick checks are new;
REJECTED/CHANGES_REQUESTED extend the baseline status constraint; old
"band fixed at approval" wording is enforced by no-edit review flow and a
post-APPROVED DB lock; resolve_by may cross the season end per this prompt;
the illustrative bulk close SQL becomes per-market transactions to honor
the prompt's stronger atomicity requirement. No old draft schema or cache
wording overrides these rules.

After review, implement schema and approval consolidation first, then pure
validation/authorization/state machine, transaction adapters, cache and
scheduler ports/workers, public/admin endpoints, seeds, integration tests
and measurements. Publish `docs/markets/API.md` and a performance report
with actual results. Review approval authorizes the next stage; this
document does not imply any migration has run.

Deferred integration work:

- Prompt 05: fills update `market_stats` and 24h metrics; exchange checks
  authoritative trading status inside commits and cancels resting orders
  on market/season close. Ledger market-wallet opening hook also remains.
- Prompt 09: liquidity approvals, bot allocations and actual funding.
- Prompt 08: resolution/dispute/void/settlement transitions, immutable final
  decisions and resolving status notes. Existing void-accounting blockers
  remain; no void payout is introduced here.
- Prompt 10: admin approvals inbox UI and broader role-management UI.
- Holder notifications: clarification event contract is supplied here;
  actual holder discovery/delivery requires the later exchange/notification
  integration and must be reported separately from outbox enqueueing.

### Design-stage verification

Only this document changed. `make check` was run with installed slangc
0.2.3: `zokor check` passed for 18 packages, then the existing
`src/platform/auth` test runner failed C compilation in `sl_io_res_line`
because generated `r->v.has` / `r->v.v` treat a pointer as a value.
The final build was not reached. Database/Redis integration cases skipped
without their test URLs; load cases skipped without `LEDGER_LOAD=1`.
This baseline compiler/runtime failure is outside the documentation change
and is not evidence of market implementation or performance validation.
