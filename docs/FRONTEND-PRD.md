# Frontend product and technical brief

Status: implementation brief. The supplied HTML contains 18 design boards:
desktop and phone home and market detail, signup and login, username, email,
verification and welcome steps, portfolio, leaderboard, profile and settings,
and operator markets, resolution, treasury and bots, and approvals and audit.
The example accounts, markets, prices and balances in the boards are mock data.

## Product

Say is a single-tenant, non-monetary prediction market. Players discover
markets, inspect their terms and trading activity, place orders with SEDI,
and follow positions and season performance. Public discovery is available
without a session. Account data and trading require authentication. Operator
workflows require the specific server-enforced role.

## Candidate user journeys

- Browse and search markets, inspect categories, market terms, prices, book,
  trades and history. Show unavailable or missing market data honestly.
- Sign up, verify email, sign in, recover access and manage account settings.
- Submit and cancel orders, see pending and committed states, and inspect
  positions, balances, results and notifications.
- View standings, profiles and season information.
- Provide operator workflows only where supported by the supplied designs and
  the corresponding server permissions.

The artifact determines screen hierarchy and visual treatment. Live responses
determine the data shown and the actions actually available.

## Technical direction

Use React and TypeScript with TanStack Router and TanStack Query. Keep API
access in typed feature-specific modules and use the existing `@say/stream`
package for the WebSocket protocol where live updates are required. Select
additional UI, form, validation and chart libraries after inspecting the
designs and their actual needs. Preserve accessible keyboard behavior, visible
focus, responsive layouts, loading, empty, error and expired-session states.

The browser uses the server's HttpOnly `say_session` cookie; private data must
not persist after sign-out or session revocation. Prefer a same-origin API and
WebSocket deployment, with a development proxy where appropriate. Verify the
actual hosting and cookie behavior before choosing deployment configuration.
Do not expose credentials in URLs or browser storage.

Treat values, quantities and fees as integer units. Dates are displayed in
Africa/Lagos as specified by the service. Null prices, rank and other missing
values must not be represented as zero. The public API can return stale cursor
errors and degraded market views; provide recovery rather than displaying stale
data as live.

For order submission, generate a UUID idempotency key for each intent and reuse
it for retries of that same intent. A 202 response means admitted or cancel
pending, not filled or cancelled; reconcile against private order state. A
200 response may still describe an unfilled or rejected order. Show server
validation and economic outcomes accurately. Streaming recovery must respect
sequence gaps, resynchronization and private session revocation.

## Source contracts

- `docs/OPENAPI.md` and `openapi.json`: mounted routes and broad API inventory.
- `docs/auth/API.md`: session, authentication and error behavior.
- `docs/markets/API.md`: discovery, lifecycle, nulls and cursor semantics.
- `docs/exchange/API.md`: order admission, idempotency and committed state.
- `docs/portfolio/API.md`: portfolio and notification contracts; verify against
  current handlers when implementing because parts may describe earlier phases.
- `docs/stream/CLIENT.md`: browser stream, recovery and lifecycle behavior.
- `docs/IMPLEMENTATION.md`: implementation and verification boundaries.

## Acceptance and open work

Trace each implemented feature to current handlers and DTOs, add API changes
only when required, and test both successful and failure paths. Verify the UI
at desktop and mobile sizes, including authentication, order reconciliation and
session expiration. Run the frontend checks and the repository's `make check`;
report any unverified live, provider, or deployment behavior separately.

## Implementation safety boundary

Account deletion is disabled in the interface. The current account handler
ignores failures when reading markets and enqueuing CancelAll, and does not wait
for those commands to commit before anonymizing the account. Its current
anonymization SQL also references columns removed or renamed by the auth
migrations, and the isolated account HTTP deletion test returns UNAVAILABLE. Implementing a
retryable deletion lifecycle with admission fencing and committed-order draining
is required before exposing deletion. The browser uses REST as the private
portfolio baseline; the available private stream hydrator requires consistent
per-entity revisions that these separate REST endpoints do not provide.

Bot controls and funding are withheld from the interface. The current treasury
service ignores failures to enqueue bot cancellations, and its funding adapter
updates allocations directly while the designed flow requires an approval.
The checked-in bot runner also uses modelled inputs rather than authoritative
pause and market state. Completing and testing those backend workflows is
required before the interface can represent a pause or funding request as safe.
The treasury summary is also withheld: its current adapter suppresses query
failures and supplies default totals and a hard-coded balanced status. The
frontend must not present those values as authoritative.
