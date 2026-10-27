# Standings, profiles, settings and governance

Status: **proposed; awaiting review**. Date: 2026-10-26.

Prompt 10's design deliverable. Stop here for review before migrations,
endpoints, new tests, clock refactoring or launch rehearsal. No staging
deployment, financial operation or rehearsal result is implied.

## 0. PRD and existing project

| User/system | Required outcome |
|---|---|
| Player | Understand current/final rank and profit, see a public call history without exposing account credentials/quantities, and manage identity/settings |
| Deleting player | Lose access immediately, cancel every outstanding order, erase personal data and preserve accounted-for positions/payouts |
| Staff | Decide current requests independently, inspect an immutable audit trail and use enrolled/recent TOTP for privileged actions |
| Operator | Revoke access promptly, recover bounded jobs and rehearse the whole exchange with reproducible clocks/faults |
| Portfolio/notifications | Share valuation/rank generations and announce a final rank only after a durable final standings freeze |

Inspected facts, distinct from earlier proposed designs:

- Auth/ledger are implemented. Registry, matching, runtime, stream,
  portfolio, resolution and bots remain proposed documents. This module
  cannot launch-rehearse nonexistent dependencies or claim their APIs work.
- Accounts use kind USER/BOT, status DELETED and citext identity fields.
  Sessions, credentials, Google links, OTP limits, logout/password/unlink
  routes and a username courtesy hold already exist. Reuse those owners.
- GET /v1/me currently maximizes username_changeable_at against season end;
  that would block the new first-72-hours rule. No username-change/history
  or email-change workflow is implemented.
- DELETE /v1/me currently takes no confirmation body and only flags DELETED
  and revokes sessions. It does not drain orders or erase identity/history.
- Auth audit events pass through a bounded, lossy writer channel and may
  arrive after a mutation. That is insufficient authority for governance.
- Migration 004 grants broad default DML and explicitly protects the
  journal, not audit_events. Add explicit audit/approval protections.
- Generic approvals in prompt 03 are mutable request/status rows. Prompt
  10 requires append-only approval facts; it wins and needs a deliberate
  contract change across subject owners, not a second competing inbox.
- timez.Clock exists and ledger receives it. Auth services/stores still
  call timez.now()/SQL now() directly. Clock injection is incomplete.
- crypto supplies hmac_sha256, rand, sha256 and sha1. No native TOTP,
  base32, authenticated encryption or key-management SDK is exposed by the
  inspected crypto/encoding docs. Those APIs cannot be invented.

Use `src/standings`, `src/profiles`, `src/approvals` and `src/audit` with
domain/service/store/server layers; extend `src/accounts` for settings,
roles and TOTP. Reuse portfolio valuation through its service contract,
ledger/markets/settlement/bots through theirs. Only stores/platform/db do
PG I/O; platform/app composes ports, jobs, clocks and snapshot cells.
Scaffold features/routes with zokor after review. No tenants, direct
balance writes, cross-feature domain imports or code comments by default.

## 1. Standings, metrics and finality

### 1.1 One financial definition, one valuation generation

Call prompt 07's valuation implementation and shared vectors. There must
not be a leaderboard-specific interpretation of marks or settlement P/L:

```text
positions_value = shared value of positive-qty unsettled exposure
total = available_SEDI + held_SEDI + positions_value
profit = total - actual_starting_grant
```

Cash already includes sales, fees and committed settlements. Do not add
realised P/L, paid_out or fees again. Reserved shares count in total qty
once; reserved cash counts once. Reuse last-trade → own-outcome midpoint →
exact average-cost fallback, including the NO complement/rounding rules.
The footnote's "last traded price" is abbreviated copy, not permission to
discard prompt 07's no-trade fallback. Expose sources/as_of; propose full
copy: "Profit includes settled markets and open positions valued using
the portfolio's price rules. Ties go to whoever got there first."

Capture one immutable in-memory market_stats generation and read accounts,
grants, cash/share wallets, positions, history and result projections in a
coherent read-only REPEATABLE READ transaction. Avoid one transaction per
player and avoid unrelated concurrent reads that double-count a fill.
Validate position/share agreement; a missing/corrupt mark or basis cannot
be replaced with a plausible invented profit. Keep the previous successful
snapshot marked stale, or report unavailable, and alert reconciliation.

Exact equality means **the same source snapshot and mark generation yield
the same result**, not that a thirty-second table equals a later live
portfolio read after trades. Responses carry generation, financial_as_of,
marks_generation and computed_at. Portfolio/profile/home rank is from the
standings generation and may lag their live profit. Return its rank_profit
value/as_of separately, so a current profit is never labelled as the exact
value that earned an older rank. A client can request/show the published
standings valuation for an exact comparison; it is not a second formula.

Eligible participants are verified ACTIVE USER accounts with
leaderboard_eligible=true, no staff role and not deleted. BOT is excluded.
Proposed staff set matches prompt 09: admin, super_admin, curator, treasury,
resolver; creator alone is a market-author capability, not staff. Review
this classification explicitly. Missing actual grant leaves profit null
as in portfolio; propose an unranked grant-pending state until funded,
rather than assuming1000 or rewarding a fabricated baseline. Player count
and ranked/funded count are distinct when that state exists.

The "everyone started at S1000" line appears only when the ranked cohort's
actual grants match that policy. Changed amounts/pending grants require
truthful copy; never infer starting grants from system issuance totals.

### 1.2 Calls, outcomes and exact orderings

Calls count distinct market IDs where the account ever held shares in the
season, including fully sold-out positions and voids. Unfilled orders do
not count. Preserve durable holdings/first-held evidence after retirement;
do not count current positions or position_results rows as distinct calls.

Win rate is exact wins/(wins+losses), excluding VOID and unresolved markets.
At least five settled, outcome-classified calls are required for win-rate
ranking. Display null rather than0% for denominator0. Compare fractions
with checked wide cross-products, not rounded display percentages.

