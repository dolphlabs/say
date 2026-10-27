# Ledger, wallets and seasons: design

Status: **reviewed 2026-10-20 and implemented** (prompt 02). Sections 1–4
follow the prompt. Section 5 records the decisions taken at review. Section 6
lists where this design departs from the spec docs or from prompt 01's code.
Section 7 lists what changed while it was being built.

The money layer has one rule above the others: **every sedi and every
share moves only through `ledger.post`**. Everything else in this document
exists to make that rule enforceable, fast under concurrency, and
checkable afterwards.

---

## 1. Seasons

### 1.1 Clock maths (pure, `src/ledger/domain/season.sl`)

- `SEASON_ANCHOR` (config, RFC 3339; default `2026-10-11T23:00:00Z`, which
  is Mon 12 Oct 2026, 00:00 WAT) and `SEASON_DAYS` (fixed at 14 by the
  table CHECK; not configurable).
- Season N spans `[anchor + (N-1)·14d, anchor + N·14d)` in UTC. The
  ordinal for an instant `t ≥ anchor` is `floor((t − anchor) / 14d) + 1`.
  Before the anchor there is no season.
- Arithmetic is in whole seconds on `timez.Time`. Lagos has no daylight
  saving, so 14 days is always 1,209,600 s. The maths does not rely on that:
  boundaries are pinned to the anchor instant, and the zone is used only for
  display.
- Display and "day 7 of 14" use `timez.load_zone("Africa/Lagos")` (the
  system tz database). The day is `lagos_date(now) − lagos_date(starts_at) + 1`,
  clamped to `1..14`. Nothing adds `+01:00` by hand. The zone is loaded once
  at startup, and a missing tz database fails startup.
- Every function takes `now` as an argument. The scheduler and the
  endpoints read it from a `timez.Clock`, and tests use `fixed_clock`.

### 1.2 Table

```sql
seasons (
  id            uuid PK,
  ordinal       bigint UNIQUE NOT NULL CHECK (ordinal >= 1),
  starts_at     timestamptz NOT NULL UNIQUE,
  ends_at       timestamptz NOT NULL,
  status        text NOT NULL CHECK (status IN
                  ('SCHEDULED','ACTIVE','CLOSING','CLOSED','FINALIZED')),
  activated_at  timestamptz,
  closed_at     timestamptz,
  finalized_at  timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at = starts_at + interval '14 days')
)
UNIQUE INDEX seasons_one_active ON seasons ((true)) WHERE status = 'ACTIVE'
```

The partial unique index makes "at most one ACTIVE" a database fact. "At
least one" comes from doing the hand-over in a single transaction (§1.3).

### 1.3 Transitions

Each transition is a compare-and-set `UPDATE seasons SET status = $to, <at> = $now
WHERE id = $id AND status = $from`. Zero rows updated means another instance
already did it, which is the no-op case.

| From → To | Fires when (`now` from the clock) | Same transaction also |
|---|---|---|
| SCHEDULED → ACTIVE | `now ≥ starts_at` | creates the season's system wallets and issuance budget (§2.2); inserts outbox `season.started` |
| ACTIVE → CLOSING | `now ≥ ends_at` | inserts outbox `season.closing` |
| CLOSING → CLOSED | no `open` hold in the season | inserts outbox `season.closed` |
| CLOSED → FINALIZED | `settlement_complete(season)` is true | inserts outbox `season.finalized` |

- **Hand-over at a boundary.** Season N's `ends_at` equals season N+1's
  `starts_at`. One transaction moves N to CLOSING and N+1 to ACTIVE, in
  that order, so the one-active index never sees two and there is no gap.
- **The rollover grant job** starts after that transaction commits (§2.4).
  Its progress row is inserted in the same transaction, so a crash between
  the commit and the job's start is picked up on the next tick.
- **The next season** is created as SCHEDULED as soon as a season becomes
  ACTIVE, which is 14 days ahead of the 24 h requirement. Every tick also
  re-ensures it with `INSERT … ON CONFLICT (ordinal) DO NOTHING`.
- **`settlement_complete(season)`** returns `(false, "market settlement
  arrives in prompt 08")` for now.
- **Postings and the hand-over.** Kinds that need an ACTIVE season take
  `SELECT status FROM seasons WHERE id = $1 FOR SHARE` (§4.3). An
  ACTIVE → CLOSING update therefore waits for in-flight postings to commit,
  and later postings see CLOSING. No hold can slip in after the
  `season.closing` sweep has started.

