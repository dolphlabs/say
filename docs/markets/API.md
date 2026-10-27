# Market registry API

Implementation: registry domain, PostgreSQL adapters, routes and background
snapshot/close workers. Public requests use immutable in-process snapshots;
admin writes are synchronous transactions. The exchange, actual funding
and resolution consumers are separate modules.

All signed-in routes require `say_session` or the existing Bearer session
token. Creator access is restricted to authored drafts/history; curator
and super_admin may review. Treasury/admin/resolver alone cannot mutate
markets. No caller can approve their own submission, including super_admin.

| Route | Result |
|---|---|
| GET /v1/categories | Categories with open_count |
| GET /v1/markets | items,next_cursor,generation,as_of; category UUID, filter new/trending/ending_soon, status open/resolving/all, default limit24/max100 |
| GET /v1/markets/featured | First eligible featured/open card and series_7d=null until exchange bars exist |
| GET /v1/markets/search?q= | At most50 public cards;2–140 Unicode characters |
| GET /v1/markets/{uuid_or_slug} | Card, rules, resolution_source, resolve_by, price_band, season, fee_units, terms_version and created_at |
| GET /v1/admin/markets | Author-scoped for creators; status,mine,cursor,limit(default50/max100) |
| POST /v1/admin/markets | Create partial DRAFT;201 with market and Location |
| PATCH /v1/admin/markets/{id} | Edit authored DRAFT/CHANGES_REQUESTED; mandatory version |
| POST .../{id}/submit | version; validate and freeze terms; REVIEW |
| POST .../{id}/approve | version; independent reviewer; APPROVED |
| POST .../{id}/request-changes | version,reason; CHANGES_REQUESTED and stale pending approval |
| POST .../{id}/reject | version,reason; REJECTED |
| POST .../{id}/suspend | version,reason; SUSPENDED |
| POST .../{id}/resume | version,reason; OPEN, or CLOSED if deadline passed |
| POST .../{id}/clarify | super_admin; version,reason,question?/rules?; economic fields refused |
| GET .../{id}/history | Immutable terms, approval facts/current projections and recent audit |
| POST /v1/admin/markets/validate | Dry-run fields;200 {valid,errors:[{code,field,message}]} |
| GET /v1/admin/resolution-sources | Curated source definitions/approved flags |
| POST /v1/admin/resolution-sources | Curator/super_admin;name,url_pattern,kind(html/json); always created unapproved |

Create/edit fields: question,category_id,season_id,resolution_source_id,
rules{yes_if,no_if,edge_cases},open_at,close_at,resolve_by,redemption_units,
min_price,max_price,tick,max_order_qty,fee_units,min_order_notional,
liquidity_request,featured_rank,opening_price. Dates are RFC3339; money and
quantities are integers. Omitted PATCH fields stay unchanged; explicit null
clears an optional draft field. The fee/minimum are fixed1/2. Missing band
defaults1..V−1; opening price defaults to the lower legal central tick.

All writes CAS version and commit audit/outbox with their data. Approval
acceptance does not claim a funded/open market: scheduler advances
APPROVED→FUNDING and opens only when due/eligible and liquidity is applied.
Close stops trading eligibility at the deadline even before the registry
worker records CLOSED. Close/handoff events do not themselves prove exchange
orders/holds were drained or that payouts occurred.

Public cards expose no author/approval identities or funding requests.
last_price,chance_pct,asks,volume/change remain null without actual stats.
Chance is100*last_price/V, not a money value. Current status/deadline controls
supersede an old card. Warm detail does no database read. Local writes kick
snapshot rebuilding; every node also refreshes authoritative data on a
bounded interval. Events never substitute for commit-time trading checks.

Public cursors bind generation/category/filter/status/index; bounded older
generations allow stable pagination. STALE_SNAPSHOT requires restarting.
Admin cursors bind the current generation/status; reload an expired page.
Search uses the public snapshot and the schema also provides a trigram
index for storage-backed search consumers.

| Validation code | Field |
|---|---|
| QUESTION_INVALID | question |
| RULES_INCOMPLETE | rules.yes_if/no_if/edge_cases |
| SOURCE_NOT_APPROVED | resolution_source_id |
| SEASON_NOT_OPEN | season_id |
| CLOSE_AFTER_SEASON_END | close_at; message includes actual season/end in configured zone |
| RESOLVE_BY_INVALID | resolve_by |
| PAYOUT_INVALID | redemption_units |
| PRICE_RANGE_INVALID | min_price/opening_price |
| BAND_NOT_SYMMETRIC | max_price |
| TICK_INVALID | tick |
| BAD_REQUEST | category_id,open_at,max_order_qty,fee_units,liquidity_request or malformed request |

Validation failures use the registered BAD_REQUEST envelope with
fields:[{code,field,message}]. State/permission codes:
SELF_APPROVAL_FORBIDDEN(403),FORBIDDEN_ROLE(403),NOT_FOUND(404),STALE_VERSION(409),
STALE_APPROVAL(409),INVALID_TRANSITION(409),LOCKED_AFTER_OPEN(409),
STALE_SNAPSHOT(409). UNAVAILABLE(503) contains no database/provider detail.

Worker controls read once from platform/config: MARKET_SNAPSHOT_EVERY
(default1.8s),MARKET_CLOSE_POLL(100ms),MARKET_CLOSE_WORKERS(8),
MARKET_SNAPSHOT_GENERATIONS(32). Set test database URLs and MARKET_LOAD=1
for close/cache performance gates. Timing results belong in PERFORMANCE.md.

`GET /v1/admin/seasons` is signed-in creator/curator metadata for the market
form. It returns `{items:[{id,ordinal,status,starts_at,ends_at,timezone}]}`,
with RFC3339 timestamps and only ACTIVE/SCHEDULED seasons. Admin market
pagination cursors bind generation, status, mine and authenticated account;
reusing one across callers or filters returns STALE_SNAPSHOT.