**Call-classification decision for review:** users can hold both outcomes,
reverse direction or sell out, so blindly counting WON/LOST outcome rows
can count one market twice. Proposed single-call stance is the last
non-flat net YES/NO direction before Close, or before complete exit if
sold out; retain the immutable exposure event proving it. If never
directional (equal YES/NO only), it is a neutral call: counts toward calls,
not wins/losses or the five-call win-rate minimum. Classify a directional
call against the final YES/NO result, regardless of its financial P/L.
Profile side reflects this same stance with a proposed BOTH/neutral display
when needed. This is a product clarification, not a new win formula hidden
in SQL; confirm it before implementing counters or notification copy.

Every changed observed profit sets profit_reached_at to the run's captured
business time; unchanged profit preserves it. Returning to an old profit
sets a new timestamp. Initial rows get that run time. Retries of the same
run never reset timestamps; a stale leader cannot overwrite a newer run.
This implements "first" at recompute granularity, not exact trade time.
Accounts first reaching a value in the same run tie on ID. Do not use
their first fill, signup time or historical maximum as a different rule.

| Sort | Total ordering and eligibility |
|---|---|
| profit | Profit descending, profit_reached_at ascending, account ID in byte/C order |
| win_rate | Eligible exact fraction descending, then profit descending, reached_at ascending, account ID |
| calls | Calls descending, then profit descending, reached_at ascending, account ID |

Use ordinal row-number ranks with this complete ordering, not dense ranks.
rank_win is null below five qualifying calls; bots/staff/deleted/unfunded
participants have no public ranks. Tie rules for the two secondary sorts
are proposed here because the prompt fixes only equal-profit ordering.

### 1.3 Recompute, snapshots, pages and personal context

A leader-locked task runs every30s and on finalization/eligibility kicks.
It captures run ID/time and a lease/fence, computes metrics/ranks, and
commits one complete generation to season_standings with a published-run
pointer. Failed or partial generations never become current. Upserts use
the current row's prior profit/timestamp; serialize overlapping runs.
Target all10000 players<2s, including source reads, compute, SQL and publish.
Use bounded pages/streamed source aggregation and an O(N log N) sort;
insertion-sorting10000 players is not an acceptable implementation choice.

Build an immutable snapshot with complete sorted compact rows for each
sort, account→row/rank indices, top100 slices, counts, season/provisional
metadata and valuation generation. Top100 plus a rank-only map is
insufficient to serve later pages or an off-page personal row without PG.
Capture rows once and sort indices rather than triplicating sensitive data.

Publish through the verified BookView-style snapshot cell: short pointer
access/publication under the existing mutex/trylock design, no network or
DB while holding it. This is not an invented atomic pointer API. Nonleader
nodes hydrate complete committed generations in background and verify the
published ID before swapping. Event loss triggers periodic generation
recovery. A node with no ready snapshot returns typed warming/unavailable,
not an empty table or an on-request SQL fallback.

Cursor binds season ID, sort, snapshot generation and next index, protected
from tampering. Retain a bounded set of old generations for cursor lifetime;
expired cursors receive a restart response. Never resume an old page in a
new ordering and duplicate/skip players. Define historical season warmup/
eviction and snapshot byte budgets in config; APIs queue bounded background
warmup for cold seasons and report readiness. Final archives are immutable
durable inputs, not permission for unbounded memory growth.

Podium uses the selected sort's first three eligible ranks; items have
stable ranks and the separate me.row is returned even when outside the
page. Clients deduplicate it if already visible and draw the gap only when
needed. limit default50/max100; validate selector, sort, cursor and bounds.
Anonymous requests have no me; authenticated ineligible participants have
explicit unranked context rather than a fabricated rank.

Percentile label is top ceil(100*rank/eligible_sort_count)%, clamped1..100.
For38/3180 this is top2%. For profit sort, if the account is outside top20:
`to_top20 = max(0, twentieth_profit - my_profit + 1)` in integer SEDI.
Merely tying #20 now normally loses to its earlier reached_at. With own
profit514 and #20 profit727,214 more reaches728 and passes. Already top20,
missing rank or fewer than20 eligible rows yields null. On other sorts,
either omit this nudge or label its profit-rank target separately; extra
profit cannot promise a particular win-rate/calls rank.

### 1.4 Provisional and frozen seasons

ACTIVE standings are live/unfinalized. CLOSING/CLOSED and not FINALIZED are
provisional; explain outstanding markets/jobs/sweeps with actual counts.
Do not say "live" when displaying a closed earlier season. Prompt 08's
financial finalization must include prompt 09's required bot sweeps.

On the durable season.finalized signal, run one terminal valuation against
the financial cutoff, with captured eligibility and identity-at-time refs.
Freeze season_final_standings, its complete generation hash/counts and
finalization receipt in one transaction, unique per season. Retries return
the same frozen result; never rerank it on later trades, mark refreshes or
username changes. The final ranking has a distinct ready marker: a financial
FINALIZED season whose snapshot is still building is not yet "final table
ready" and must not send final-rank notifications.

Emit season.final once after the freeze. Prompt 08's season.finalized and
this season.final are distinct financial/table stages, linked by season
and receipt; notification dedupe prevents two "final" messages. Resolve
the earlier prompt 07 template contract to send rank/of from the frozen
generation, not from a later live lookup.

Frozen financial rows/ranks are immutable. Historical names are stored in
an erasable identity-at-time sidecar referenced by those rows, so ordinary
rename retains the name used at the cutoff without embedding erasable PII
in an immutable financial record. Current deletion/staff/ineligibility
redaction can hide a public row without changing frozen financial ranks.
Proposed display keeps rank gaps and original participant count, with a
separate visible count; it never silently promotes #4 into a frozen #3.
Historical-row exclusion versus rank gaps needs explicit review. Deleted
identities are not publicly resurrected by an old snapshot or podium.

### 1.5 HTTP and copy