### 1.4 Scheduler

- **One long-lived spawned task.** It sleeps until the next boundary or 60 s,
  whichever is sooner. On waking:
  - it acquires a dedicated connection (`pg.acquire`);
  - it calls `pg_try_advisory_lock(LOCK_SEASONS)`. If it doesn't get the
    lock, it releases the connection and sleeps again;
  - with the lock, it applies every overdue transition in order, oldest
    season first, then `pg_advisory_unlock` and release.
  - On any error the connection is closed rather than released, so a
    session lock can never go back into the pool.
- **Catch-up on boot** is the same loop run at once. Every transition is a
  compare-and-set, so repeating it is harmless.
  - If seasons are missing (first boot, or a long outage), they are created
    from the anchor up to the current one plus one.
  - Fully missed seasons walk through ACTIVE and CLOSING immediately
    (decision D4).
- **Alert.** Every instance, with or without the lock, checks each tick for a
  boundary that passed more than 2 minutes ago without its transition:
  - a SCHEDULED season with `starts_at < now − 2m`;
  - an ACTIVE season with `ends_at < now − 2m`.

  It logs the miss as critical and increments `season_transition_late`.
- **Every transition** logs `season <ordinal> <from>→<to>` and increments
  `season_transitions_total{to}`.

---

## 2. Season grants

### 2.1 Policy (two-operator issuance authority)

```sql
issuance_policies (
  id            uuid PK,
  amount        bigint NOT NULL CHECK (amount > 0),          -- 1000
  season_cap    bigint NOT NULL CHECK (season_cap >= amount), -- e.g. 10,000,000
  status        text NOT NULL CHECK (status IN ('PROPOSED','APPROVED','REVOKED')),
  proposed_by   uuid NOT NULL REFERENCES accounts(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  approved_at   timestamptz,
  revoked_at    timestamptz
)
UNIQUE INDEX issuance_policies_one_approved ON issuance_policies ((true)) WHERE status = 'APPROVED'

issuance_policy_approvals (legacy history, read-only after migration 009)
  policy_id     uuid REFERENCES issuance_policies(id),
  operator_id   uuid REFERENCES accounts(id),
  approved_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (policy_id, operator_id)
)
```

- **Approval** uses two immutable requests in the shared approvals workflow,
  bound to the policy's canonical payload hash. Two distinct `super_admin`
  accounts other than the proposer must approve. The second approval flips
  the policy to APPROVED and revokes the previous one in the same transaction.
  Migration 009 preserves legacy votes in their original table, excludes
  proposer self-votes from the threshold, and resumes eligible pending policies
  without fabricating historical request or decision timestamps.
- **The CLI** is `bin/say admin issuance-policy propose|approve|show`
  (decision D6). Decisions are recorded in shared append-only approval facts
  and `audit_events`; the old approvals table is retained for read-only history.
- **Fail-closed.** `grant_season_allowance` and the rollover job read the
  single APPROVED policy. Without one they fail with `PolicyMissing`, and
  the rollover job raises an alert and retries next tick.
  - **During verification** a missing policy must not block sign-up. The
    account is verified with no grant, and the rollover job's next pass
    covers it once a policy exists, because the job also re-runs for the
    active season whenever a policy is approved (§2.4).
- **The amount** comes from the policy. The `SEASON_GRANT_AMOUNT` setting
  from prompt 01 is removed.

### 2.2 Exact cap without a hot row

Checking the cap with `count(*)` over grants is slow and racy. A single
"remaining budget" row is exact, but it is the same hot row the prompt warns
against for `system:issuance`. So the cap is split across shard rows:

```sql
issuance_budget (
  season_id   uuid REFERENCES seasons(id),
  shard       smallint CHECK (shard BETWEEN 0 AND 15),
  remaining   bigint NOT NULL CHECK (remaining >= 0),
  PRIMARY KEY (season_id, shard)
)
```

- **Seeding.** On activation the 16 rows are seeded in **whole grants**:
  the cap allows `cap / amount` grants, each shard gets an equal share and
  the first shards take one extra each. A shard never holds part of a grant,
  so no grant can fail on a shard that is short by less than one. The rows
  are also seeded lazily by the first grant of a season that has none.
