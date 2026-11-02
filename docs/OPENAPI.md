# OpenAPI and Postman

The root [`openapi.json`](../openapi.json) is an OpenAPI 3.1 specification for
the HTTP endpoints currently mounted by `src/main.sl`. Import the JSON file in
Postman with **Import → File**.

## Postman setup

1. Edit the server URL in the imported collection to the service origin, such
   as `http://localhost:8080` or the deployed HTTPS origin. Do not include
   `/v1`.
2. Browser requests use the `say_session` cookie set by login or signup
   verification. Postman normally keeps and resends this cookie automatically.
3. For mobile-style requests, choose **Bearer Token** in Authorization and
   paste the session token value. The cookie takes precedence when both are
   provided.
4. Public market discovery and season reads do not need authentication.
   `/v1/me/*` requires a session. Admin endpoints also check the caller's
   specific operator or market role; a valid session alone does not grant
   access.
5. Use the request examples in the collection as starting payloads. Replace
   sample UUIDs, credentials, dates, and tokens with values from your own
   environment. Never share real session tokens or passwords.

## Scope and implementation status

The specification covers all 97 HTTP and WebSocket endpoints mounted by `src/main.sl`:
- **Authentication & Account Settings**: Signup, OTP verification, password login & reset, Google OAuth, username changes, email updates, TOTP 2FA enrollment/verification/disablement, account deletion & anonymization, and staff role governance.
- **Seasons & Ledger**: Current and historical season metadata, cash balances, journaled transaction ledgers, and operator reconciliation runs.
- **Market Registry & Discovery**: Public market catalog, featured lists, category filtering, search, and admin market authoring & lifecycle workflows.
- **Exchange Core & Orders**: Limit order admission, order queries, cancellations, orderbook level-2 depths, and public trade history.
- **Portfolio & Positions**: Open position valuations with mark-to-market pricing, unrealized PnL, committed order reservations, and settled outcomes.
- **Notifications**: User notification feeds, unread badge counts, mark-as-read, preference toggles, and HMAC-signed email unsubscribe.
- **Resolution & Settlement**: Resolution queue management, evidence snapshots, trader dispute filing & decisions, two-person outcome finalization, and batch payout settlement progress.
- **Treasury & Bot Fleet**: Treasury reserves, player grant issuance, season budget proposals, bot inventory & spread oversight, quoting parameter updates, and bot heartbeats.
- **Standings & Public Profiles**: Season leaderboard rankings (profit, win rate, calls), live ticker strip, and public user prediction accuracy profiles.
- **Approvals & Governance**: Multi-person approval inbox enforcing separation of duties and payload hash integrity on privileged mutations.
- **Audit & Observability**: Immutable structured audit logs with faceted queries and exports, system health/readiness probes (`/healthz`, `/readyz`), Prometheus exposition (`/metrics`), and real-time WebSocket feeds (`/v1/stream`).

OpenAPI examples use synthetic credentials and identifiers. SEDI quantities
and market prices are integer units. Timestamps are RFC 3339; season display
uses `Africa/Lagos`.
