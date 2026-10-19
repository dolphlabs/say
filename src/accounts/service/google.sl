import "crypto";
import "encoding";
import "json";
import "strings";
import "time";
import "timez";
import "../domain" as domain;
import "../../ledger/domain" as ledger;

pub gc struct RsaKey {
    n: bytes,
    e: bytes
}

// Google's signing keys, held in memory. A background task refreshes them
// on Google's max-age; an unknown kid forces at most one refresh a minute.
pub gc struct Jwks {
    lock: mutex,
    keys: map[str]RsaKey,
    expires_unix: int,
    last_forced_unix: int
}

pub fn new_jwks() -> Jwks {
    let keys: map[str]RsaKey = {};
    return Jwks { lock: make_mutex(), keys: keys, expires_unix: 0, last_forced_unix: 0 };
}

gc struct Jwk {
    kid: str,
    kty: str,
    n: str,
    e: str
}

gc struct JwksBody {
    keys: [Jwk]
}

pub fn parse_jwks(body: str) -> result[map[str]RsaKey, str] {
    let r: result[JwksBody, str] = json.decode(body);
    guard let doc = r else let e = err_of(r) {
        return err("jwks: " + e);
    }
    let out: map[str]RsaKey = {};
    for k in doc.keys {
        if k.kty != "RSA" || len(k.kid) == 0 {
            continue;
        }
        let nr = encoding.base64url_decode(k.n);
        let er = encoding.base64url_decode(k.e);
        if let n = nr {
            if let e = er {
                out[k.kid] = RsaKey { n: n, e: e };
            }
        }
    }
    if len(out) == 0 {
        return err("jwks: no usable RSA keys");
    }
    return ok(out);
}

pub fn refresh_jwks[C](a: Auth[C]) -> result[int, str] {
    let fetch = a.store.google_jwks;
    let r = fetch(a.store.context);
    guard let doc = r else let e = err_of(r) {
        return err(e);
    }
    let pr = parse_jwks(doc.body);
    guard let keys = pr else let e = err_of(pr) {
        return err(e);
    }
    let max_age = doc.max_age_seconds;
    if max_age < 60 {
        max_age = 3600;
    }
    mutex_lock(a.jwks.lock);
    a.jwks.keys = keys;
    a.jwks.expires_unix = timez.now().unix() + max_age;
    mutex_unlock(a.jwks.lock);
    return ok(max_age);
}

pub fn run_jwks_refresher[C](a: Auth[C]) -> int {
    while true {
        let r = refresh_jwks(a);
        let wait = 30;
        if let max_age = r {
            wait = max_age - 60;
            if wait < 60 {
                wait = 60;
            }
        } else let e = err_of(r) {
            report(a, "google jwks refresh failed: " + e);
        }
        time.sleep(wait * 1000000000);
    }
    return 0;
}

fn cached_key(j: Jwks, kid: str) -> opt[RsaKey] {
    mutex_lock(j.lock);
    let found: opt[RsaKey] = none;
    if has(j.keys, kid) {
        found = some(j.keys[kid]);
    }
    mutex_unlock(j.lock);
    return found;
}

fn may_force(j: Jwks) -> bool {
    let now = timez.now().unix();
    mutex_lock(j.lock);
    let allowed = now - j.last_forced_unix >= 60;
    if allowed {
        j.last_forced_unix = now;
    }
    mutex_unlock(j.lock);
    return allowed;
}

fn key_for[C](a: Auth[C], kid: str) -> opt[RsaKey] {
    if let k = cached_key(a.jwks, kid) {
        return some(k);
    }
    if !may_force(a.jwks) {
        return none;
    }
    let _r = refresh_jwks(a);
    return cached_key(a.jwks, kid);
}

gc struct JoseHeader {
    alg: str,
    kid: str
}

pub gc struct GoogleClaims {
    iss: str,
    aud: str,
    sub: str,
    exp: int,
    nonce: opt[str],
    email: opt[str],
    email_verified: opt[bool]
}

