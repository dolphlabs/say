# say web

React + TypeScript frontend for say, built with Vite, TanStack Router and
TanStack Query. It talks to the service over same-origin `/v1` requests with
the HttpOnly `say_session` cookie; nothing private is kept in browser storage.

```sh
npm ci
npm run dev        # Vite on :5173, proxying /v1 (HTTP and WebSocket) to SAY_API_ORIGIN
npm run build      # type-check and build into dist/
npm test           # API client checks (node:test)
npm run test:ui    # component and unit tests (vitest + jsdom)
```

`SAY_API_ORIGIN` (in `.env` here, default `http://localhost:8080`) points the
dev proxy at a running service. Set the service's `APP_URL` to the browser
origin so Google sign-in redirects land back in the app. In production serve
`dist/` and route `/v1` to the service on the same HTTPS origin, falling back
to `index.html` for app routes.

## Layout

```
src/
  api.ts, format.ts      HTTP client and error type; sedi / WAT formatting
  session.ts             the signed-in user, roles, and clearing private data
  live.ts                stream events that trigger throttled REST refreshes
  shell.tsx              player header, notifications, footer
  ui/                    shared pieces: icons, chips, gauge, chart, toast
  features/
    markets/             home, market detail, order book, chart, resolution
    trading/             order panel, quick trade, idempotent submission, quotes
    auth/                sign up (email and Google), log in, password reset
    portfolio/           summary, positions, orders, results, activity
    standings/           leaderboard
    profile/             public profile and account settings
    admin/               markets, resolution, treasury & bots, approvals & audit
```

Each feature keeps its own typed API module (`features/*/api.ts`). The admin
console is a separate chunk loaded only on `/admin/*`.

## Behaviour worth knowing

- Orders carry one `Idempotency-Key` per intent, kept with the intent in
  `sessionStorage` until the server gives a definite answer. A network error or
  5xx keeps it, so a retry of the same order recovers the original result; a
  different order is refused until that one is resolved or discarded. A `202`
  is polled on `GET /v1/orders/:id` until it is no longer `ADMITTED`.
- Order previews are estimates walked from the current book; the server sets
  the final price.
- A `401 UNAUTHENTICATED` on any request drops all private query data.
- Public views also poll, so a stream that cannot connect only costs freshness.
- Missing values (no price, no rank, no cap) render as `—` or a sentence, never
  as zero.
- Account deletion stays disabled: the service does not yet cancel open orders
  reliably before anonymising an account.