- **A single grant** runs:
  ```sql
  UPDATE issuance_budget SET remaining = remaining - $amount
   WHERE season_id = $1 AND shard = $2 AND remaining >= $amount
  RETURNING remaining
  ```
  on shard `hash(account_id) % 16`. If that shard is short, it tries the
  next. A short shard is not locked, so a grant holds at most one budget
  row. **A rollover chunk** takes shards in ascending order, so two chunks
  never wait on each other in a cycle.
- **The budget is taken last**, after the posting, just before COMMIT, so
  a shard row is locked only for that one statement and the commit.
- **Cap reached** means no shard has `amount` left. The grant fails with
  `CapReached` and posts nothing. The rollover job stops, emits
  `issuance.cap_reached` (an alert), and logs critical. Verification goes
  ahead without a grant, and the response's `grant` is null.

### 2.3 Idempotency

```sql
issuance_grants (
  account_id    uuid REFERENCES accounts(id),
  season_id     uuid REFERENCES seasons(id),
  amount        bigint NOT NULL CHECK (amount > 0),
  policy_id     uuid NOT NULL REFERENCES issuance_policies(id),
  business_key  text NOT NULL UNIQUE
                REFERENCES ledger_transactions(business_key) DEFERRABLE INITIALLY DEFERRED,
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, season_id)
)
```

`grant_season_allowance(c, account_id, season_id)` runs in the caller's
transaction and is never spawned:

1. `SAVEPOINT`, then `INSERT INTO issuance_grants … SELECT … FROM accounts
   WHERE <eligible> ON CONFLICT DO NOTHING RETURNING account_id`. The
   eligibility check and the claim are one statement. If no row comes back
   the account is ineligible or already granted, and nothing is posted.
   Two racing callers serialise on the primary key: the second waits for
   the first to commit, then gets no row back.
2. Post the `SEASON_GRANT`s (`system:issuance` −amount, user +amount free),
   business key `grant:{season_id}:{account_id}`, in one `post_many`.
3. Take the budget (§2.2). If it funds fewer grants than were claimed,
   `ROLLBACK TO SAVEPOINT` and redo the claim for only as many as it can
   fund; if it funds none, nothing is posted and the result says the cap
   is reached. The caller's own transaction (a verification) goes on.

Verification and the rollover use this one function (`grant_accounts`):
with one id and with a chunk of 500.

The foreign key from `business_key` is deferred, so the claim row can come
before the ledger transaction it names. A claim without its posting cannot
commit.

### 2.4 Rollover job

- **Eligible accounts:** `kind = 'USER'`, `status = 'ACTIVE'`,
  `email_verified_at IS NOT NULL`, `deleted_at IS NULL`. Bots
  (`kind = 'BOT'`, added in this prompt) and system accounts are never
  granted.
- **One run per season:**
  ```sql
  grant_runs (
    season_id        uuid PK REFERENCES seasons(id),
    last_account_id  uuid,        -- every eligible id <= this is done
    granted          bigint NOT NULL DEFAULT 0,
    skipped          bigint NOT NULL DEFAULT 0,
    started_at       timestamptz NOT NULL DEFAULT now(),
    finished_at      timestamptz,
    halted_reason    text
  )
  ```
- **Shape.** One producer and N workers (`GRANT_WORKERS`, default 4), all
  holding a session advisory lock `LOCK_GRANTS(season)` on the producer's
  connection.
  - The producer keyset-paginates the eligible ids (`id > $cursor ORDER BY
    id LIMIT 500`). It sends each chunk `(lo, hi)` on a bounded
    `chan[Chunk]` of capacity N, and parks when the channel is full.
  - Each worker grants its chunk in **one transaction**: `grant_season_allowance`
    for each account, then `UPDATE grant_runs SET granted = granted + g,
    skipped = skipped + s`.
- **The cursor.** Workers finish out of order, so a worker reports
  completion on a second channel. The producer advances `last_account_id`
  only to the highest contiguous finished chunk. After a crash, at most N−1
  finished chunks are redone. Redoing one is harmless (step 2 above) and
  only adds to `skipped`.
- **Finish.** When the producer runs out of ids it closes the chunk
  channel, waits for the workers with `join_wait`, and sets `finished_at`.
  `granted` is recomputed from `issuance_grants`. It writes the summary to
  the log and emits `season.grants_done {season, granted, skipped,
  duration_ms}`.
- **Never one task per account.** Exactly 1 + N tasks run.
- **Throughput estimate.** About 6 statements a grant, so 100k accounts is
  about 600k statements over 4 connections. That is under a minute locally
  if a round trip costs about 0.1 ms. I'll measure it. If it misses the
  2-minute target, I'll replace the per-account calls with a set-based
  `grant_chunk` in the ledger store, under the same rules, and test it
  against the per-account path.