fn decode_segment(s: str) -> result[str, str] {
    let r = encoding.base64url_decode(s);
    guard let b = r else let e = err_of(r) {
        return err(e);
    }
    return ok(strings.from_bytes(b, 0, len(b)));
}

// Signature against Google's JWKS, then iss, aud, exp, nonce and a
// verified email. Anything short of all of them is a failure.
pub fn check_id_token[C](a: Auth[C], token: str, nonce: str, now_unix: int) -> result[GoogleClaims, str] {
    if len(token) > 8192 {
        return err("id token too large");
    }
    let parts = strings.split(token, ".");
    if len(parts) != 3 {
        return err("id token is not a JWS");
    }
    let hr = decode_segment(parts[0]);
    guard let header_text = hr else let e = err_of(hr) {
        return err("id token header: " + e);
    }
    let jr: result[JoseHeader, str] = json.decode(header_text);
    guard let header = jr else let e = err_of(jr) {
        return err("id token header: " + e);
    }
    if header.alg != "RS256" {
        return err("id token alg " + header.alg + " not accepted");
    }
    guard let key = key_for(a, header.kid) else {
        return err("id token signed by unknown key " + header.kid);
    }
    let sr = encoding.base64url_decode(parts[2]);
    guard let sig = sr else let e = err_of(sr) {
        return err("id token signature: " + e);
    }
    let vr = crypto.rsa_verify_sha256(key.n, key.e, to_bytes(parts[0] + "." + parts[1]), sig);
    guard let valid = vr else let e = err_of(vr) {
        return err("id token key: " + e);
    }
    if !valid {
        return err("id token signature does not verify");
    }
    let pr = decode_segment(parts[1]);
    guard let payload = pr else let e = err_of(pr) {
        return err("id token payload: " + e);
    }
    let cr: result[GoogleClaims, str] = json.decode(payload);
    guard let claims = cr else let e = err_of(cr) {
        return err("id token claims: " + e);
    }
    if claims.iss != "https://accounts.google.com" && claims.iss != "accounts.google.com" {
        return err("id token issuer " + claims.iss);
    }
    if claims.aud != a.cfg.google_client_id {
        return err("id token audience mismatch");
    }
    if claims.exp + 30 < now_unix {
        return err("id token expired");
    }
    if (claims.nonce ?? "") != nonce || len(nonce) == 0 {
        return err("id token nonce mismatch");
    }
    if !(claims.email_verified ?? false) || len(claims.email ?? "") == 0 {
        return err("google email not verified");
    }
    if len(claims.sub) == 0 {
        return err("id token has no subject");
    }
    return ok(claims);
}

gc struct OAuthState {
    nonce: str,
    verifier: str,
    intent: str,
    account_id: str
}

gc struct PendingGoogle {
    subject: str,
    email: str,
    email_masked: str
}

fn state_key(state: str) -> str {
    return "oauth:state:" + encoding.hex_encode(hash_token(state));
}

fn pending_key(token: str) -> str {
    return "pending_google:" + encoding.hex_encode(hash_token(token));
}

fn random_b64(n: int) -> result[str, str] {
    let r = crypto.rand(n);
    guard let b = r else let e = err_of(r) {
        return err(e);
    }
    return ok(encoding.base64url_encode(b));
}

