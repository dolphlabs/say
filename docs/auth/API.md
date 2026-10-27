# say auth API

For the app team. All bodies are JSON. Timestamps are RFC 3339 in UTC;
show them in Africa/Lagos. Base path `/v1`.

## Sessions

A successful verify, login or Google sign-in sets a cookie:

```
Set-Cookie: say_session=<token>; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Lax
```

Browsers need nothing else. Mobile clients take the same token from the
cookie and send `Authorization: Bearer <token>`. Sessions last 30 days.
Logging out, resetting the password, changing it (other sessions only)
and deleting the account all end sessions at once.

## Errors

Every failure has one shape:

```json
{ "error": { "code": "OTP_INVALID", "message": "That code is not right.", "attempts_left": 3 } }
```

`message` is short and safe to show as is. Optional members:

| Member | When |
|---|---|
| `retry_after` (seconds) | `RATE_LIMITED`, `BUSY`; also sent as the `Retry-After` header |
| `attempts_left` | `OTP_INVALID` |
| `signup_token` | `EMAIL_NOT_VERIFIED`: go straight to the code screen with it |
| `fields: [{field, reason}]` | Validation: every bad field at once; `code` names the first |

| Code | HTTP | Meaning / what the UI does |
|---|---|---|
| `USERNAME_INVALID` | 422 | 3–20 characters, `a-z 0-9 . _`, starts with a letter or digit, does not end with `.` |
| `USERNAME_RESERVED` | 422 | On the reserved list |
| `USERNAME_TAKEN` | 409 | Taken or held by someone else; at signup, back to step 1 |
| `USERNAME_HOLD_EXPIRED` | 409 | The 10-minute hold ran out or does not match; pick the name again |
| `EMAIL_INVALID` | 422 | |
| `EMAIL_IN_USE` | 409 | Offer "Log in instead" |
| `WEAK_PASSWORD` | 422 | Fewer than 8 characters (or over 128) |
| `INVALID_CREDENTIALS` | 401 | Every login failure, whatever the cause |
| `EMAIL_NOT_VERIFIED` | 403 | Only after a correct password; carries `signup_token` |
| `OTP_INVALID` | 400 | Wrong code; `attempts_left` (0 means the next try locks) |
| `OTP_EXPIRED` | 400 | Older than 10 minutes, already used, or replaced; send a new one |
| `OTP_LOCKED` | 423 | 5 wrong tries; send a new one |
| `GOOGLE_EMAIL_IN_USE` | 409 | Log in with the password, then link Google in Settings |
| `GOOGLE_LINKED_ELSEWHERE` | 409 | That Google account belongs to another say account |
| `GOOGLE_FAILED` | 502 | Google did not answer or its token failed a check |
| `PENDING_EXPIRED` | 410 | The signup token (30 min), Google pending signup (15 min) or OAuth state (10 min) ran out |
| `LAST_SIGN_IN_METHOD` | 409 | Cannot unlink Google without a password |
| `RATE_LIMITED` | 429 | `retry_after` |
| `UNAUTHENTICATED` | 401 | No session, or it ended |
| `BAD_REQUEST`, `VALIDATION_FAILED` | 400 / 422 | Malformed JSON, missing or wrongly-typed field |
| `BUSY` | 503 | Password checks are saturated; retry after `retry_after` |
| `UNAVAILABLE` | 503 | Our side failed; retry |

## The user object

Returned by verify, login, Google complete and `GET /v1/me`.

```json
{
  "id": "6f1c...", "username": "utee", "email": "utee@gmail.com",
  "email_verified": true, "has_password": true, "google_linked": false,
  "username_changeable_at": "2026-10-26T23:00:00Z", "created_at": "2026-10-19T21:02:11Z"
}
```

`username_changeable_at`: a username is fixed until the end of the season
it was set in.

## Endpoints

### Username (signup step 1)

`GET /v1/auth/username/{name}` → 200 (case-insensitive)

```json
{ "username": "utee", "available": false, "reason": "USERNAME_TAKEN",
  "suggestions": ["utee.ng", "utee99", "utee_ng"] }
```

`reason` is absent when available, otherwise `USERNAME_INVALID`,
`USERNAME_RESERVED` or `USERNAME_TAKEN`. Suggestions are given for
taken and reserved names. 60 checks per minute per IP.