---

## 3. Chart of accounts and wallets

### 3.1 Assets

| `asset_key` | Meaning |
|---|---|
| `SEDI` | the currency |
| `YES:{market_uuid}` / `NO:{market_uuid}` | outcome shares; the UUID is lowercase and canonical |

The format is checked in the domain, by `parse_asset_key`, and by a table
CHECK: `asset_key = 'SEDI' OR asset_key ~ '^(YES|NO):[0-9a-f-]{36}$'`.

### 3.2 Wallets

```sql
wallets (
  id          uuid PK,
  season_id   uuid NOT NULL REFERENCES seasons(id),
  owner_kind  text NOT NULL CHECK (owner_kind IN ('user','bot','system')),
  owner_id    text NOT NULL,      -- account uuid, or 'system:issuance' etc.
  account_id  uuid REFERENCES accounts(id),
  asset_key   text NOT NULL,
  free_units  bigint NOT NULL DEFAULT 0,
  held_units  bigint NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (season_id, owner_id, asset_key),
  UNIQUE (id, season_id),                       -- target of entries' composite FK
  CHECK ((owner_kind = 'system') = (account_id IS NULL)),
  CHECK (owner_kind = 'system' OR owner_id = account_id::text),
  CHECK (owner_kind = 'system' OR (free_units >= 0 AND held_units >= 0)),
  CHECK (owner_kind <> 'system' OR (free_units = 0 AND held_units = 0))
)
INDEX wallets_account ON wallets (account_id, season_id) WHERE account_id IS NOT NULL
```

`owner_id` is a single text key, so the lock order is one total order over
users, bots and system owners. `account_id` keeps referential integrity for
users and bots.

### 3.3 System owners

They are created per season at activation (§1.3), or per market by
`open_market_wallets` (prompt 03/05 calls it):

| `owner_id` | Asset(s) | Purpose |
|---|---|---|
| `system:issuance` | SEDI | debited by every grant and bot budget; its negative balance is the sedi supply |
| `system:fees` | SEDI | credited S 1 per order on first fill |
| `system:treasury` | SEDI | funds bot budgets (approved allocations, prompt 09) |
| `system:collateral:{market}` | SEDI | locked collateral for issued pairs |
| `system:shares:{market}` | `YES:{market}`, `NO:{market}` | issue and burn counterparty for mint and merge |

A posting never creates a system wallet. A missing one fails with
`WalletNotFound`, which is a programming error.

### 3.4 Hot accounts

- **System wallets keep no cached balance.** Their `free_units` and
  `held_units` stay 0, enforced by the CHECK above. Posting to them only
  inserts an entry: no `UPDATE`, and no row lock.
  - A grant and a fill therefore never queue behind `system:issuance` or
    `system:fees`.
- **Their balance is `sum(delta)` over their entries.**
  - The aggregator (§4.6) keeps `system_balances` at most 10 s stale for
    dashboards.
  - Exact values come from the reconciliation scan.
- **User and bot wallets keep cached `free_units` and `held_units`,**
  updated under a row lock. The CHECK makes a negative balance impossible at
  commit time.

Test 4 measures this: 5,000 parallel grants against the insert-only path,
and against a deliberately locking variant that does `SELECT … FOR UPDATE`
on the issuance wallet first.

### 3.5 Season isolation, structurally

Entries carry `season_id` and reference `wallets(id, season_id)` and
`ledger_transactions(id, season_id)` through composite foreign keys. An
entry whose wallet belongs to another season **cannot be inserted**: the
constraint fires, not just the trigger. `post` also checks it first, so the
caller gets `SeasonMismatch` rather than a foreign-key error.

---

## 4. Posting

### 4.1 Tables

