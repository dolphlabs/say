# Governance, Standings, Profiles, and Approvals API

This document covers all endpoints introduced in **Prompt 10** for season standings, public profiles, account settings, staff 2FA, staff role management, unified approvals inbox, and audit logging.

---

## 1. Season Leaderboard & Standings

### `GET /v1/leaderboard`
Returns the current season leaderboard, including the season progress header, top-3 podium, ranked list, and the caller's personal standing card if authenticated.

- **Auth**: Optional session (`auth.require_session` not required, but caller `account_id` evaluated if present)
- **Query Parameters**:
  - `sort`: `profit` (default), `win_rate`, `calls`
  - `limit`: `1..100` (default: `50`)
  - `cursor`: keyset pagination cursor for subsequent pages
- **Response `200 OK`**:
  ```json
  {
    "season": {
      "ordinal": 1,
      "status": "ACTIVE",
      "starts_at": 1700000000000,
      "ends_at": 1705000000000,
      "players": 3180,
      "provisional": false,
      "provisional_reason": ""
    },
    "podium": [
      {
        "account_id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
        "username": "tunde.calls",
        "avatar_color": "#4caf50",
        "profit": 12450,
        "calls": 42,
        "wins": 34,
        "losses": 8,
        "rank_profit": 1,
        "rank_win": 2,
        "rank_calls": 5,
        "win_rate": "81%",
        "leaderboard_eligible": true
      }
    ],
    "items": [...],
    "next_cursor": "",
    "me": {
      "rank": 38,
      "of": 3180,
      "profit": 514,
      "percentile_label": "top 2%",
      "to_top20": 214,
      "row": { ... }
    }
  }
  ```
- **Rules**:
  - Minimum 5 settled calls required to show a percentage for `win_rate`. Otherwise, `win_rate` is empty `""` and excluded from `rank_win`.
  - Tie-break for profit: `profit DESC`, then `profit_reached_at ASC`, then `account_id ASC`.
  - Excludes banned (`status != 'ACTIVE'`) and non-eligible staff (`leaderboard_eligible = false`).

### `GET /v1/leaderboard/strip`
Ultra-fast strip showing the top 5 players by profit for live feeds and banners.

- **Auth**: None (Public)
- **Response `200 OK`**:
  ```json
  {
    "items": [
      { "account_id": "...", "username": "tunde.calls", "avatar_color": "#4caf50", "profit": 12450, "rank_profit": 1 }
    ]
  }
  ```

---

## 2. Public Profiles

### `GET /v1/users/:username`
Public user profile with strict privacy guarantees.

- **Auth**: None (Public)
- **Caching**: `Cache-Control: public, max-age=10`
- **Response `200 OK`**:
  ```json
  {
    "username": "kemi.calls",
    "avatar_color": "#e91e63",
    "joined_season": "Season 01",
    "share_url": "https://say.it/u/kemi.calls",
    "current_season": {
      "rank": 38,
      "of": 3180,
      "profit": 514,
      "calls": 12,
      "right": 8,
      "settled": 12
    },
    "calls": [
      {
        "market": {
          "slug": "will-ghana-inflation-drop-below-20-pct",
          "question": "Will Ghana inflation drop below 20% in October?"
        },
        "side": "YES",
        "status": "OPEN",
        "chance_pct": 65
      }
    ]
  }
  ```
- **Privacy Guarantees**:
  - **NEVER EXPOSED**: email, Sedis balance, held funds, share count, order IDs, fill prices, or trade logs.
  - Active positions only expose the market question, slug, chosen side (`YES`/`NO`), status, and current market chance percentage.
- **Redirects & Deletion**:
  - If user was renamed within 30 days: `301 Moved Permanently` to `/v1/users/<new_username>`.
  - If user was deleted or never existed: `404 Not Found`.

---

## 3. Account Settings & 2FA

### `PATCH /v1/me/username`
Renames the caller's username.