GET /v1/leaderboard?season=current|ordinal&sort=profit|win_rate|calls&limit=50&cursor=
returns season ordinal/status/start/end/player counts, provisional/reason,
generation/as_of, podium, items, next_cursor and optional me with ranks,
profit, percentile, top20 context and row. GET /v1/leaderboard/strip?season=
uses the same snapshot's top5. Monetary wire values are decimal strings
as in portfolio; null and missing eligibility are explicit.

Read data comes from memory, target p99<5ms; measure successful warm reads,
pagination and personal context, not just cold-error responses. Identity/
session enforcement is still required for me; report its real latency and
any authoritative guard separately instead of silently excluding auth from
an end-to-end result. Personalized responses are private/no-store, never
publicly cache a cookie-dependent me object. Public generic data may use
generation-aware short caching. Home/profile/portfolio consume standings
service, not three different rank calculations.

## 2. Public profiles and privacy

GET /v1/users/{username} returns an explicitly allowlisted public DTO:
username, avatar_color, joined_season, share_url; current_season rank/of,
profit/calls/right/settled with standings generation; and at most50 newest
calls with market slug/question, public side/neutral stance, status and
chance_pct when open. Newest means first-held event time then stable ID;
propose a cursor for older history without an unbounded response.
WON/LOST describe the reviewed call stance, not the sign of trading profit.
Use market policy V for chance, not a universal100 redemption assumption.
Chance uses a public own-side market price only; never expose a holder's
private average-cost fallback as public probability. With no public mark,
chance_pct is null.
Calls remain OPEN/resolving until a final classified result is committed;
VOIDED never counts toward "right" or its denominator.

Proposed joined_season is first actual participation/grant season, null if
none; do not infer it from a nonexistent season at pre-launch signup.
Active verified human profiles may remain public when unranked, with null
rank; no bot profile or deleted profile. Share URL uses canonical username
and configured app origin; Open Graph generation is deferred.

Account/public identity, standings and calls reads may run concurrently
with top-level spawn and join all, unwrapping both task and service errors.
Recheck identity/privacy generation before constructing/publishing a
response; joining independent reads is not an atomic financial snapshot.
The profile uses published standings profit/rank together and never mixes
a fresh profit into an old rank without a separate explicit as_of field.

No email, cash/balance, free/held amounts, quantities, cost basis, account
credentials, session data, order details or private dispute text. Build the
public DTO directly; never serialize an account/position struct and then
remove a few keys. Schema/privacy tests recursively forbid private keys
and verify actual values, nested data, errors and cached responses.
Public profit and a known starting grant may allow inference about total
equity; "balance stays private" is a field-exposure promise, not a claim
that the public numbers reveal nothing. Record this for privacy review.

Cache by normalized username plus identity/privacy and standings generation
in-process for10s; send Cache-Control: public,max-age=10 on public200 only.
Aliases redirect to the account's current canonical name for their active
reservation, not a redirect chain. DELETED returns404.

**Deletion/cache boundary:** local tombstones and generation invalidation
must override cached public rows immediately on informed nodes. Strict
global instant removal is incompatible with independently cached public
responses valid for10s. Use controlled CDN purge and node invalidation
barriers, report pending acknowledgements, and document that existing
third-party copies cannot be recalled. Review the allowed public cache
revocation delay; if zero is mandatory, change the supplied public-cache
contract before implementation. Never claim max-age10 guarantees instant
erasure on disconnected nodes.

## 3. Account settings and deletion

### 3.1 Username window, reservation and history

Use signup normalization/validation/reserved-name rules unchanged. The
rename window is [season.starts_at,starts_at+72h), once per active season;
initial signup is not a rename. A no-op same normalized name does not
consume the allowance. Require the authenticated verified human and the
same availability/hold contract as signup.

POST /v1/me/username {username,hold_id} synchronously locks the account and
relevant normalized-name claims, rechecks window/season/version, consumes
one rename claim unique(account,season), changes the canonical name,
appends username_history and reserves the old name until change_at+30days.
Audit/outbox and identity-cache invalidation commit with it. At exactly72h
the window is closed. Outside the window/change already used, return the
specified USERNAME_CHANGE_WINDOW_CLOSED or
USERNAME_ALREADY_CHANGED_THIS_SEASON with next eligible season start.

GET /v1/me must replace the current max(season_end,changeable_at) logic with
this domain rule, exposing can_change_username, window_ends_at and
username_changeable_at. During an unused open window, changeable_at=now;
after use/outside it, next season start. Before an active season, use its
next eligible scheduled start. UI can say "You can change it when Season
01 ends" when that endpoint is actually the next season boundary.

Postgres is authoritative across current usernames and30-day reservations.
The account username unique index alone does not prevent signup taking a
reserved old name from another table. Use a canonical unique name-claim
namespace/DB guard shared by signup, Google complete and rename, with
expired-claim takeover checked under lock. Advisory/name locks are acquired
in normalized byte order, and DB constraints/triggers defend cross-table
claims against bypass. Redis ten-minute holds stay a courtesy with the
existing fallback behavior; availability is never the final guarantee.

GET /v1/users/{old} sends301 only while its alias reservation is active.
Resolve name→account→current name directly, including a later rename or
permitted self-reclaim, so aliases cannot loop. Cache the redirect no
longer than its remaining reservation (proposed max-age=0,must-revalidate).
After expiry, release the namespace claim; the old URL can eventually
belong to someone else under the specified finite reservation policy.
Final standings retain their erasable name-at-cutoff reference on ordinary
rename; deletion erases that identity layer.

### 3.2 Email, password, Google and notification settings

POST /v1/me/email {new_email} creates a bounded pending change tied to the
session/account, normalized new address and opaque hashed change_token.
Send OTP only to the new address; response202 has change_token and
resend_available_at, with no premature account.email mutation. Reuse OTP
HMAC/attempt/cooldown/hourly machinery, extending allowed purpose to
change_email. Bind code to this pending change/address, not just an account
whose target address may have since changed. Proposed code lifetime10min,
token30min and resend limits match auth; resends supersede older codes.