```sql
ledger_transactions (
  id            bigint GENERATED ALWAYS AS IDENTITY PK,
  public_id     uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),  -- the TxId the API exposes
  business_key  text NOT NULL UNIQUE,
  kind          text NOT NULL CHECK (kind IN ('SEASON_GRANT','ORDER_HOLD','ORDER_RELEASE',
                  'FILL','FEE','MINT','MERGE','PAYOUT','BOT_FUNDING','ADJUSTMENT')),
  season_id     uuid NOT NULL REFERENCES seasons(id),
  market_id     uuid REFERENCES markets(id),
  ref_type      text,
  ref_id        text,
  payload_hash  bytea NOT NULL,               -- sha256 of the canonical payload (§4.4)
  metadata      jsonb NOT NULL DEFAULT '{}',
  xid           xid8 NOT NULL DEFAULT pg_current_xact_id(),
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, season_id)
)
INDEX ledger_tx_xid ON ledger_transactions (xid)

ledger_entries (
  id              bigint GENERATED ALWAYS AS IDENTITY PK,
  transaction_id  bigint NOT NULL,
  season_id       uuid NOT NULL,
  wallet_id       uuid NOT NULL,
  asset_key       text NOT NULL,
  bucket          text NOT NULL CHECK (bucket IN ('free','held')),
  delta           bigint NOT NULL CHECK (delta <> 0),
  free_after      bigint,                     -- user/bot wallets only
  held_after      bigint,
  created_at      timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (transaction_id, season_id) REFERENCES ledger_transactions(id, season_id),
  FOREIGN KEY (wallet_id, season_id)      REFERENCES wallets(id, season_id)
)
INDEX ledger_entries_tx     ON ledger_entries (transaction_id)
INDEX ledger_entries_wallet ON ledger_entries (wallet_id, created_at DESC, id DESC)
```

- **`free_after` and `held_after`** are the wallet's balance after the
  whole transaction, the same on every entry of that wallet in it. The
  Activity tab reads them directly.
- **The id is a bigint now.** `ledger_transactions.id` becomes a bigint
  identity, which keeps index entries small and keyset paging cheap. The
  public id is a separate `public_id`.
  - `fills.journal_id` and `settlement_claims.journal_id` are re-typed to
    match. Both tables are empty.

### 4.2 Restricted role

- **The migration** creates the `say_app` role (NOLOGIN) if it doesn't
  exist.
  - `ledger_transactions`, `ledger_entries`: `SELECT, INSERT` only. No
    UPDATE, DELETE or TRUNCATE.
  - Every other table: `SELECT, INSERT, UPDATE, DELETE`, as the features
    need.
  - The trigger functions are owned by the migration owner.
- **The running service** connects as a login role that is a member of
  `say_app` (`DATABASE_URL`). `zokor migrate` runs as the owner
  (`MIGRATE_DATABASE_URL`) (decision D3).
- **The test stack** gets a `say_api` login role in `say_app`. Integration
  tests run the application code as `say_api`, and one test proves that
  UPDATE and DELETE on the ledger tables are refused.
- **"Only the ledger writes `ledger_*`, `wallets`, `holds`,
  `issuance_*`."** Postgres can't tell features apart under one role, so a
  repo test scans every SQL literal under `src/`. Any `INSERT`, `UPDATE` or
  `DELETE` on those tables outside `src/ledger/store/` fails the build.

### 4.3 `post(c, LedgerTx) -> result[TxId, LedgerError]`

```
LedgerTx { business_key, kind, season_id, market_id?, ref_type?, ref_id?,
           metadata (display only), entries: [Entry], hold_ops: [HoldOp] }
Entry    { owner: User(id) | Bot(id) | System(key), asset_key, bucket, delta }
HoldOp   { open (wallet, asset, amount) | consume(hold_id, amount) | release(hold_id, amount) }
```

Steps, all on the caller's connection, in the caller's transaction:

1. **Validate (pure, domain).** At least 2 entries, no zero delta, and every
   asset sums to zero. Sums use checked addition: slang integers wrap, so
   `checked_add` refuses beyond ±2⁶³−1 and returns `Overflow`. System
   entries use the free bucket only. The business key is non-empty and at
   most 200 bytes.
2. **Retry fast path.** `SELECT public_id, payload_hash FROM
   ledger_transactions WHERE business_key = $1`. The same hash returns that
   `public_id` and nothing changes. A different hash returns
   `IdempotencyConflict`. This makes most retries lock-free.
3. **Season.** `SELECT status … FOR SHARE` (§1.3). The kind must be allowed
   in that status:

   | Kind | Allowed season status |
   |---|---|
   | SEASON_GRANT, ORDER_HOLD, FILL, FEE, MINT, MERGE, BOT_FUNDING | ACTIVE |
   | ORDER_RELEASE | ACTIVE, CLOSING |
   | PAYOUT | CLOSING, CLOSED |
   | ADJUSTMENT | anything but FINALIZED |

   Otherwise it returns `SeasonNotActive`.
