import "encoding";
import "json";
import "strings";

fn fixture_nonce() -> str {
    return "fixed-nonce-7701";
}

fn now_unix() -> int {
    return 1750000000;
}

fn expect_rejected(a: Auth[Fake], token: str, nonce: str, why: str) {
    let r = check_id_token(a, token, nonce, now_unix());
    guard let _c = r else let e = err_of(r) {
        assert(strings.contains(e, why), "expected '" + why + "', got: " + e);
        return;
    }
    panic("accepted a token that should fail on " + why);
}

fn test_should_accept_a_good_google_id_token() {
    let a = fresh(new_fake());
    let r = check_id_token(a, fixture_good(), fixture_nonce(), now_unix());
    guard let c = r else let e = err_of(r) { panic(e); }
    assert(c.sub == "google-sub-7701");
    assert((c.email ?? "") == "g.tester@gmail.com");
}

fn test_should_reject_tokens_failing_any_check() {
    let a = fresh(new_fake());
    expect_rejected(a, fixture_wrong_aud(), fixture_nonce(), "audience");
    expect_rejected(a, fixture_expired(), fixture_nonce(), "expired");
    expect_rejected(a, fixture_unverified(), fixture_nonce(), "not verified");
    expect_rejected(a, fixture_bad_sig(), fixture_nonce(), "does not verify");
    expect_rejected(a, fixture_good(), "another-nonce", "nonce");
    expect_rejected(a, "not.a-token", fixture_nonce(), "");
}

fn test_should_refresh_jwks_once_for_an_unknown_kid() {
    let a = fresh(new_fake());
    expect_rejected(a, fixture_other_kid(), fixture_nonce(), "unknown key");
    assert(len(a.jwks.keys) == 1, "jwks not refreshed for the unknown kid");
    expect_rejected(a, fixture_other_kid(), fixture_nonce(), "unknown key");
}

fn state_of(url: str) -> str {
    let at = strings.find(url, "&state=");
    let rest = strings.slice(url, at + 7, len(url));
    return strings.slice(rest, 0, strings.find(rest, "&"));
}

// The real nonce is random; the fixtures are signed over a fixed one, so
// the test rewrites the stored state to carry it, as Google would echo it.
fn start_with_fixed_nonce(f: Fake, a: Auth[Fake], intent: str, account_id: str) -> str {
    let r = google_start(a, intent, account_id);
    guard let url = r else let fl = err_of(r) { panic(inspect(fl.why)); }
    assert(strings.contains(url, "code_challenge_method=S256"));
    let state = state_of(url);
    let key = "oauth:state:" + encoding.hex_encode(hash_token(state));
    mutex_lock(f.lock);
    assert(has(f.eph, key), "state not stored");
    let saved: result[OAuthState, str] = json.decode(f.eph[key]);
    guard let st = saved else { panic("state unreadable"); }
    st.nonce = fixture_nonce();
    f.eph[key] = json.encode(st);
    mutex_unlock(f.lock);
    return state;
}

fn test_should_sign_up_with_google_then_log_in_with_it() {
    let f = new_fake();
    f.id_token = fixture_good();
    let a = fresh(f);
    let state = start_with_fixed_nonce(f, a, "signup", "");
    let cr = google_callback(a, state, "auth-code", meta());
    guard let cb = cr else let fl = err_of(cr) { panic(inspect(fl.why) + " " + fl.detail); }
    assert(cb.kind == CallbackKind.Pending);
    assert(cb.email_masked == "g•••@gmail.com", cb.email_masked);

    let replay = google_callback(a, state, "auth-code", meta());
    guard let _x = replay else let fl = err_of(replay) {
        assert(fl.why == Why.PendingExpired, inspect(fl.why));
        let hr = hold_username(a, "gtester", "10.0.0.5");
        guard let hold = hr else { panic("hold"); }
        let done = google_complete(a, cb.pending_token, "gtester", hold.hold_id, meta());
        guard let s = done else let df = err_of(done) { panic(inspect(df.why)); }
        guard let grant = s.grant else { panic("no grant"); }
        assert(grant.amount == 1000);
        assert(s.account.google_linked && !s.account.has_password);

        let again = start_with_fixed_nonce(f, a, "login", "");
        let lr = google_callback(a, again, "auth-code-2", meta());
        guard let login_cb = lr else let lf = err_of(lr) { panic(inspect(lf.why)); }
        assert(login_cb.kind == CallbackKind.SignedIn);
        assert(len(login_cb.session_token) > 20);
        return;
    }
    panic("oauth state used twice");
}

fn test_should_refuse_google_for_an_email_a_password_account_owns() {
    let f = new_fake();
    let a = fresh(f);
    let o = new_outbox();
    let hr = hold_username(a, "pwowner", "10.0.0.6");
    guard let hold = hr else { panic("hold"); }
    let sr = signup(a, mailer(o), "pwowner", hold.hold_id, "taken.by.password@say.test", "correct horse", meta());
    guard let _s = sr else { panic("signup"); }
    f.id_token = fixture_existing_email();
    let state = start_with_fixed_nonce(f, a, "login", "");
    let cr = google_callback(a, state, "code", meta());
    guard let _x = cr else let fl = err_of(cr) {
        assert(fl.why == Why.GoogleEmailInUse, inspect(fl.why));
        return;
    }
    panic("auto-linked google to a password account");
}

fn test_should_fail_cleanly_when_google_times_out() {
    let f = new_fake();
    f.id_token = "";
    let a = fresh(f);
    let state = start_with_fixed_nonce(f, a, "signup", "");
    let before = len(f.accounts);
    let cr = google_callback(a, state, "code", meta());
    guard let _x = cr else let fl = err_of(cr) {
        assert(fl.why == Why.GoogleFailed, inspect(fl.why));
        assert(len(f.accounts) == before, "account created on a failed exchange");
        return;
    }
    panic("accepted without google");
}

fn test_should_require_a_session_to_link_google() {
    let a = fresh(new_fake());
    let r = google_start(a, "link", "");
    guard let _u = r else let fl = err_of(r) {
        assert(fl.why == Why.Unauthenticated);
        return;
    }
    panic("link started without a session");
}