POST /v1/me/email/verify {change_token,code} synchronously verifies and
consumes the pending intent, checks current session/account and citext email
uniqueness, swaps email while retaining verification, queues a notice to
the old address, and revokes all other sessions in the same transaction.
Keep the verifying session; invalidate account/session projections and
close revoked sockets through prompt06's durable revocation path. Concurrent
claims for the address have one winner; replay cannot send notices twice.
Notice payload is protected and not copied to audit. Google association
remains bound to its provider subject, never relinked from the new email.
Add a scoped resend route/intent contract after review; signup tokens must
not authorize an email swap.

Reuse implemented /v1/me/password, Google start intent=link, DELETE
/v1/me/google, /v1/auth/logout and /logout-others. Preserve last-sign-in-method
checks, OAuth state/PKCE and password verification/revocation semantics.
Google-only accounts need an explicit proved local-password setup flow if
the UI offers "add password"; the current current_password contract must
not be bypassed with an empty string. Do not claim that new flow exists.

Reuse prompt07's per-kind in-app/email preference API, defaults and grouped
switch mapping. Weekly email stays off by default; Results/New season
switches must not enable additional email kinds implicitly. Atomic grouped
updates validate all values and audit/outbox once. Disable/cancel queued
delivery according to preference/deletion races, not only at enqueue.

### 3.3 Confirmed deletion and durable order drain

DELETE /v1/me {password|otp} requires the current password when present,
or a purpose-bound, rate-limited deletion OTP for Google-only accounts.
Introduce an authenticated deletion-OTP request, not reuse a password-reset
code or OAuth ID token. Do not log either proof. Verification failures
must leave account, orders and personal data unchanged.

After proof, commit DELETED/deleted_at, public tombstone/pseudonym,
account admission fence, all-session revocation, notification suppression,
durable cancel/erasure work, audit/outbox together. Revoke pending privileged
sessions/proofs and roles from effective authorization. A new order cannot
race through a cached session after this account fence. Preserve the
existing DELETED status rather than adding a sign-in-capable intermediate.
Clear core serving email/credentials/Google identity and pending identity
intents in this initial transaction; large histories/replicas then use the
durable cleanup receipts while already fenced from serving personal data.

Discover all markets with resting orders, PENDING places or open holds for
this account. Dispatch trusted account-scoped CancelAll concurrently with
a bounded pool, then await **all** results. The coordinator uses ordinary
exchange cancellation/ownership fencing, not a revoked player's API key or
raw deletes. Re-enumerate under the account fence and confirm no remaining
admissions/orders/holds; one failed market means drain is incomplete.
Holds/orders are not erased before their normal release journal commits.

Keep the request waiting for this bounded drain when practical. If it
cannot finish within the HTTP budget, return202 with an opaque deletion-job
receipt/progress token and resume durable work; never return completed
success just because tasks were spawned. Session access stays revoked.
The progress receipt grants only non-PII job status, not account access.
Final completion requires drain, erasure and cache invalidation receipts;
bounded cleanup tasks retry failures after disconnect/restart.

Positions, outcome wallets, orders/fills, claims/results and financial
identity IDs remain for integrity; payouts/refunds still credit the inert
account as prompt08 requires. Financial settlement must not filter it out
because notifications/sign-in stopped. No new sign-in, grants, notifications
or public profile may revive it. The display pseudonym is
deleted-<6 random>, collision-checked and reserved outside public signup
validation; its hyphen intentionally need not match the normal username
regex. Never relabel a real player's name by mutating historical journal.

### 3.4 Erasure, immutable history and required review

| Data | Treatment |
|---|---|
| Email/phone/password/Google subject and linked-email metadata | Erase immediately from serving identity/credential stores after proof; cancel pending identity changes |
| OTP/signup/OAuth pending intents, session IP/UA, device fingerprints | Revoke/erase identifying data; retain only minimal nonidentifying revocation facts required to deny old credentials |
| Username aliases/reservations/history and final name sidecars | Erase identifying names; tombstone public projections; prevent old cached aliases serving deleted profile |
| Notifications/preferences/unsubscribe links/pending mail | Suppress first, erase history/preferences/tokens and queued personal payloads; do not send deletion-time trade/payout notices |
| Public trades/standings caches and replicas | Resolve stable account IDs through current deletion/identity overlay; remove from public ranks, render deleted account where attribution remains |
| Ledger/wallets/fills/orders/settlement claims/results | Retain IDs, amounts, provenance and reconciliation evidence; avoid embedded names/email in their immutable payloads |
| Governance audit/approval facts | Retain minimal integrity core; display actor as deleted account; remove erasable identity/IP/free-text material through the private sidecar policy |
| Exports/logs/email-provider copies/backups | Inventory, purge/revoke where supported, document restoration/tombstone replay and residual retention; not silently covered by a DB DELETE |

If an old-name reservation still needs its remaining anti-impersonation
period after deletion, retain only a keyed namespace claim/expiry needed
to refuse reuse, not a public alias or recoverable name history. Review
its retention/linkability explicitly; do not silently release the promised
reservation or call a hash automatically anonymous.

New immutable audit/financial facts must not contain erasable raw identity
inside arbitrary detail JSON. Put actor display names/IP/UA and necessary
personal attachments in access-controlled erasable sidecars or separately
encrypted envelopes. Keep a stable nonpublic actor ID/integrity reference
in the immutable core. Audit's requested ip field is an authorized joined
projection, not a promise that plaintext IP can remain forever while also
being erased. Apply deletion redaction to generated audit CSVs/downloads.

Existing audit rows already contain plaintext IP/UA/detail and other
historical rows may embed identity. Preflight must inventory these fields;
no unapproved bulk rewrite or claim of complete erasure is made. Their
one-time migration, retained legal/integrity basis, scope and access policy
need explicit privacy approval before this erasure promise can ship.