4. **Wallets.**
   - Create missing user and bot wallets in one `INSERT … SELECT … ORDER BY
     season_id, owner_id, asset_key ON CONFLICT DO NOTHING`. A sorted
     insert order means racing first touches can't deadlock on the unique
     index.
   - Lock **all user and bot wallets the call touches** with one `SELECT …
     WHERE (season_id, owner_id, asset_key) IN (…) ORDER BY season_id,
     owner_id, asset_key FOR UPDATE`.
   - Resolve system wallet ids without locking them.
   - Any wallet whose season differs from the transaction's returns
     `SeasonMismatch`.
5. **Insert the transaction** with `INSERT … ON CONFLICT (business_key) DO
   NOTHING RETURNING`. If no row comes back, a concurrent caller won the
   race after step 2. Re-read it, then return the existing id (same hash) or
   `IdempotencyConflict`. The caller's transaction is left for the caller
   to roll back.
6. **Balances.**
   - From the locked rows and the deltas, compute each wallet's new free and
     held amounts with checked addition.
   - Any negative result returns `InsufficientFunds { wallet, asset, needed,
     available }` before any write.
   - Otherwise it inserts all entries in one multi-row `INSERT`, with
     `free_after` and `held_after` for user and bot wallets, and updates each
     locked wallet once.
   - The CHECK constraints are the backstop. A CHECK violation (23514) that
     slipped through is mapped to `InsufficientFunds`, not surfaced raw.
7. **Holds** (§4.5).

**`post_many(c, [LedgerTx])`** does steps 3–4 once over the union of all
the transactions' wallets, then steps 5–7 for each transaction. Prompt 05
needs it, because a fill and its fees are separate business keys in one
database transaction.

Calling `post` twice in one database transaction locks in two rounds. Two
such transactions could then lock in conflicting order. So the rule is: **a
database transaction that touches wallets calls `post` or `post_many`
exactly once.** The API documents it, and a debug assertion enforces it by
setting a per-transaction `say.ledger_posted` GUC.

**The lock order, which is the deadlock rule:** issuance claim row (grants
only) → seasons row (shared) → user and bot wallets, sorted by
`(season_id, owner_id, asset_key)` → hold rows, which are only ever touched
after their wallet is locked → issuance budget shard (grants only, last;
one row for a single grant, ascending rows for a chunk). System wallets are
never locked.

**One round of statements per call.** `post_many` inserts every
transaction in one statement, every entry in one, and updates every moved
wallet in one, so a rollover chunk of 500 grants costs about ten round
trips, not 1,500.

### 4.4 Canonical payload hash

`sha256` over a byte string built in a fixed order. Each field is written
as `len:bytes` so no field can bleed into the next:

1. `kind`, `season_id`, `market_id` (or empty), `ref_type`, `ref_id`;
2. the entries, sorted by `(owner_id, asset_key, bucket)`, each written as
   `owner_id|asset_key|bucket|delta`;
3. the hold ops, sorted, each as `op|hold_id-or-wallet|amount`.

`metadata` is **excluded** (decision D8). It is display text, so a retry
whose display text changed is still the same money movement.

### 4.5 Holds

```sql
holds (
  id               uuid PK,
  wallet_id        uuid NOT NULL,
  season_id        uuid NOT NULL,
  asset_key        text NOT NULL,
  amount_held      bigint NOT NULL CHECK (amount_held > 0),
  amount_consumed  bigint NOT NULL DEFAULT 0 CHECK (amount_consumed >= 0),
  amount_released  bigint NOT NULL DEFAULT 0 CHECK (amount_released >= 0),
  ref_type         text NOT NULL,
  ref_id           text NOT NULL,
  status           text NOT NULL CHECK (status IN ('open','closed')),
  opened_tx        bigint NOT NULL REFERENCES ledger_transactions(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  closed_at        timestamptz,
  FOREIGN KEY (wallet_id, season_id) REFERENCES wallets(id, season_id),
  CHECK (amount_consumed + amount_released <= amount_held),
  CHECK ((status = 'closed') = (amount_consumed + amount_released = amount_held))
)
INDEX holds_open_season ON holds (season_id) WHERE status = 'open'
INDEX holds_ref         ON holds (ref_type, ref_id)
```

Each helper is a single `post`:

- **`hold(c, owner, season, asset, amount, ref, key)`:** an `ORDER_HOLD`
  posting with free −amount and held +amount on the owner's wallet. It opens
  a hold row and returns the hold id.