- **Auth**: Required session
- **Window**: First 72 hours of an active season only.
- **Limits**: Once per season per account.
- **Reservation**: The old username is reserved for 30 days (prevents impersonation; incoming traffic redirected with 301).
- **Body**: `{ "username": "new_handle" }`
- **Errors**:
  - `400 USERNAME_INVALID`
  - `409 USERNAME_TAKEN`
  - `403 USERNAME_CHANGE_WINDOW_CLOSED`
  - `409 USERNAME_ALREADY_CHANGED_THIS_SEASON`
- **Response `200 OK`**: `{ "username": "new_handle" }`

### `POST /v1/me/email`
Requests an email change. Dispatches a 6-digit OTP to the new email address.

- **Auth**: Required session
- **Body**: `{ "new_email": "new@example.com" }`
- **Response `202 Accepted`**:
  ```json
  {
    "change_token": "a1b2c3d4...",
    "resend_available_at": "60s"
  }
  ```

### `POST /v1/me/email/verify`
Confirms the email change with the OTP sent to the new email.

- **Auth**: Required session
- **Body**: `{ "change_token": "a1b2c3d4...", "code": "654321" }`
- **Security Actions**:
  - Updates account email.
  - Dispatches security alert notice to old email address.
  - Revokes all other active sessions for this account.
- **Response `204 No Content`**

### `DELETE /v1/me`
Permanently deletes and anonymises the caller's account.

- **Auth**: Required session
- **Confirmation**: Authenticated session verified.
- **Actions**:
  1. Concurrently drains and cancels all open and partial orders across all markets via `CancelAll`.
  2. Anonymises `username` to `deleted-<6 random hex>`.
  3. Erases email, phone number, passwords, Google IDs, and notification preferences.
  4. Marks status = `DELETED`, sets `leaderboard_eligible = false`.
  5. Preserves immutable double-entry ledger transactions and trade histories.
  6. Clears session cookie and invalidates all session tokens.
- **Response `202 Accepted`**: `{}` (with cleared session cookie)

### `POST /v1/me/2fa/enroll`
Enrolls staff into RFC 6238 TOTP 2FA.

- **Auth**: Required session
- **Response `200 OK`**:
  ```json
  {
    "secret": "JBSWY3DPEHPK3PXP...",
    "uri": "otpauth://totp/say:kemi?secret=JBSWY3DPEHPK3PXP...&issuer=say&algorithm=SHA256&digits=6&period=30"
  }
  ```

### `POST /v1/me/2fa/verify`
Verifies enrollment or acts as a step-up verification. Proof lasts for 12 hours.

- **Auth**: Required session
- **Body**: `{ "code": "123456" }`
- **Response `200 OK`**: `{ "verified": true }`

### `POST /v1/me/2fa/disable`
Disables TOTP 2FA.

- **Auth**: Required session
- **Body**: `{ "code": "123456" }`
- **Response `204 No Content`**

---

## 4. Staff Roles Management

### `POST /v1/admin/roles`
Grants a role to an account.

- **Auth**: Required session + Staff Role
- **Policy**:
  - `creator` role can be granted directly by curators or super_admins.
  - Staff roles (`curator`, `analyst`, `admin`, `settler`) create a `role_grant` approval request requiring a second staff member's approval.
- **Body**: `{ "username": "kwame", "role": "curator", "reason": "Joined content team" }`
- **Response `200 OK`** (Direct): `{ "status": "granted" }`
- **Response `202 Accepted`** (Pending Approval):
  ```json
  {
    "status": "pending_approval",
    "approval_id": "app-4a9f-..."
  }
  ```

### `DELETE /v1/admin/roles`
Revokes a role immediately.

- **Auth**: Required session + Super Admin (or Curator for creator role)
- **Body**: `{ "username": "kwame", "role": "creator" }`
- **Response `204 No Content`**

---

## 5. Unified Approvals Inbox

### `GET /v1/admin/approvals`
Lists pending and historical approval requests across markets, liquidity, bots, and roles.

