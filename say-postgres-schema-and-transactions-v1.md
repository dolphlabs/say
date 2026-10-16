# say — PostgreSQL Schema & Transaction Protocol

**Version:** 1.0 | **Date:** 2026-10-16 | **Status:** Design DDL, migrations require validation

## 1. Fundamental constraints

PostgreSQL is source of truth for issuance, custody, orders, fills, sessions, fees, settlements and approvals. Redis never decides asset ownership. `sedi` is a ledger asset; YES/NO shares are separate per-market assets. All values are integral, checked and nonnegative at account-balance level. User balances derive from posted entries, with cached balances updated inside the same transaction.

Each market declares immutable `redemption_units` `V_m`, `min_price`, `max_price`, `tick`, `max_order_qty`, fee policy, resolution terms, and eligible evidence sources before opening. Do not change them after market activation. Prices interpreted as probability use `price/V_m`; no floating-point money.

## 2. Migration 001 — Core tables (illustrative PostgreSQL 16+)

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE seasons (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), ordinal bigint UNIQUE NOT NULL, starts_at timestamptz NOT NULL, ends_at timestamptz NOT NULL, status text NOT NULL CHECK (status IN ('SCHEDULED','ACTIVE','CLOSING','CLOSED','FINALIZED')), CHECK (ends_at = starts_at + interval '14 days'));
CREATE TABLE accounts (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), verified_at timestamptz, status text NOT NULL DEFAULT 'ACTIVE', beneficial_owner_group uuid, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE markets (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), season_id uuid NOT NULL REFERENCES seasons(id), statement text NOT NULL, terms_hash text NOT NULL, redemption_units bigint NOT NULL CHECK (redemption_units >= 3), min_price bigint NOT NULL CHECK (min_price > 0), max_price bigint NOT NULL, tick bigint NOT NULL CHECK(tick > 0), fee_units bigint NOT NULL DEFAULT 1 CHECK(fee_units = 1), min_order_notional bigint NOT NULL DEFAULT 2 CHECK(min_order_notional = 2), status text NOT NULL, cutoff_at timestamptz NOT NULL, resolution_at timestamptz, owner_epoch bigint NOT NULL DEFAULT 0, committed_seq bigint NOT NULL DEFAULT 0, book_seq bigint NOT NULL DEFAULT 0, CHECK (max_price < redemption_units AND min_price <= max_price), CHECK((max_price-min_price) >= 0));
CREATE TABLE wallets (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), account_id uuid NOT NULL, season_id uuid NOT NULL REFERENCES seasons(id), asset_key text NOT NULL, free_units bigint NOT NULL DEFAULT 0 CHECK(free_units >= 0), reserved_units bigint NOT NULL DEFAULT 0 CHECK(reserved_units >= 0), UNIQUE(account_id,season_id,asset_key));
CREATE TABLE ledger_transactions (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), business_key text NOT NULL UNIQUE, kind text NOT NULL, season_id uuid REFERENCES seasons(id), market_id uuid REFERENCES markets(id), created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE ledger_entries (id bigserial PRIMARY KEY, transaction_id uuid NOT NULL REFERENCES ledger_transactions(id), wallet_id uuid NOT NULL REFERENCES wallets(id), asset_key text NOT NULL, delta_units bigint NOT NULL CHECK(delta_units <> 0));
CREATE INDEX ledger_entries_tx ON ledger_entries(transaction_id);
CREATE TABLE orders (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), account_id uuid NOT NULL REFERENCES accounts(id), market_id uuid NOT NULL REFERENCES markets(id), outcome text NOT NULL CHECK (outcome IN ('YES','NO')), side text NOT NULL CHECK(side IN ('BUY','SELL')), limit_price bigint NOT NULL CHECK(limit_price > 0), original_qty bigint NOT NULL CHECK(original_qty > 0), remaining_qty bigint NOT NULL CHECK(remaining_qty >= 0), status text NOT NULL, tif text NOT NULL CHECK(tif IN ('GTC','IOC')), fee_posted boolean NOT NULL DEFAULT false, accepted_seq bigint, created_at timestamptz NOT NULL DEFAULT now(), CHECK(remaining_qty <= original_qty));
CREATE INDEX orders_book ON orders(market_id,outcome,side,limit_price,created_at,id) WHERE remaining_qty > 0;
CREATE TABLE idempotency_records (account_id uuid NOT NULL REFERENCES accounts(id), scope text NOT NULL, idem_key text NOT NULL, request_hash text NOT NULL, order_id uuid REFERENCES orders(id), state text NOT NULL, PRIMARY KEY(account_id,scope,idem_key));
CREATE TABLE market_commands (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), market_id uuid NOT NULL REFERENCES markets(id), seq bigint NOT NULL, command_type text NOT NULL, payload jsonb NOT NULL, state text NOT NULL, UNIQUE(market_id,seq));
CREATE TABLE fills (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), market_id uuid NOT NULL REFERENCES markets(id), execution_seq bigint NOT NULL, fill_index integer NOT NULL, maker_order_id uuid NOT NULL REFERENCES orders(id), taker_order_id uuid NOT NULL REFERENCES orders(id), mode text NOT NULL CHECK(mode IN ('TRANSFER','MINT','MERGE')), qty bigint NOT NULL CHECK(qty>0), yes_equivalent_price bigint NOT NULL, journal_id uuid NOT NULL REFERENCES ledger_transactions(id), UNIQUE(market_id,execution_seq,fill_index));
CREATE TABLE outbox_events (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), market_id uuid REFERENCES markets(id), market_seq bigint, book_seq bigint, type text NOT NULL, payload jsonb NOT NULL, published_at timestamptz, attempt_count integer NOT NULL DEFAULT 0);
CREATE TABLE issuance_grants (account_id uuid NOT NULL REFERENCES accounts(id), season_id uuid NOT NULL REFERENCES seasons(id), amount bigint NOT NULL CHECK(amount=1000), journal_id uuid NOT NULL UNIQUE REFERENCES ledger_transactions(id), PRIMARY KEY(account_id,season_id));
CREATE TABLE market_resolutions (market_id uuid PRIMARY KEY REFERENCES markets(id), proposed_outcome text, evidence_digest text, proposed_at timestamptz, dispute_until timestamptz, approved_outcome text, super_admin_id uuid REFERENCES accounts(id), approved_at timestamptz, status text NOT NULL);
CREATE TABLE settlement_claims (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), market_id uuid NOT NULL REFERENCES markets(id), account_id uuid NOT NULL REFERENCES accounts(id), decision_key text NOT NULL, outcome text NOT NULL, units bigint NOT NULL CHECK(units>=0), journal_id uuid NOT NULL UNIQUE REFERENCES ledger_transactions(id), UNIQUE(market_id,account_id,decision_key,outcome));
CREATE TABLE audit_events (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), actor_id uuid, action text NOT NULL, target_type text NOT NULL, target_id uuid, detail jsonb NOT NULL, created_at timestamptz DEFAULT now());
```

**Required additions before shipping:** market terms versions; creator approvals; authorization grants and multi-party approvals; dedicated inventory journal and collateral set journal; snapshots and hashes; immutable evidence payloads; durable settlement queue; bot budgets; reservation links; risk triggers; explicit owner fencing history; and a deferred transaction-level per-asset sum-zero check. This DDL is a structural starting point, not a deployable complete migration.

## 3. Ledger transaction design

The `ledger_entries` table records signed deltas and must be rejected at COMMIT unless for each transaction and asset `SUM(delta_units)=0`. Implement via a deferred constraint trigger or post-and-check stored procedure with restricted direct DML rights. Enforce unique business keys. Wallet account movement and journal insertion occur in one database transaction. Lock wallet rows in stable lexical `(season_id, account_id, asset_key)` order.

For mint of one pair: deduct eligible buyers’ sedi funds in total `V_m`; credit collateral custody by `V_m`; issue +1 YES and +1 NO to their respective inventory accounts against corresponding issuance clearing journals. For settlement: redeem `V_m` to each winning unit once, burn all outstanding units, and release collateral. Never mix currency and inventory in one summation.

## 4. Admission protocol

BEGIN SERIALIZABLE (or READ COMMITTED with explicit row locks and version checks): verify account, market season/time, market min/max/tick and notional >=2; look up `(account_id,scope,idempotency_key)`; compare canonical request hash; lock funding wallets; reserve max purchase or shares plus unpaid flat fee; create order and idempotency row; assign durable market command sequence under locked market row; COMMIT. On request timeout, return existing order by key; do not create a second order.

## 5. Fill protocol

BEGIN: lock market row, assert `owner_epoch` and expected `committed_seq`; lock affected wallets; post transfers/issuance/merge and one-time S1 fee per newly executed order; insert fills with stable unique keys; update orders and reservations; insert `outbox_events`; increment `committed_seq` and `book_seq` only on book changes; assert ledger sums and inventory collateral invariants; COMMIT. Actor advances memory only on success.

## 6. Cancellation, idempotency and price protection

Cancel command is sequenced by market actor. Once committed, free unspent credits or unsold shares and unused fee reserve. Self-trade across the same beneficial-owner group invokes CANCEL_NEW, with no fill or trade fee. If computed execution or bot quote price would fall outside immutable market band, reject/cancel the matching attempt, never clamp. Fill prices use maker price, awarding all feasible improvement to taker.

## 7. Season clock, evidence and voids

Season schedule follows Africa/Lagos UTC+01:00 for display and operations; `timestamptz` stores UTC instants. Every verified eligible account receives a unique 1,000-sedi grant per season. Resolution proposal publishes evidence, then must wait at least 30 minutes for disputes before super-admin approval and settlement. On disputed or cancelled markets, no automatic void until the refund accounting algorithm covers secondary sales, fees and guaranteed solvency; a flat refund of every historical BUY would double pay.

## 8. Indexes, migrations and hardening

Add partial indexes on live GTC orders, `(market_id,book_seq)` outbox, settlement work status, market deadline, unprocessed commands. Partition fills, ledger_entries and outbox only after measurement. Use advisory migration locks, schema migrations with zero-downtime compatibility, RLS or separate restricted DB roles, backups with PITR, and daily reconciliation.