- **`release(c, hold_id, amount, key)`:** an `ORDER_RELEASE` posting, held
  −amount and free +amount.
- **`consume(c, hold_id, amount, counter_entries, key)`:** held −amount on
  the hold's wallet, plus the counter entries the caller supplies
  (counterparty, collateral, fees). They must balance per asset. The kind is
  the caller's (`FILL`, `FEE`, `MINT` …).

Hold updates happen **after** the wallet lock:

```sql
UPDATE holds SET amount_consumed = amount_consumed + $n, …
 WHERE id = $id AND status = 'open'
   AND amount_consumed + amount_released + $n <= amount_held
RETURNING …
```

- No row back: if the hold is closed it's `HoldNotOpen`, otherwise
  `HoldExceeded`.
- The row is closed in the same statement when it reaches zero remaining,
  which the CHECK requires.
- Every operation on a hold first locks its wallet, so concurrent consumes
  and releases on one hold serialise there. The hold row never needs a lock
  order of its own.

### 4.6 The commit-time check, aggregator and watermarks

- **The deferred constraint trigger** on `ledger_entries` (`AFTER INSERT,
  DEFERRABLE INITIALLY DEFERRED, FOR EACH ROW`) re-checks at COMMIT that the
  row's transaction sums to zero per asset and that every entry's season
  matches its transaction's.
  - On failure it raises `23514` with the message prefix `LEDGER_INVARIANT`.
    `post`'s callers never see this, because `post` checked it first. If it
    does fire, the commit error is logged as **critical**.
- **The system-balance aggregator** is a spawned task that runs every 2 s
  under `LOCK_AGGREGATE`.
  ```sql
  system_balances (wallet_id uuid PK, season_id uuid, owner_id text, asset_key text,
                   balance bigint NOT NULL, as_of timestamptz NOT NULL)
  ledger_watermarks (name text PK, xid xid8 NOT NULL)  -- 'aggregate', 'recon'
  ```
- **The watermark is a transaction id, not `max(id)`.** Identity ids are
  assigned at insert, not at commit. A transaction that commits late can
  hold a lower id than one already scanned, and a `max(id)` watermark would
  skip it forever.
  - Each pass takes `pg_snapshot_xmin(pg_current_snapshot())`. Every
    transaction below it has finished, so its rows are final.
  - The pass folds in system entries whose transaction `xid` is in
    `[watermark, xmin)`, then advances the watermark. That is exact, with no
    lag window.
  - Incremental reconciliation (§5 of the prompt) uses the same scheme.
  - A long-running transaction holds xmin back. The aggregator then reports
    its staleness (`system_balances_lag_seconds`) instead of guessing.

### 4.7 Errors

```
LedgerError = InsufficientFunds { wallet, asset, needed, available }
            | IdempotencyConflict { business_key }
            | SeasonMismatch | SeasonNotActive { status }
            | Unbalanced { asset, sum } | Overflow
            | HoldNotOpen | HoldExceeded { remaining }
            | WalletNotFound { owner, asset }     -- added: missing system wallet
            | PolicyMissing | CapReached          -- added: grants only
            | Store { detail }                    -- logged, never sent to clients
```

Each maps to a registered error code in `src/ledger/server/errors.sl`.
`InsufficientFunds` becomes `INSUFFICIENT_FUNDS` (409, with `needed` and
`available`), and so on; the full table goes in API.md.

---

## 5. Decisions for you

