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

The specification covers the currently mounted account/authentication,
season, ledger, reconciliation, and market-registry routes. It reflects the
response shapes created by the current route handlers; in particular, season
responses are direct season objects, and a missing current season is an error.

The matching core is a domain implementation, not an HTTP API. The exchange
runtime's order admission, cancellation, book/trade REST views and the
WebSocket feed are not implemented as routes and are intentionally absent.
The WebSocket channel protocol in `docs/stream/STREAM.md` is a proposed design,
not an active endpoint. Re-export this specification when route contracts
change.

OpenAPI examples use synthetic credentials and identifiers. SEDI quantities
and market prices are integer units. Timestamps are RFC 3339; season display
uses `Africa/Lagos`.