- **Auth**: Required session + Staff Role
- **Query Parameters**:
  - `status`: `pending` (default), `approved`, `rejected`
  - `kind`: `market_open`, `liquidity`, `bot_topup`, `role_grant`, `issuance_policy`
- **Response `200 OK`**:
  ```json
  {
    "items": [
      {
        "id": "app-01...",
        "kind": "role_grant",
        "title": "Grant curator role to kwame",
        "detail": "Joined content team",
        "requested_by": {
          "username": "alice.admin",
          "role": "admin"
        },
        "requested_at": 1700000000000,
        "can_decide": true,
        "subject_link": "/v1/admin/approvals/app-01...",
        "payload_hash": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "status": "pending"
      }
    ]
  }
  ```
- **Rules**:
  - Self-approval is strictly forbidden: if `requester_account_id == caller_account_id`, `can_decide = false` with reason `"You asked for this, so someone else has to approve it."`
  - Stale payloads are rejected: decision must send back the `payload_hash`.

### `POST /v1/admin/approvals/:id/approve`
Approves an approval request.

- **Auth**: Required session + 12h Step-Up TOTP proof
- **Body**:
  ```json
  {
    "payload_hash": "e3b0c442...",
    "note": "Looks good, vetted."
  }
  ```
- **Response `200 OK`**: `{ "status": "approved" }`
- **Errors**:
  - `403 TOTP_REQUIRED`: caller must complete step-up 2FA within last 12 hours.
  - `403 SELF_APPROVAL_FORBIDDEN`: cannot approve own request.
  - `409 STALE_APPROVAL`: payload hash does not match current request state.

### `POST /v1/admin/approvals/:id/reject`
Rejects an approval request.

- **Auth**: Required session + 12h Step-Up TOTP proof
- **Body**:
  ```json
  {
    "payload_hash": "e3b0c442...",
    "reason": "Budget cap too high."
  }
  ```
- **Response `200 OK`**: `{ "status": "rejected" }`

---

## 6. Audit Logging & Export

### `GET /v1/admin/audit`
Queries the append-only, immutable audit trail with keyset pagination.

- **Auth**: Required session + Staff Role
- **Query Parameters**:
  - `area`: `Access`, `Market`, `Money`, `Resolution`, `Governance`
  - `actor`: account UUID
  - `target_type`: entity type (e.g. `market`, `account`, `bot`, `policy`)
  - `target_id`: target entity ID
  - `from`: epoch ms start
  - `to`: epoch ms end
  - `limit`: `1..100` (default: `50`)
  - `cursor`: keyset pagination cursor
- **Response `200 OK`**:
  ```json
  {
    "items": [
      {
        "id": "aud-1...",
        "actor_id": "9b1deb4d-...",
        "actor_kind": "staff",
        "role_at_time": "curator",
        "area": "Market",
        "action": "MARKET_APPROVED",
        "target_type": "market",
        "target_id": "mkt-1...",
        "ip_address": "197.210.64.12",
        "links": "{\"market_slug\": \"will-ghana-win\"}",
        "detail": "{\"round\": 1}",
        "created_at_ms": 1700000000000
      }
    ],
    "next_cursor": "aud-1..."
  }
  ```

### `POST /v1/admin/audit/export`
Enqueues an immutable CSV audit export job.

- **Auth**: Required session + Admin
- **Body**: Filter options (`area`, `actor`, `from`, `to`)
- **Response `202 Accepted`**:
  ```json
  {
    "id": "exp-9a8b...",
    "download_url": "/v1/admin/audit/export/exp-9a8b..."
  }
  ```

### `GET /v1/admin/audit/export/:id`
Downloads the exported audit CSV.

- **Auth**: Required session + Admin
- **Response `200 OK`**: `Content-Type: text/csv`
  ```csv
  id,created_at_ms,actor_id,actor_kind,role_at_time,area,action,target_type,target_id,ip_address,links,detail
  aud-1,1700000000000,9b1deb4d-...,staff,curator,Market,MARKET_APPROVED,market,mkt-1,197.210.64.12,"{}","{}"
  ```
