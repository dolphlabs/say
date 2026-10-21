# Ledger: assumptions and open TODOs

## Decisions (with Utee, 2026-10-20)

The D1–D10 table in [DESIGN.md](DESIGN.md#5-decisions-for-you): all approved
as proposed. For D8, `metadata` stays out of the idempotency hash.

## Assumptions

- **The cap belongs to the season it was seeded for.** A season's budget
  comes from the policy approved when the budget was first needed. A
  policy approved later applies from the next season; it does not top up
  the current one. Approving one does restart a rollover that had halted
  for lack of a policy.
- **Missed grants.** Verifying while no policy is approved, or after the
  cap is reached, still succeeds, with `grant: null`.
  - With no policy, the rollover halts. Approving a policy restarts it,
    and it then grants those accounts.
  - With the cap reached, the account waits for the next season.
- **Grants after the rollover.** Accounts verified mid-season are granted
  at verification. The rollover runs once per season, when it becomes
  ACTIVE.
- **Missed seasons** (the service was down for a whole season) are walked
  through ACTIVE and CLOSING with no grants (D4).
- **Restricted roles.** Production creates `say_app` and a login role in it
  before `make migrate`. Migration 004 creates `say_app` only where it is
  missing, which needs CREATEROLE.
- **Admin roles** come only from the CLI (`say admin role grant`) until
  prompt 10.
- **`/metrics`** is served only when `METRICS_TOKEN` is set, and needs it
  as a bearer token.
- **Ledger history is newest first** by the transaction's start time.
  Entries of one transaction share it.
- **`GET /v1/seasons/current` answers 404** when no season is active (only
  before launch). Prompt 01 answered `{"season": null}`.

## TODO for later prompts

- `TODO(prompt 05)`: on `season.closing`, the exchange cancels resting
  orders and releases their holds. CLOSING moves to CLOSED only when no
  hold is open.
- `TODO(prompt 05)`: the exchange checks the trading halt (Redis
  `say:trading_halted`, falling back to Postgres) before admitting orders.
- `TODO(prompt 05)`: call `open_market_wallets` when a market opens, and
  build the three `not_applicable` checks (`yes_no_supply`, `collateral`,
  `fee_once`) in `ledger/store/recon.sl`.
- `TODO(prompt 08)`: `settlement_complete(season)` in
  `ledger/store/seasons.sl` returns "market settlement arrives in prompt
  08", so no season reaches FINALIZED yet.
- `TODO(prompt 09)`: bot funding (`BOT_FUNDING` from `system:treasury`,
  under approved allocations).
- `TODO(prompt 10)`: the admin UI for issuance-policy approvals, and the
  role system that replaces `account_roles`.
- **Outbox consumers.** Events are published to the Redis stream
  `say:events`; nothing reads them yet.
- **Retention.** `ledger_entries` and `outbox_events` grow without bound.
  Partition or archive once real volumes are known (schema doc §8).
