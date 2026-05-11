# Google OAuth Login — Server

**Status:** Design
**Date:** 2026-05-09
**Companion spec:** `diet-tracker-ios/docs/superpowers/specs/2026-05-09-google-oauth-login-ios-design.md`

## Goal

Replace static API-key auth with a server-mediated Google OAuth flow. The server owns the entire OAuth handshake (Google client secret stays server-side), issues an opaque session token to the iOS client via a custom-scheme redirect, and validates that token as a Bearer credential on every subsequent request. Single-user today (single allowed email), designed so multi-user is a clean future change.

## Scope

In: `/auth/google/start`, `/auth/google/callback`, `/auth/whoami`, `/auth/logout`; auth middleware that validates Bearer tokens; `sessions` table; allowlist via `ALLOWED_EMAILS`; removal of `X-API-Key` middleware and `?user_key=` parameter handling.

Out: refresh tokens; multi-tenant data model (data stays keyed by the existing `user_key`); rate-limiting; CAPTCHA; account self-service.

## Non-goals

- Not maintaining backwards compatibility with `X-API-Key`. Cutover is hard.
- Not a real users table — the allowlist is the user model for now.
- Not stateless JWTs — opaque tokens with a server-side `sessions` row, so revocation is trivial.

## Contract with iOS

- **Sign-in start:** iOS opens `<base>/auth/google/start` in `ASWebAuthenticationSession` with callback scheme `diettracker`. The server is responsible for the entire Google handshake.
- **Callback success:** server 302s to `diettracker://auth?token=<opaque>&email=<urlenc>`.
- **Callback failure:** server 302s to `diettracker://auth?error=<code>` where `<code>` ∈ `{access_denied, not_allowed, invalid_state, invalid_callback, server_error}`. iOS owns user-facing copy.
- **Session use:** iOS sends `Authorization: Bearer <token>` on every non-`/auth/*` call. No `?user_key=` is sent.
- **Whoami:** `GET /auth/whoami` → `{ "email": string, "expires_at": ISO-8601 }`.
- **Sign-out:** `POST /auth/logout` with the Bearer token → 204 on success.
- **Token semantics:** opaque server-issued string, sliding TTL renewed on every authenticated request.

## Endpoints

### `GET /auth/google/start`