| # | Question | Decision (all approved 2026-10-20) |
|---|---|---|
| D1 | Exact per-season cap through 16 budget shards (§2.2), rather than an approximate cap re-checked afterwards | Shards: exact, and no hot row |
| D2 | Where outbox events (`season.*`, `reconciliation.failed`, `issuance.cap_reached`) go | `outbox_events` (exists). A small publisher, kicked through a bounded channel and also polling every 5 s, sends them to the Redis stream `say:events` and stamps `published_at`. Prompt 05 consumes `season.closing` from there. |
| D3 | Restricted role wiring | Two URLs: `MIGRATE_DATABASE_URL` (owner) for `zokor migrate`, `DATABASE_URL` (a `say_app` member) for the service. The test stack adds `say_api`. |
| D4 | Seasons missed entirely while the service was down | Walk them through ACTIVE and CLOSING, and run **no** rollover grants for them; grants only for the season that is live now |
| D5 | Rebuild the ledger tables | Migration 004 drops and recreates `wallets`, `ledger_*` and `issuance_grants`, and re-types `fills` and `settlement_claims` `journal_id`. It needs another dev DB reset. Nothing is in production. |
| D6 | Operator CLI | A subcommand of the same binary, `bin/say admin issuance-policy propose|approve|show --operator <uuid>`, with `src/main.sl` dispatching on the first argument. The alternative is a second entry point, `src/admin.sl`. |
| D7 | Postings that need ACTIVE take `FOR SHARE` on the season row (§1.3) | Yes. That is about 20 concurrent sharers at most (the pool size). The alternative, an exchange grace period after `season.closing`, is weaker. |
| D8 | `metadata` excluded from the idempotency hash | Excluded (left to me; kept) |
| D9 | Metrics | There is no metrics backend yet. `platform/metrics` holds counters and gauges, updated through a bounded channel that drops and counts when full, and served at `GET /metrics` (Prometheus text, admin or internal only). |
| D10 | Verification while no policy exists or the cap is reached | Verify anyway, with no grant; the rollover covers the account later |

---

## 6. Departures from the spec docs and from prompt 01's code

1. **Lock order.** The schema doc says `(season_id, account_id, asset_key)`;
   the prompt says `owner_id`. They are the same order: `owner_id` equals
   the account id for users and bots, and system wallets are never locked.
2. **Grant amount.** The schema doc has `issuance_grants.amount CHECK
   (amount = 1000)`. Here the amount comes from the approved policy and is
   checked as `> 0`.
3. **Shares.** The kernel spec has a separate `Position` table. Following
   the prompt, shares are `YES:` and `NO:` wallets. Positions become a read
   model in prompt 05.
4. **Naming.** The spec's "available" and "reserved" are `free` and `held`,
   per the prompt. The API still says `available`.
5. **Treasury reservations.** The spec gives the treasury free and reserved
   balances. Here the treasury is a system wallet with no cached balance;
   bot funding is a transfer to the bot wallet (prompt 09).
6. **Transaction ids.** `ledger_transactions.id` was a uuid; it is now a
   bigint, with a uuid `public_id`.
7. **The reconciliation watermark** uses transaction xids, not
   `max(ledger_transactions.id)` as the prompt says (§4.6, explained there).
8. **Step order.** The prompt checks idempotency at step 4. A lock-free
   pre-check is added before the locks (§4.3 step 2), and the
   insert-on-conflict at step 5 still decides races.
9. **Prompt 01 code replaced:**
   - `post_signup_grant` and the `allow_negative` issuance wallet (prompt
     01's "grants serialise on one hot row" is gone);
   - kind `ISSUANCE_GRANT` (now `SEASON_GRANT`);
   - the `SEASON_GRANT_AMOUNT` setting.

   The verify and Google-complete transactions call
   `grant_season_allowance` instead. Their response's `grant` keeps its
   shape.
10. **Errors added:** `WalletNotFound`, `PolicyMissing` and `CapReached`.
    The prompt's list has no place for those failures.
11. **The reactor fix.** Until dolphlabs/slang#448 is installed, the load
    tests in this prompt run on a locally built slangc from that branch, and
    the performance report will say so.

---

## 7. Changed while building

- **Shards hold whole grants** (§2.2). Splitting the cap evenly in sedis
  left 125 per shard for a 2,000 cap, so no shard could fund a single
  S 1,000 grant. The integration test for the cap caught it.
- **The budget is taken last** (§2.2, §4.3). Taking it first held a shard
  row for the whole posting. At 32 concurrent grants most sessions were
  waiting on shard rows.
- **`post_many` is batched** (§4.3). Rollover chunks went from about 1,500
  round trips to about ten, which brought 100k grants to about 70 s.
- **Entries carry `hold_id`** for held-bucket rows, so the holds check can
  compare each open hold with exactly its own entries.
- **The claim checks eligibility** in the same statement, so an account
  suspended between the rollover's page read and its chunk is skipped.
- **Seeding races.** The first grants of a season seed its budget. A grant
  that found no rows, while another transaction's seed was still
  uncommitted, used to report the cap reached. It now seeds if needed and
  looks once more before reporting it. The hot-account test (32
  concurrent first grants) caught it.
- **Wallet creation checks the account's kind** (`user` or `bot`), so a
  posting cannot open a user wallet for a bot or for an account that does
  not exist; it fails with `WalletNotFound`.
