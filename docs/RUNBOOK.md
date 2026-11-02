# say — Operator Runbook & Incident Response

This runbook documents day-to-day operations, emergency controls, incident response procedures, and administrative interventions for **say**.

---

## 1. Emergency Kill Switches

### Global Trading Emergency Halt
To immediately halt all trading across every market:
```bash
# Using CLI
say admin emergency halt --reason "Suspected matching desync"

# Via API (requires Super Admin session + 12h TOTP step-up)
POST /v1/admin/emergency/halt
Content-Type: application/json

{ "reason": "Immediate engine investigation required" }
```

### House Bot Emergency Drain & Pause
If bots are pricing incorrectly or experiencing adverse inventory buildup:
```bash
# Via API (requires Admin role)
POST /v1/admin/treasury/pause
Content-Type: application/json

{ "cancel_resting_orders": true, "reason": "Adverse selection spike" }
```
- **SLA**: All resting bot orders cancelled within **< 2.0 seconds**.
- **Result**: Bots stop quoting; resting quotes withdrawn; player-to-player trading unaffected.

### Single Market Emergency Suspension
To suspend a single disputed or corrupted market:
```bash
POST /v1/markets/:id/suspend
Content-Type: application/json

{ "reason": "Official resolution source fixture postponed" }
```

---

## 2. Ledger Reconciliation & Discrepancy Resolution

The ledger runs continuous automated reconciliation:
- **Rule**: `sum(active_wallets) + sum(held_orders) == system:issuance` at all times.
- **Alert**: `LEDGER_IMBALANCE_DETECTED` (SEV-1).

### Incident Response Steps:
1. **Identify Discrepancy**:
   ```sql
   select * from reconciliation_runs order by ran_at desc limit 1;
   ```
2. **Review Detailed Journals**:
   Check `posting_journal` and `order_admission_holds` for mismatched debits and credits:
   ```sql
   select account_id, sum(amount) as balance 
   from postings 
   group by account_id 
   having sum(amount) < 0; -- Invariant violation if player balance negative
   ```
3. **Trace Transaction Hash**:
   Every posting journal entry contains an SHA256 cryptographic chain. Check hash continuity:
   ```sql
   select id, prev_hash, current_hash from postings order by sequence_num asc;
   ```

---

## 3. Season Transitions & Leaderboard Maintenance

### Season Closing Procedure:
1. **At `ends_at`**:
   - The season status changes from `ACTIVE` to `CLOSING`.
   - Provisional banner appears on `/v1/leaderboard` if unfinalized markets remain.
2. **When All Markets Settled**:
   - Operator freezes final standings into `season_final_standings`:
     ```sql
     insert into season_final_standings(season_id, account_id, final_rank, final_profit, frozen_at)
     select season_id, account_id, rank_profit, profit, now()
     from season_standings
     where season_id = $1;
     ```
   - Update season status to `CLOSED`.
3. **Start Next Season**:
   - Insert new season record (status `ACTIVE`).
   - Trigger initial season issuance (P-1 policy grants 1,000 S to each active eligible player).
   - The 72-hour username change window opens automatically for the first 72 hours of the new season.

---

## 4. Staff Role Grants & Dual Approvals

### Granting Creator Role (Direct):
Curators and super admins can grant the creator role directly:
```bash
POST /v1/admin/roles
{ "username": "tunde.calls", "role": "creator", "reason": "Approved market creator" }
```

### Granting Staff Roles (Requires Dual Approval):
Staff roles (`curator`, `analyst`, `admin`, `settler`) generate a `role_grant` approval item in the unified inbox:
```bash
POST /v1/admin/roles
{ "username": "alice", "role": "curator", "reason": "Hired into content team" }
# Returns 202 Accepted with approval_id
```
- A **different** staff member must approve the request via `POST /v1/admin/approvals/:id/approve`.
- Self-approval is rejected by policy.
- Caller must have completed TOTP verification within the last 12 hours.

---

## 5. Audit Log Export & Verification

### Running an Audit Export:
To generate an immutable CSV for compliance or investigation:
```bash
POST /v1/admin/audit/export
Content-Type: application/json

{
  "area": "Money",
  "from": 1700000000000,
  "to": 1705000000000
}
```
Response returns `{ "id": "exp-uuid", "download_url": "/v1/admin/audit/export/exp-uuid" }`.

### Downloading Export:
```bash
curl -H "Authorization: Bearer <staff_token>" https://api.say.it/v1/admin/audit/export/exp-uuid -o audit.csv
```

---

## 6. Injectable Clock Audit & Deterministic Time

All time-dependent schedulers and business logic throughout the application are decoupled from hardware wall clocks via the `timez.Clock` port:
- **Ledger**: Uses `timez.Clock` for posting sequence timestamps.
- **Markets**: Uses `timez.Clock` for `open_at`, `close_at`, and `resolve_by` transitions.
- **Exchange Engine**: Uses strictly monotonic sequence IDs and injectable time for order expiry and cancel-all sweeps.
- **Standings & 72h Rename Window**: Uses epoch ms offsets checked against season `starts_at`.
- **Rehearsal Simulation**: Runs deterministic step-based tick progression without hardware sleep delays.