1. Generate a 32-byte random `state` value.
2. Set a short-lived (10 min), HttpOnly, `SameSite=Lax`, `Secure` cookie `oauth_state=<state>` scoped to `/auth/google/`.
3. Build Google authorize URL with:
   - `client_id` = `GOOGLE_CLIENT_ID`
   - `redirect_uri` = `OAUTH_REDIRECT_URI` (must match what's registered in Google Cloud Console)
   - `response_type` = `code`
   - `scope` = `openid email profile`
   - `state` = the value above
   - `prompt` = `select_account`
   - `access_type` = `online` (we only need ID token for identity; no refresh token)
4. 302 to that URL.

Failure: returns 500 if `GOOGLE_CLIENT_ID` / `OAUTH_REDIRECT_URI` aren't configured. There is no app redirect on this path because the user hasn't reached the app yet — they get a plain 500 page.

### `GET /auth/google/callback?code=&state=&error=`

All exit paths from this endpoint are 302 to `<APP_REDIRECT_SCHEME>://auth?…`. There is no HTML response.

1. If `error=` is present (Google denied), 302 to `diettracker://auth?error=access_denied`.
2. If `state` query param doesn't match the cookie or cookie is missing/expired, 302 to `diettracker://auth?error=invalid_state`. Always clear the cookie.
3. POST to Google's token endpoint with `code`, `client_id`, `client_secret`, `redirect_uri`, `grant_type=authorization_code`. Failure → 302 with `error=server_error`; log the upstream error.
4. Verify the returned ID token's signature against Google's JWKS, validate `iss`, `aud == GOOGLE_CLIENT_ID`, `exp`, `iat`. Pull `email` and `sub`. Verification failure → 302 with `error=server_error`.
5. If `email` ∉ `ALLOWED_EMAILS` (case-insensitive compare), 302 with `error=not_allowed`. Log the rejected email at INFO so first-time setup can find the right one.
6. Generate a 32-byte random session token. Insert a row into `sessions`: `(token_hash = sha256(token), email, created_at = now, last_used_at = now, expires_at = now + SESSION_TTL_DAYS)`. The token itself is never persisted, only its hash.
7. 302 to `diettracker://auth?token=<token>&email=<urlenc(email)>`.
8. Clear the `oauth_state` cookie on every exit.

### `GET /auth/whoami`

Bearer-required. Returns `{ "email": <session.email>, "expires_at": <ISO-8601 of session.expires_at> }`. The middleware (below) has already slid `expires_at`, so the value returned reflects post-slide.

### `POST /auth/logout`

Bearer-required. Deletes the `sessions` row. Returns 204. If the token doesn't exist or is expired, returns 401 (handled by middleware before this handler runs).

## Middleware

Applies to every route except `/auth/google/start`, `/auth/google/callback`, and `/health` (if present).

1. Read `Authorization` header. If missing or not `Bearer <token>`, return 401.
2. Compute `sha256(token)`. Look up `sessions` by `token_hash`.
3. If not found, return 401.
4. If `expires_at <= now`, delete the row and return 401.
5. Slide: set `last_used_at = now`, `expires_at = now + SESSION_TTL_DAYS`. Single `UPDATE`.
6. Attach `request.context.email = session.email` and `request.context.user_key = email_to_user_key(email)` for downstream handlers.
7. Continue to the route handler.

`email_to_user_key(email)` is a single-line helper that, today, returns the env-configured `LEGACY_USER_KEY` (`"khash"`) — the existing data is keyed there. When multi-user lands later, this helper changes to a real lookup; nothing else has to.

### Cutover guardrail

For one release after this lands, the middleware also rejects requests where the URL contains a `user_key` query parameter (any non-`/auth/*` route): returns 400 `{"error":"user_key query param is no longer accepted"}`. This catches any forgotten iOS call sites loudly. The guardrail is removed in a follow-up cleanup.

## Data model

New table:

```sql
CREATE TABLE sessions (
    token_hash    BYTEA PRIMARY KEY,         -- sha256 of opaque token
    email         TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at    TIMESTAMPTZ NOT NULL
);

CREATE INDEX sessions_email_idx ON sessions (email);
CREATE INDEX sessions_expires_idx ON sessions (expires_at);
```

Alembic migration adds the table. A separate, optional housekeeping job (out of scope for this spec) can delete rows where `expires_at < now()`.

## Configuration (env)

| Var | Purpose | Example |
|---|---|---|
| `GOOGLE_CLIENT_ID` | Google OAuth client id | `…apps.googleusercontent.com` |
| `GOOGLE_CLIENT_SECRET` | Google OAuth client secret | (secret) |
| `OAUTH_REDIRECT_URI` | Google sends user back here | `https://api.example.com/auth/google/callback` |
| `APP_REDIRECT_SCHEME` | Custom scheme for iOS callback | `diettracker` |
| `ALLOWED_EMAILS` | Comma-separated allowlist | `khashzd@gmail.com` |
| `SESSION_TTL_DAYS` | Sliding TTL | `90` |
| `SESSION_TOKEN_BYTES` | Random bytes for token | `32` |
| `LEGACY_USER_KEY` | Today's single user_key | `khash` |

`API_KEY` (the static key the server currently accepts) is removed.

Removed env: anything wiring up `X-API-Key` checks.

## Error handling

| Condition | Response |
|---|---|
| Missing required `GOOGLE_*` env at boot | Process fails to start with a clear error. |
| Google token exchange returns non-2xx | 302 to `diettracker://auth?error=server_error`; upstream body logged at WARN. |
| ID token signature/claim verification fails | 302 with `error=server_error`. |
| Email not in `ALLOWED_EMAILS` | 302 with `error=not_allowed`; rejected email logged at INFO. |
| State cookie missing/mismatched/expired | 302 with `error=invalid_state`. |
| Anything else unexpected in callback | 302 with `error=server_error`; full traceback logged. |
| Bearer missing on protected route | 401. |
| Bearer present but session not found | 401. |
| Bearer present but session expired | 401; session row deleted. |
| `?user_key=` on protected route (during guardrail window) | 400. |

## Security notes

- **Token storage:** server stores `sha256(token_hash)` only — DB compromise doesn't leak live tokens.
- **State cookie:** HttpOnly, `Secure`, `SameSite=Lax`, 10 min TTL, scoped to `/auth/google/` so it isn't sent on regular API traffic.
- **Allowlist comparison:** lowercased email both sides; trim whitespace.
- **`prompt=select_account`:** prevents silent re-use of a non-allowlisted Google account already signed into the device's browser.
- **TLS:** the redirect URI and base URL must be HTTPS in any non-local environment. Server fails to start if `OAUTH_REDIRECT_URI` is non-`https://` and the env isn't `local`/`dev`.
- **Logging:** never log raw tokens or full ID tokens; log only `email` and `sub` after verification.

## Testing

| Endpoint / area | Test |
|---|---|
| `/auth/google/start` | Returns 302; `Location` is Google authorize URL with all required params; `state` cookie set with correct attributes. |
| Callback — happy path | Stub Google token endpoint and userinfo; allowed email; assert 302 to `diettracker://auth?token=…&email=…`; session row exists with hashed token and correct TTL. |
| Callback — Google denial | `?error=access_denied` → 302 with `error=access_denied`; no session created. |
| Callback — bad state | Mismatched / missing cookie → 302 with `error=invalid_state`; no session. |
| Callback — disallowed email | Allowed list excludes the test email → 302 with `error=not_allowed`; no session. |
| Callback — invalid ID token | Tampered signature → 302 with `error=server_error`; no session. |
| Middleware — missing Bearer | 401. |
| Middleware — unknown token | 401. |
| Middleware — expired session | 401; row deleted. |
| Middleware — happy path | 200; `last_used_at` and `expires_at` advanced. |
| `/auth/whoami` | 200 with `{email, expires_at}`. |
| `/auth/logout` | 204; session row gone; subsequent request with same Bearer → 401. |
| Cutover guardrail | Any non-`/auth/*` request with `?user_key=foo` → 400. |
| End-to-end (test client) | One full sign-in → authenticated request → logout → request rejected. |

## Cutover

Hard cutover in a single deploy:

1. Apply Alembic migration to create `sessions`.
2. Set `GOOGLE_*`, `ALLOWED_EMAILS`, `OAUTH_REDIRECT_URI`, `APP_REDIRECT_SCHEME`, `LEGACY_USER_KEY`.
3. Register the redirect URI in Google Cloud Console.
4. Deploy the new server. `X-API-Key` requests now 401. `?user_key=` requests on protected routes now 400 (guardrail). iOS PR is released in lockstep.
5. Remove the `?user_key=` 400 guardrail in the next release.

## Open questions

- Token entropy: 32 bytes (`SESSION_TOKEN_BYTES = 32`) is plenty; confirm the URL-safe encoding (likely base64url without padding) at impl time.
- ID-token verification: prefer `google-auth` library's verifier over hand-rolled JWKS handling. Confirm available in the server's dep set.
- `/health` (or whatever liveness endpoint exists) stays unauthenticated — confirm exact path during impl.