// The Google consent URL for intent signup|login|link, with S256 PKCE,
// state and nonce kept single-use in Redis for ten minutes.
pub fn google_start[C](a: Auth[C], intent: str, session_account: str) -> result[str, Failed] {
    if intent != "signup" && intent != "login" && intent != "link" {
        return err(fail_field(Why.BadRequest, "intent", "must be signup, login or link"));
    }
    if intent == "link" && len(session_account) == 0 {
        return err(fail(Why.Unauthenticated, "link needs a session"));
    }
    if len(a.cfg.google_client_id) == 0 {
        return err(fail(Why.GoogleFailed, "google sign-in is not configured"));
    }
    let sr = random_b64(32);
    let nr = random_b64(32);
    let vr = random_b64(32);
    guard let state = sr else { return err(fail(Why.Unavailable, "rand")); }
    guard let nonce = nr else { return err(fail(Why.Unavailable, "rand")); }
    guard let verifier = vr else { return err(fail(Why.Unavailable, "rand")); }
    let saved = json.encode(OAuthState { nonce: nonce, verifier: verifier, intent: intent, account_id: session_account });
    let put = a.store.eph_put;
    let pr = put(a.store.context, state_key(state), saved, a.cfg.oauth_state_seconds);
    guard let _p = pr else let e = err_of(pr) {
        return err(fail(Why.Unavailable, "oauth state not stored: " + e));
    }
    let challenge = encoding.base64url_encode(crypto.sha256(to_bytes(verifier)));
    return ok(a.cfg.google_auth_url +
        "?client_id=" + encoding.url_encode(a.cfg.google_client_id) +
        "&redirect_uri=" + encoding.url_encode(a.cfg.google_redirect_uri) +
        "&response_type=code&scope=" + encoding.url_encode("openid email") +
        "&state=" + encoding.url_encode(state) +
        "&nonce=" + encoding.url_encode(nonce) +
        "&code_challenge=" + encoding.url_encode(challenge) +
        "&code_challenge_method=S256&prompt=select_account");
}

pub enum CallbackKind {
    SignedIn,
    Pending,
    Linked
}

pub gc struct Callback {
    kind: CallbackKind,
    intent: str,
    session_token: str,
    pending_token: str,
    email_masked: str
}

fn callback(kind: CallbackKind, intent: str) -> Callback {
    return Callback { kind: kind, intent: intent, session_token: "", pending_token: "", email_masked: "" };
}

pub fn google_callback[C](a: Auth[C], state: str, code: str, meta: Meta) -> result[Callback, Failed] {
    if len(state) == 0 || len(state) > 128 || len(code) == 0 || len(code) > 2048 {
        return err(fail(Why.PendingExpired, "missing state or code"));
    }
    let take = a.store.eph_take;
    let tr = take(a.store.context, state_key(state));
    guard let taken = tr else let e = err_of(tr) {
        return err(fail(Why.Unavailable, "oauth state unreadable: " + e));
    }
    guard let saved_text = taken else {
        return err(fail(Why.PendingExpired, "oauth state unknown, used or expired"));
    }
    let sr: result[OAuthState, str] = json.decode(saved_text);
    guard let saved = sr else let e = err_of(sr) {
        return err(fail(Why.PendingExpired, e));
    }
    let exchange = a.store.google_exchange;
    let xr = exchange(a.store.context, code, saved.verifier, a.cfg.google_redirect_uri);
    guard let id_token = xr else let e = err_of(xr) {
        return err(fail(Why.GoogleFailed, e));
    }
    let cr = check_id_token(a, id_token, saved.nonce, timez.now().unix());
    guard let claims = cr else let e = err_of(cr) {
        return err(fail(Why.GoogleFailed, e));
    }
    let email = domain.normalize_email(claims.email ?? "");
    let ir = a.store.identity_owner;
    let owner_r = ir(a.store.context, claims.sub);
    guard let identity_owner = owner_r else let f = err_of(owner_r) {
        return err(from_store(f));
    }
    let er = a.store.email_owner;
    let email_r = er(a.store.context, email);
    guard let email_owner = email_r else let f = err_of(email_r) {
        return err(from_store(f));
    }
    let none_str: opt[str] = none;
    let session_account = none_str;
    if len(saved.account_id) > 0 {
        session_account = some(saved.account_id);
    }
    let decision = domain.google_link_policy(saved.intent, identity_owner, email_owner, session_account);
    switch decision {
        case domain.GoogleOutcome.LogIn {
            let owner = identity_owner ?? "";
            let ar = account_of(a, owner);
            guard let account = ar else let f = err_of(ar) {
                return err(f);
            }
            if !domain.can_sign_in(account.status) {
                return err(fail(Why.InvalidCredentials, "account cannot sign in"));
            }
            let sr2 = start_session(a, owner, meta);
            guard let token = sr2 else let f = err_of(sr2) {
                return err(f);
            }
            audit_event(a, owner, "login", meta, "{\"method\":\"google\"}");
            let out = callback(CallbackKind.SignedIn, saved.intent);
            out.session_token = token;
            return ok(out);
        }
        case domain.GoogleOutcome.EmailInUse {
            return err(fail(Why.GoogleEmailInUse, ""));
        }
        case domain.GoogleOutcome.Link {
            let link_fn = a.store.link_google;
            let lr = link_fn(a.store.context, saved.account_id, claims.sub, email);
            guard let _l = lr else let f = err_of(lr) {
                return err(from_store(f));
            }
            audit_event(a, saved.account_id, "google_linked", meta, "{}");
            return ok(callback(CallbackKind.Linked, saved.intent));
        }
        case domain.GoogleOutcome.AlreadyLinked {
            return ok(callback(CallbackKind.Linked, saved.intent));
        }
        case domain.GoogleOutcome.LinkedElsewhere {
            return err(fail(Why.GoogleLinkedElsewhere, ""));
        }
        case domain.GoogleOutcome.NeedSession {
            return err(fail(Why.Unauthenticated, ""));
        }
        default {
            let pr = new_token();
            guard let pending = pr else let e = err_of(pr) {
                return err(fail(Why.Unavailable, e));
            }
            let masked = domain.mask_email(email);
            let body = json.encode(PendingGoogle { subject: claims.sub, email: email, email_masked: masked });
            let put = a.store.eph_put;
            let put_r = put(a.store.context, pending_key(pending.value), body, a.cfg.pending_seconds);
            guard let _p = put_r else let e = err_of(put_r) {
                return err(fail(Why.Unavailable, "pending signup not stored: " + e));
            }
            let out = callback(CallbackKind.Pending, saved.intent);
            out.pending_token = pending.value;
            out.email_masked = masked;
            return ok(out);
        }
    }
}