`POST /v1/auth/username/hold` `{ "username" }` → 200
`{ "username", "hold_id", "expires_at" }`. Holds the name for 10
minutes. Errors: `USERNAME_INVALID`, `USERNAME_RESERVED`,
`USERNAME_TAKEN`.

### Email and password (step 2)

`POST /v1/auth/signup` `{ "username", "hold_id", "email", "password" }`
→ 201 `{ "signup_token", "email_masked": "u•••@gmail.com", "resend_available_at" }`

Creates an unverified account and emails a 6-digit code (valid for 10
minutes). Keep `signup_token` (30 minutes) for the next two calls.
Errors: the username codes above, `EMAIL_INVALID`, `EMAIL_IN_USE`,
`WEAK_PASSWORD`, `RATE_LIMITED` (5 signups per IP per hour).

`POST /v1/auth/otp/resend` → 202 `{ "resend_available_at" }`
- verify: `{ "signup_token", "purpose": "verify_email" }`
- reset: `{ "email", "purpose": "reset_password" }`, which always answers 202

A new code replaces the old one. 60 s between sends, 5 per email per
hour: early calls get `RATE_LIMITED` with `retry_after`.

### Code (step 3)

`POST /v1/auth/otp/verify` `{ "signup_token", "code" }` → 200 + cookie

```json
{ "user": { ... },
  "grant": { "amount": 1000, "season_ordinal": 1, "season_ends_at": "2026-10-26T23:00:00Z" } }
```

The welcome screen reads `grant`; show "Season 01" from
`season_ordinal`. `grant` is `null` when no season is running: the
account is still verified, and the season job (not built yet) will credit
it when the next season opens.
Errors: `OTP_INVALID` (+`attempts_left`), `OTP_EXPIRED`, `OTP_LOCKED`,
`PENDING_EXPIRED`, `RATE_LIMITED` (20 per IP per hour).

### Log in

`POST /v1/auth/login` `{ "email", "password" }` → 200 `{ "user", "grant": null }` + cookie.
Errors: `INVALID_CREDENTIALS`, `EMAIL_NOT_VERIFIED` (+`signup_token`),
`RATE_LIMITED` (10 per email and 30 per IP per 15 minutes), `BUSY`.

### Google

`GET /v1/auth/google/start?intent=signup|login|link` → 302 to Google.
`link` needs the session cookie.

`GET /v1/auth/google/callback` (Google redirects here) → 302 into the app:

| Outcome | Redirect |
|---|---|
| Signed in (known Google account) | `{APP_URL}/` with the session cookie |
| New Google account | `{APP_URL}/signup/google?pending_token=…&email=u•••@gmail.com` |
| Linked | `{APP_URL}/settings?google=linked` |
| Any failure | `{APP_URL}/login?error=<CODE>` |

`POST /v1/auth/google/complete` `{ "pending_token", "username", "hold_id" }`
→ 200 `{ "user", "grant" }` + cookie. Hold the username first, as in
step 1. Errors: username codes, `PENDING_EXPIRED`, `GOOGLE_EMAIL_IN_USE`.

### Password reset

`POST /v1/auth/password/forgot` `{ "email" }` → 202 `{}`, always.

`POST /v1/auth/password/reset` `{ "email", "code", "new_password" }` →
204, ends every session and clears the cookie. Errors: `OTP_INVALID`,
`OTP_EXPIRED`, `OTP_LOCKED`, `WEAK_PASSWORD`, `RATE_LIMITED`.

### Session and settings (need the session)

| Call | Answer |
|---|---|
| `GET /v1/me` | 200 user object |
| `POST /v1/me/password` `{ "current_password", "new_password" }` | 204; ends every other session. `INVALID_CREDENTIALS`, `WEAK_PASSWORD` |
| `DELETE /v1/me/google` | 204. `LAST_SIGN_IN_METHOD` without a password |
| `DELETE /v1/me` | 202; the account is flagged deleted, every session ends, cookie cleared |
| `POST /v1/auth/logout` | 204, clears the cookie; fine without a session |
| `POST /v1/auth/logout-others` | 204; this session stays |

Without a session: 401 `UNAUTHENTICATED`.

### Season

`GET /v1/seasons/current` (public) → 200
`{ "season": { "ordinal", "starts_at", "ends_at", "status" } }`, or
`{ "season": null }` between seasons.