Review retention, lawful basis, rights handling, processors/exports/backups,
stable-ID linkability and redaction against Nigeria's data-protection law
with privacy/legal owners. Reference the official
[Nigeria Data Protection Act source](https://ndpc.gov.ng/download/nigeria-data-protection-act-2023).
This is a required review item, not a legal-compliance determination.

## 4. Approvals, audit, roles and staff authentication

### 4.1 One append-only approvals inbox

Prompt10 supersedes earlier mutable approval facts. approvals contains
immutable request identity/kind/subject/revision/hash/requester/reason/time/
expiry/slot. Append approval_decisions for approve/reject and
approval_transitions for stale/expiry/application facts. Mutable
approval_state is only a CAS projection/version pointer, like resolution's
projection/history split; a view exposes current status/decider/time to
earlier consumers. Revoke UPDATE/DELETE/TRUNCATE on all fact tables.
Migration preserves original request/decision provenance, including legacy
issuance self-votes; do not invent compliant requesters or discard history.
Represent potentially personal request/decision reasons and notes through
erasable sidecar references; the immutable core keeps their integrity
reference and structured decision, not arbitrary identifying free text.

| Kind | Authorized independent decider / required threshold |
|---|---|
| market_open | curator or super_admin; one, never requester |
| liquidity, bot_topup | treasury or super_admin; one, never requester |
| bot_season_budget | treasury or super_admin; preserve prompt09's two distinct non-requester votes |
| issuance_policy | super_admin; two distinct non-requester votes |
| void_shortfall | super_admin distinct from requester and the void finalizer; exact frozen manifest binding |
| role_grant | super_admin distinct from requester; one, exact target/role/current subject binding |

The actor's *current* role and recent TOTP are checked inside the decision
transaction. Self-rejection is also forbidden by the universal non-self
rule. Slot uniqueness and distinct-decider constraints prevent voting
twice in a two-person round. One vote is not effective funding authority.

GET /v1/admin/approvals?status=pending|decided&kind=&cursor= returns bounded
keyset items with subject-derived title/detail, requester username/role,
time, can_decide/reason, subject_link and payload_hash plus version/expiry.
Exact self-request copy: "You asked for this, so someone else has to approve
it." can_decide is a UI hint, never authorization for a later POST.

POST .../{id}/approve {payload_hash,note?} and /reject {payload_hash,reason}
must also carry an expected version/If-Match or equivalent single-use
pending-decision CAS. Lock current subject and projection; validate
unchanged hash, current policy/role/MFA, slot, expiry and undecided status.
Return STALE_APPROVAL on changed subject/hash/expired request. Compare the
caller hash with both immutable request **and current subject**, not merely
two copies of an old hash. Race winners append one decision/audit/outbox;
losers get the existing same-request result or a typed conflict, no new vote.

Pending requests expire at requested_at+7days, using business time. The
sweeper appends stale transitions and CASes projections; decision handlers
enforce the deadline even if the sweeper is late. Expiry never revokes an
already applied standing policy or refunds an applied allocation.

approval.decided is durable in the same transaction. Subject owners consume
it through durable receipts keyed by approval/round/hash and recheck their
own lifecycle/aggregate threshold before applying once. Atomic local store
composition may apply the subject in the decision transaction; otherwise
durable continuation retries. "Approved, applying" is distinct from market
OPEN, cash funded or void refunds sent. A subject changed or became
ineligible after approval needs its explicit stale/compensating workflow,
not blind execution from delayed events. Consolidate prompt09 subject
decision endpoints into these shared commands; no alternate bypass path.

**Season-grants decision, fixed by this prompt:** the existing two-person
standing player issuance policy covers ordinary new-season grants. Show
"Covered by policy P-1, approved by tobi.o and ada.ops" with real provenance.
The "Season02 starting balances" card is pending only for an amount/cap
policy change; a new season does not require a click or a fabricated
approval. The eligibility/grant ledger remains authoritative.
Titles/previews use current subject data and declared as_of; e.g. a top-up
of25000 moves502000→527000 of750000, but final apply recomputes constraints.

### 4.2 Audit consistency, query and CSV

Core audit schema: id,actor_id,actor_kind(player/staff/bot/system),
role_at_time,area(Money/Markets/Resolution/Bots/Access),action,target_type,
target_id,detail,links,created_at and erasable private-data reference.
Use actual service/DB identity; clients cannot choose actor_kind or role.
Links identify immutable ledger transactions, terms revisions and approvals.
Allowlist details by action; never put passwords, OTPs, tokens, TOTP seeds,
API keys or provider bodies in them. Retain unknown legacy roles as unknown,
not a guessed current role retroactively applied to old events.

Privileged decisions, settings swaps, deletion/role/MFA changes, and money/
market transitions commit their audit with the mutation and outbox. A failed
audit insert rolls back that command. Current lossy auth logging may remain
explicit best-effort diagnostics for nonmutating attempts, but is not the
governance trail. Migrate relevant auth mutation paths off that channel;
performance results from a lossy login log do not prove a durable path.

Application role has INSERT/SELECT only on audit facts, no UPDATE/DELETE/
TRUNCATE. Make default grants and sidecar cleanup privileges explicit.
GET /v1/admin/audit filters area,actor,target_type,target_id,from,to and
limit(default50/max100), keyset on descending(created_at,id), with an opaque
bound-filter cursor. Newer inserts cannot shift completed pages. Do not
claim cross-page snapshot consistency for late/backdated commits from this
ordering alone; exports capture an explicit set. Add requested indexes
with id as deterministic suffix, and actor/time index as measured.

Proposed read/export permissions: admin/super_admin can inspect all areas;
treasury can inspect Money/Bots plus approvals within its capability;
curator/resolver receive their authorized Market/Resolution scope only if
review approves it. No creator/player/bot access. Restrict IP/private-sidecar
visibility separately and audit export requests/downloads.

POST /v1/admin/audit/export {filters} validates scopes/limits, creates a
durable job and returns202/job identity. A bounded spawned worker first
captures a consistent event-ID manifest in a transaction, then writes
bounded CSV chunks from those immutable facts. Crash retries use the same
manifest; no new inserts appear halfway through the export. Apply current
privacy redaction and revoke/regenerate affected artifacts on deletion.
Escape CSV quoting/newlines and spreadsheet formula-leading untrusted text.

Artifact storage is a private port; do not assume an S3 SDK. Return a
short-lived opaque app download link bound to requester/job, with current
session/role authorization on every download. A public bearer URL whose
contents cannot be revoked would defeat immediate role/deletion controls.
Bound rows/bytes/runtime/retention, cleanup files, record checksum/count
and expose failed/retry state. Rehearsal compares export with its manifest.

### 4.3 Role requests, immediate revocation and caches

POST /v1/admin/roles {username,role,reason} resolves a stable target account
ID and current target revision. creator may be granted directly by curator
(proposed also super_admin). curator/treasury/resolver/admin/super_admin
create role_grant approval requests; request capability is itself authorized,
proposed curator for creator management and super_admin for staff roles.
No role activates merely because a request exists. Recheck target ACTIVE,
human classification, target/hash and independent approver at apply time.

DELETE /v1/admin/roles {username,role,reason} is synchronous and immediate,
without approval. Proposed revoker scope is super_admin for all roles,
curator for creator only. Advance authz_version, record audit/roles.changed,
invalidate step-up proofs/caches and trigger eligibility/house-group effects.
An outstanding role_grant for the revoked target/role is staled/fenced;
a delayed old approval cannot silently restore the role. Preserve an
operable super-admin recovery policy; review last-admin/self-revoke handling
before shipping, without delaying emergency removal for a routine approval.

Role cache stores versioned grants, not permanent permission. **Events
alone cannot guarantee next-request revocation** on another node during
delay/Redis outage. For staff endpoints, read authoritative account/session/
authz version each request and use the cached roles only if versions match;
fail closed on authority failure. Mutations hold an account authorization
share guard through commit; revocation takes its exclusive guard, so the
linearization boundary is explicit. Acquire these guards in a single
documented order before subject/treasury/wallet locks (after season when
required); re-read hash/state under those same transaction guards.

Public fast read models can update eligibility through their generation/
tombstone channel; they must report/fence stale privacy state rather than
pretend a thirty-second recompute is immediate. House-group changes follow
prompt09's PENDING/resting-order fencing. Creator alone remains outside
house under the proposed staff definition. Update CLI/operator paths too:
the current direct grant_role helper cannot remain an unauthenticated
governance bypass. First-operator bootstrap/recovery is a separate explicit
audited operational procedure, not a general HTTP exception.

### 4.4 Enrolled TOTP and twelve-hour step-up

Staff must enroll before **any** staff action. Actions listed by the prompt
also require verified TOTP within the previous12h on the same current
session: all approval decisions; finalize/void/dispute decisions; pause-all;
clear halt; role changes; all treasury writes. Use authorize() for every
request; settings enrollment remains reachable for a newly appointed staff
member who has not yet enrolled. Other staff actions require enrollment,
not an invented universal12h challenge rule.

Use the algorithm and vectors in [RFC6238](https://www.rfc-editor.org/rfc/rfc6238.txt).
Proposed parameters: HMAC-SHA256,32-byte random secret,T0=0,30-second step,
six display digits. Native hmac_sha256/rand support these primitives; test
the RFC's eight-digit SHA256 vectors as well as configured six-digit output.
Validate the provisioning metadata against supported authenticator clients
before promising interoperability. Implement/test Base32 if needed; no
encoding.base32 or crypto.totp API currently exists.

POST /v1/me/2fa/enroll creates a short-lived pending encrypted seed and
returns provisioning material once over TLS/no-store; it does not activate
2FA until verified. /verify {code,enrollment_id?} either confirms enrollment
or records a step-up on an already enrolled account/session. /disable needs
a fresh current code, clears all MFA proofs and blocks staff actions until
re-enrolled; it does not silently revoke the role or grant password access.
Never return the stored seed on later GETs or include it in audit/metrics.

Default verification accepts current step and one preceding step for delay,
with explicit clock-skew policy. Atomically consume accepted time counters
to reject replay across nodes/sessions; bound attempts by account/IP and
rate-limit enrollment/disable too. Store last accepted counter and secret
version. A step-up receipt binds session ID/account/authz/secret versions,
not a browser boolean or reusable code. Credentials/role/MFA changes and
session revocation invalidate it; exactly12h elapsed is expired. Do not
silently extend proof lifetime on ordinary staff requests.

The seed must be recoverable for verification, so password hashing cannot
replace encryption. Require a vetted authenticated-encryption/KMS adapter
before implementation: envelope/key version plus authenticated account/
secret identity, key outside the database, documented rotation and access.
No verified local AEAD API exists; block production enrollment until an
actual adapter and decrypt/tamper/rotation tests pass. Base64/XOR/handmade
encryption is not an alternative. Read settings/key identifiers once in
platform/config; do not log ciphertext/plaintext or claim GC gives secure
zeroization. Lost-device recovery/bootstrap is a reviewed runbook gate.

## 5. Jobs, clocks and launch rehearsal after review

| Work | Execution |
|---|---|
| Standings, approval expiry | Long-lived leader-locked tasks with durable generation/expiry receipts |
| Role/privacy cache listener | Bounded listener with authoritative version/gap recovery |
| Audit export and deletion cleanup | Durable jobs, bounded worker pools, leases/progress and retry |
| Profile independent reads | Spawn concurrently, join every result, validate privacy/generation |
| Deletion CancelAll fanout | Bounded concurrent dispatch, await all then confirm no exposure |
| Approval/role/username/email/TOTP state changes | Synchronous guarded CAS transactions with audit/outbox |

Reuse top-level spawn/join, bounded channels and select send/default from
slang-notes. No native try_send, captured closures, automatic task restart
or cancellable join is assumed. A failed worker is supervised; durable work
survives process exit and Redis loss. Never hold a snapshot mutex over I/O.

### 5.1 Injectable clock audit

Every scheduler gets an injected clock; no production refactor happens
before this design review. Inventory timez.now()/SQL now(), expiry queries,
retention, OAuth/OTP limits, season boundaries, queue leases, resolution
windows, quote freshness, standings/approval timestamps and notification
jobs across all ten prompts. Ledger injection alone does not cover them.
Pass captured business time as a SQL value for semantic deadlines instead
of assuming an injected service clock changes database now().

Separate clock purposes: compressed business time for seasons/market dates/
disputes/rename windows/approval expiry; injectable security UTC for OTP,
TOTP/session/step-up proofs; real monotonic time for I/O deadlines, worker
leases and performance. Security time stays synchronized to authenticator
Unix time; it need not accelerate with a fourteen-day season. Test clocks
can control each independently. Network faults and latency benchmarks use
real elapsed time, so a scaled clock cannot fake a passing latency metric.

Verified timez.Clock exposes now,advance,set; it has no wakeable scheduler
method. Inject scheduler wake/clock-generation notifications separately,
or bounded re-evaluation, so advancing a fake clock does not leave tasks
sleeping fourteen real days. Cross-node staging clock changes carry an
epoch and acknowledgement barrier before assertions. Never expose time
override/dev-email-OTP interfaces in production or via public user input.

### 5.2 Rehearsal scenario and acceptance

tools/rehearsal, after all dependencies are implemented, targets a staging
stack: PG,Redis,two app nodes,bot runners and gateway; pinned timezone/data/
versions/seeds and recorded clock mapping. No production funds/accounts.

1. Sign up1000 simulated players through real auth/verified OTP flows,
   using only the staging dev mail capture. Staff separately enroll TOTP
   and exercise independent approvals; clocks cannot bypass that protocol.
2. Run two full compressed seasons;50 markets traverse create/approve/fund/
   open, bots quote, players trade/cancel/dispute. Include two voids and one
   changed outcome with its fresh30-minute dispute window.
3. Close/drain, collect captured fixture evidence, propose, decide disputes,
   independently finalize, settle, sweep, reconcile and freeze season1.
   Season2 grants follow the approved standing policy and continue trading.
4. Kill an app node and verify owner takeover/replay; Redis down60 real
   seconds; add50ms PG latency for5 real minutes; pause all bots; halt then
   clear trading with authorized recent-TOTP actions. Record recovery and
   degraded periods, not just final success.
5. Verify every phase's money/share/hold/claim invariants, portfolio/standings
   vectors, frozen finality, approval/role/deletion races and duplicate
   logical effects/notification receipts. External email exactly-once is
   not implied by an outbox; report provider idempotency/uncertainty.

**Correct the supplied aggregate money check:** BOT_SWEEP is an internal
bot→treasury transfer, not destruction. Across all non-issuance SEDI owners
(players,bots,treasury,fees,collateral), including authorized negative
treasury balances, net cash equals total approved issuance credits (player
grants+BOT_FUNDING+any separately authorized issuance), with no sweep
subtraction. All journal entries including issuance sum to zero per asset.
For example, grants1000+bot funding500, allocation200 and later sweep200
leave player1000+treasury500=1500; subtracting that sweep would wrongly
report1300. Neither allocation nor sweep creates/destroys global cash.
If a report excludes treasury it needs an explicitly different flow
equation; do not make a correct sweep fail global conservation or count
allocated bot capital as an additional mint. Compare cash to journal and
portfolio total to cash **plus shared marked position value**, not cash
alone. During settlement use prompt08's phase-aware supply/collateral rules.

Record kernel§13.4 metrics and prior targets: offered/admitted/committed/
failed rates; request/admission/fill/cancel p50/p95/p99; actor scheduling,
PG/lock/commit, recovery/replay, outbox/stream delivery, queue/backpressure,
RSS/native buffers/GC and errors. Include the specified2000 offered orders/s
profiles,1000 hot-market watchers with commit→client p99<150ms, and the
separate10000-socket/30-minute endurance gate. The1000-player/50-market
rehearsal alone cannot substitute for those scale tests. Also measure
standings10000<2s, leaderboard warm p99<5ms, portfolio targets, settlement
10000<30s, bot stale pull≤1s/pause-all≤2s and explained notification timing.
Do not invent a missing numeric admission SLO; resolve remaining baseline/
hardware targets before treating a report as launch approval.

After an actual run, write docs/LAUNCH.md with measured results, environment,
fault timelines, seeds, failed/skipped gates and open risks. Write
docs/RUNBOOK.md for recon failure/halt, DEGRADED market, Redis/PG outage,
runaway bots, void/shortfall approval, key rotation, TOTP recovery and
deletion/export cleanup. Do not create passing evidence or claim launch
readiness during this design stage.

## 6. Migration and verification plan

Forward migrations add standing generations/runs/frozen rows and erasable
name refs; leaderboard_eligible and authz/privacy epochs; username history/
reservations/shared namespace and rename claims; bound email/deletion OTP
intents/jobs; append-only approval requests/decisions/transitions plus CAS
projection/application receipts; audit fields/indexes/private sidecars and
export manifests/jobs; encrypted pending/active TOTP seeds/counters and
session-bound step-up proofs. Preserve deployed history and current auth/
ledger constraints. No edits to applied SQL or startup schema changes.

Every server route uses auth.require_session for signed-in access, with
explicit authorization/MFA for staff routes; public profile/leaderboard
markers are deliberate. Optional personalized leaderboard context never
leaks to an anonymous/public cache. Register window/change/approval/TOTP/
role/clock/snapshot/privacy job errors; reuse known auth/not-found/conflict/
unavailable codes. Unexpected store details are logged, not client-visible.

Required post-review tests include:

- Random portfolios through shared valuation vectors, NO midpoint/cost
  fallback, realised sale/fees/holds, account settlement boundary, missing
  grants and identical generation equality. No second valuation fixture.
- Tie timestamps unchanged/changed/returned values, same-run ties, exact
  ratio ordering, five-settled threshold, neutral/sold-out/both outcomes,
  distinct calls, bots/staff/deletion and final identity-at-time behavior.
- Snapshot publication/takeover/cursors after100 ranks, pinned personal row,
  top20+1 arithmetic, percentile, cold/historical warmup and memory limits.
- Financial FINALIZED→single final freeze/event/notification; rank immutability
  through rename/deletion and public tombstone behavior under node/cache gaps.
- Rename exact window endpoints/once-per-season, concurrency with signup,
  namespace hold failure/expiry,30-day reservation/301 expiry/alias loops,
  historical name preservation and erasure.
- Email target-bound OTP/resend/uniqueness/replay, old-address notice exactly
  once at outbox intent level, other-session revocation and Google-subject
  stability. Existing password/Google/notifications/logouts regressions.
- Wrong/missing delete proof; every pending/resting order drained across
  markets, failures resume, no new admission after fence, sockets ended,
  personal stores/exports/cache invalidated, inert-account payouts preserved
  and final full reconciliation green.
- Self/hash/expiry/version/role/threshold approval checks, two concurrent
  votes, append-only raw-SQL enforcement, delayed subject continuation once,
  standing season policy without artificial fresh approval.
- Transactional audit rollback, read filters/keyset insertion behavior,
  frozen export manifest/checksum/CSV formula escaping and redacted downloads.
- Next-request revoke across two nodes with Redis unavailable, stale cached
  roles/proofs, pending regrant fencing and CLI/bootstrap coverage.
- RFC TOTP vectors, replay/rate/clock edges, secret ciphertext/tamper/rotation,
  same-session12h proof, disable/re-enroll and all named staff guards.
- Clock audit and cross-node advance/wake, real-time fault durations and
  rehearsal reproducibility; load gates require actual timing reports.

Design-stage baseline (2026-10-26): whitespace and independent arithmetic
checks passed for the supplied portfolio, top2%/#20 example and sweep
conservation. `zokor check` passed for the existing eighteen packages;
`make build` passed with existing generic-instantiation/OpenSSL warnings.
Required `make check` stopped at the existing
test_should_time_out_a_send_to_an_unreachable_provider: the sandbox returned
`dial 10.255.255.1: Operation not permitted` instead of a timeout. DB/Redis
integration and opt-in ledger load tests skipped without their settings.
These baseline checks validate no governance implementation or rehearsal.

## 7. Review decisions and consolidated open work

| Review | Proposed clarification / implementation gate |
|---|---|
| R1: Values | Reuse portfolio service/vectors, declare shared snapshots and live-versus-ranked profit age |
| R2: Calls | One distinct market; review last-directional stance/neutral/both-outcome handling before wins/profile implementation |
| R3: Ranking | Complete sort tie rules, observed reached_at, +1 to pass #20 and full in-memory pagination rows |
| R4: Finality | Separate financial/table-final stages, one notification, immutable ranks plus erasable identity and public rank gaps |
| R5: Identity | First72h rename window, common durable namespace, finite301, target-bound email changes |
| R6: Deletion | Confirmed durable drain/erasure receipts, inert financial rights, legacy-PII inventory and cache-revocation delay review |
| R7: Approvals | Append-only facts/CAS projection replace prior mutable contracts; two-vote bot cap/issuance preserved |
| R8: Roles | Explicit revoker/requester matrix, current authority check, transaction fence and bootstrap/last-admin recovery |
| R9: Staff MFA | Session-bound enrolled/recent TOTP, verified SHA256 provisioning and real AEAD/KMS adapter gate |
| R10: Launch | Injectable separated clocks, corrected all-owner conservation, implemented dependencies and measured gates before readiness |

Consolidated assumptions/TODO register for all ten prompts, to be resolved
and reported again with actual implementation/rehearsal evidence:

| Area | Existing design / outstanding gate |
|---|---|
| 01 Auth | docs/auth notes/API; settings extensions, durable mutation audit, cross-node revocation, clock refactor and provider/runtime load limits |
| 02 Ledger/seasons | Existing ledger is authoritative; generic approval cutover, phase guards, finalized scheduler wiring, cap/recon/load gates |
| 03 Registry | docs/markets/DESIGN.md review decisions; actual layered feature, immutable terms/source/operator workflows, opening price and funding integration |
| 04 Matching | docs/exchange/MATCHING.md review decisions; representations/compiler probes, deterministic golden/replay/fuzz/reference parity and measured performance |
| 05 Runtime | docs/exchange/RUNTIME.md review decisions; durable admission/owner fencing, complete hold/position/recon contracts, snapshots and CancelAll extensions |
| 06 Stream | docs/stream/STREAM.md review decisions; writer/queue/framework hooks, privacy/revocation, shard/Redis capacity, client mirror and genuine socket benchmarks |
| 07 Portfolio/notices | docs/portfolio/DESIGN.md review decisions; coherent reads/shared valuations, final-results/call mapping, preferences and provider delivery uncertainty |
| 08 Resolution | docs/resolution/DESIGN.md review decisions; real source fixtures/collector boundaries, independent decisions, manifests/refunds/approvals and season eligibility for never-opened markets |
| 09 Treasury/bots | docs/bots/DESIGN.md review decisions; market cash/risk enforcement, treasury commitments/shortfall financing policy, outbound client/key scopes, runner leases and simulations |
| 10 Governance | This R1–R10; privacy/retention and legacy erasure decision, MFA key adapter/provisioning, role recovery, all-owner rehearsal ledger checks and launch/runbook reports |

These are proposed dependency/review gates, not completed modules or a
fresh reopening of the already decided void policy. After review implement
shared contracts/migrations and clocks, projections/settings/governance,
then meaningful correctness/fault/performance checks and finally the full
staging rehearsal. Final assumptions/open TODOs and launch evidence are
delivered after those stages; this turn stops at this document.