pub fn google_complete[C](a: Auth[C], pending_token: str, raw_username: str, hold_id: str,
                          meta: Meta) -> result[SignedIn, Failed] {
    if len(pending_token) == 0 || len(pending_token) > 128 {
        return err(fail(Why.PendingExpired, ""));
    }
    let username = domain.normalize_username(raw_username);
    if let bad = username_failure(username, a.cfg.reserved) {
        return err(bad);
    }
    let get = a.store.eph_get;
    let gr = get(a.store.context, pending_key(pending_token));
    guard let found = gr else let e = err_of(gr) {
        return err(fail(Why.Unavailable, "pending signup unreadable: " + e));
    }
    guard let body = found else {
        return err(fail(Why.PendingExpired, ""));
    }
    let pr: result[PendingGoogle, str] = json.decode(body);
    guard let pending = pr else {
        return err(fail(Why.PendingExpired, "pending signup unreadable"));
    }
    if let bad = hold_problem(a, username, hold_id) {
        return err(bad);
    }
    let tr = new_token();
    guard let token = tr else let e = err_of(tr) {
        return err(fail(Why.Unavailable, e));
    }
    let make_id = a.new_id;
    let create = a.store.create_google_account;
    let cr = create(a.store.context, GoogleSignup {
        account_id: make_id(),
        username: username,
        email: pending.email,
        subject: pending.subject,
        grant_amount: a.cfg.grant_amount,
        session: new_session(token, a.cfg.session_ttl_seconds, meta)
    });
    guard let made = cr else let f = err_of(cr) {
        if f.fault == Fault.EmailTaken {
            return err(fail(Why.GoogleEmailInUse, ""));
        }
        return err(from_store(f));
    }
    let drop = a.store.eph_drop;
    let _d = drop(a.store.context, [pending_key(pending_token)]);
    release_hold(a, username);
    audit_event(a, made.account.id, "signup", meta, "{\"method\":\"google\"}");
    audit_event(a, made.account.id, "google_linked", meta, "{}");
    return ok(SignedIn { account: made.account, session_token: token.value, grant: made.grant });
}

fn account_grant_none() -> opt[ledger.Grant] {
    let g: opt[ledger.Grant] = none;
    return g;
}
