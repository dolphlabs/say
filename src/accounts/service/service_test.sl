import "time";

fn wait_for_mail(o: Outbox, n: int) -> bool {
    for i in 0..200 {
        mutex_lock(o.lock);
        let have = len(o.mails);
        mutex_unlock(o.lock);
        if have >= n {
            return true;
        }
        time.sleep(2000000);
    }
    return false;
}

fn signed_up(a: Auth[Fake], o: Outbox, name: str) -> SignupStarted {
    let hr = hold_username(a, name, "10.0.0.9");
    guard let hold = hr else let f = err_of(hr) { panic("hold " + inspect(f.why)); }
    let r = signup(a, mailer(o), name, hold.hold_id, name + "@say.test", "correct horse", meta());
    guard let s = r else let fs = err_of(r) { panic("signup " + inspect(fs[0].why)); }
    return s;
}

fn test_should_sign_up_verify_and_grant_one_thousand() {
    let f = new_fake();
    let a = fresh(f);
    let o = new_outbox();
    let s = signed_up(a, o, "utee");
    assert(s.email_masked == "u•••@say.test", s.email_masked);
    assert(wait_for_mail(o, 1), "verification email never sent");
    let code = last_code(o);
    assert(len(code) == 6, code);
    let vr = verify_signup(a, s.signup_token, code, meta());
    guard let v = vr else let fl = err_of(vr) { panic("verify " + inspect(fl.why)); }
    guard let grant = v.grant else { panic("no grant"); }
    assert(grant.amount == 1000);
    assert(v.account.email_verified);
    let sess = authenticate(a, v.session_token);
    guard let found = sess else { panic("auth failed"); }
    guard let session = found else { panic("session not found"); }
    assert(session.account_id == v.account.id);
}

fn test_should_never_store_or_log_the_code_in_the_outbox_payload() {
    let f = new_fake();
    let a = fresh(f);
    let o = new_outbox();
    o.fail = true;
    let _s = signed_up(a, o, "sealed");
    mutex_lock(f.lock);
    let payloads: [str] = [];
    for k, p in f.outbox { push(payloads, p); }
    mutex_unlock(f.lock);
    assert(len(payloads) == 1);
    o.fail = false;
    assert(deliver(a, mailer(o), "") == 1);
    let code = last_code(o);
    assert(!contains(payloads[0], "\"" + code + "\""), "plain code in payload");
    assert(contains(payloads[0], "\"sealed\""));
}

fn test_should_retry_delivery_after_the_provider_recovers() {
    let f = new_fake();
    let a = fresh(f);
    let o = new_outbox();
    o.fail = true;
    let _s = signed_up(a, o, "retry1");
    time.sleep(20000000);
    assert(len(o.mails) == 0);
    mutex_lock(f.lock);
    let pending = len(f.outbox);
    mutex_unlock(f.lock);
    assert(pending == 1, "row not kept for retry");
    o.fail = false;
    assert(deliver(a, mailer(o), "") == 1);
    assert(len(o.mails) == 1);
}

fn test_should_lock_after_five_wrong_codes_and_refuse_the_right_one() {
    let f = new_fake();
    let a = fresh(f);
    let o = new_outbox();
    let s = signed_up(a, o, "locky");
    assert(wait_for_mail(o, 1));
    let code = last_code(o);
    let wrong = "000000";
    if code == wrong { wrong = "111111"; }
    for i in 0..5 {
        let r = verify_signup(a, s.signup_token, wrong, meta());
        guard let _v = r else let fl = err_of(r) {
            assert(fl.why == Why.OtpInvalid, inspect(fl.why));
            assert(fl.attempts_left == 4 - i, "attempts_left " + to_str(fl.attempts_left));
            continue;
        }
        panic("wrong code accepted");
    }
    let r = verify_signup(a, s.signup_token, code, meta());
    guard let _v = r else let fl = err_of(r) {
        assert(fl.why == Why.OtpLocked, inspect(fl.why));
        return;
    }
    panic("locked code accepted");
}

fn test_should_reject_a_malformed_code_without_counting_it() {
    let f = new_fake();
    let a = fresh(f);
    let o = new_outbox();
    let s = signed_up(a, o, "shape");
    let r = verify_signup(a, s.signup_token, "12ab", meta());
    guard let _v = r else let fl = err_of(r) {
        assert(fl.why == Why.OtpInvalid);
        assert(fl.attempts_left == -1);
        return;
    }
    panic("accepted");
}

fn test_should_report_every_signup_field_problem() {
    let f = new_fake();
    let a = fresh(f);
    let r = signup(a, mailer(new_outbox()), "A!", "h", "nope", "short", meta());
    guard let _s = r else let fs = err_of(r) {
        assert(len(fs) == 3, inspect(len(fs)));
        assert(fs[0].why == Why.UsernameInvalid);
        assert(fs[1].why == Why.EmailInvalid);
        assert(fs[2].why == Why.WeakPassword);
        return;
    }
    panic("accepted");
}

fn test_should_refuse_signup_without_the_matching_hold() {
    let f = new_fake();
    let a = fresh(f);
    let r = signup(a, mailer(new_outbox()), "noholder", "bogus", "n@say.test", "correct horse", meta());
    guard let _s = r else let fs = err_of(r) {
        assert(fs[0].why == Why.UsernameHoldExpired, inspect(fs[0].why));
        return;
    }
    panic("accepted");
}

fn test_should_map_a_lost_username_race_to_username_taken() {
    let f = new_fake();
    let a = fresh(f);
    let o = new_outbox();
    let _s = signed_up(a, o, "racer");
    f.eph_down = true;
    let r = signup(a, mailer(o), "racer", "any", "other@say.test", "correct horse", meta());
    guard let _x = r else let fs = err_of(r) {
        assert(fs[0].why == Why.UsernameTaken, inspect(fs[0].why));
        return;
    }
    panic("duplicate username accepted");
}

fn test_should_say_invalid_credentials_for_every_login_failure() {
    let f = new_fake();
    let a = fresh(f);
    let o = new_outbox();
    let s = signed_up(a, o, "loginer");
    assert(wait_for_mail(o, 1));
    let _v = verify_signup(a, s.signup_token, last_code(o), meta());
    for attempt in [["nobody@say.test", "correct horse"], ["loginer@say.test", "wrong horse"], ["", ""]] {
        let r = login(a, attempt[0], attempt[1], meta());
        guard let _x = r else let fl = err_of(r) {
            assert(fl.why == Why.InvalidCredentials, inspect(fl.why));
            continue;
        }
        panic("login accepted " + attempt[0]);
    }
    let good = login(a, "  LOGINER@say.test ", "correct horse", meta());
    guard let signed = good else let fl = err_of(good) { panic(inspect(fl.why)); }
    assert(signed.account.username == "loginer");
}

fn test_should_return_email_not_verified_with_a_fresh_signup_token() {
    let f = new_fake();
    let a = fresh(f);
    let o = new_outbox();
    let _s = signed_up(a, o, "unverif");
    let r = login(a, "unverif@say.test", "correct horse", meta());
    guard let _x = r else let fl = err_of(r) {
        assert(fl.why == Why.EmailNotVerified, inspect(fl.why));
        assert(len(fl.signup_token) > 20);
        let again = resend(a, mailer(o), fl.signup_token, "", "verify_email", meta());
        guard let _q = again else let rf = err_of(again) {
            assert(rf.why == Why.RateLimited, inspect(rf.why));
            assert(rf.retry_after > 0 && rf.retry_after <= 60);
            return;
        }
        panic("resend inside the cooldown");
    }
    panic("unverified login accepted");
}

fn test_should_not_reveal_unverified_status_on_a_wrong_password() {
    let f = new_fake();
    let a = fresh(f);
    let _s = signed_up(a, new_outbox(), "quiet");
    let r = login(a, "quiet@say.test", "wrong horse", meta());
    guard let _x = r else let fl = err_of(r) {
        assert(fl.why == Why.InvalidCredentials, inspect(fl.why));
        return;
    }
    panic("accepted");
}

fn test_should_rate_limit_login_by_email_even_when_redis_is_down() {
    let f = new_fake();
    f.eph_down = true;
    let a = fresh(f);
    let limited = false;
    for i in 0..12 {
        let r = login(a, "victim@say.test", "guess " + to_str(i), Meta { ip: "10.1.1." + to_str(i), user_agent: "" });
        if let _ok = r {
        } else let fl = err_of(r) {
            if fl.why == Why.RateLimited {
                limited = true;
                assert(i == 10, "limited at " + to_str(i));
                break;
            }
        }
    }
    assert(limited, "11th attempt not limited");
}

fn slow_hash(p: str) -> result[str, str] {
    time.sleep(50000000);
    return ok("stub$" + p);
}

fn slow_verify(p: str, enc: str) -> result[bool, str] {
    time.sleep(50000000);
    return ok(false);
}

gc struct Tally {
    lock: mutex,
    busy: int,
    done: int
}

fn hammer(h: Hasher, t: Tally, out: chan[int]) {
    let r = verify_with(h, "pw", "x");
    mutex_lock(t.lock);
    if let _v = r {
        t.done += 1;
    } else let e = err_of(r) {
        if e == HashFail.Busy {
            t.busy += 1;
        }
    }
    mutex_unlock(t.lock);
    chan_send(out, 1);
}

fn test_should_reject_hashing_with_busy_when_the_queue_is_full() {
    let h = new_hasher(1, 2, slow_hash, slow_verify);
    let t = Tally { lock: make_mutex(), busy: 0, done: 0 };
    let out: chan[int] = make_chan(20);
    for i in 0..20 {
        spawn hammer(h, t, out);
    }
    for i in 0..20 {
        let _x = chan_recv(out);
    }
    assert(t.busy > 0, "nothing was refused");
    assert(t.done >= 1 && t.done + t.busy == 20, inspect(t.done) + " " + inspect(t.busy));
}

fn test_should_batch_audit_events_and_drop_when_full() {
    let f = new_fake();
    let a = fresh(f);
    spawn run_audit_writer(a);
    for i in 0..250 {
        record(a.audit, AuditEvent { actor_id: "", action: "login", ip: "", user_agent: "", detail_json: "{}" });
    }
    for i in 0..100 {
        if audit_written(a.audit) >= 250 { break; }
        time.sleep(10000000);
    }
    assert(audit_written(a.audit) == 250, inspect(audit_written(a.audit)));

    let tiny = new_audit_log(2);
    for i in 0..5 {
        record(tiny, AuditEvent { actor_id: "", action: "x", ip: "", user_agent: "", detail_json: "{}" });
    }
    assert(audit_dropped(tiny) == 3);
}

fn test_should_reject_a_revoked_session_with_and_without_redis() {
    let f = new_fake();
    let a = fresh(f);
    let o = new_outbox();
    let s = signed_up(a, o, "revoker");
    assert(wait_for_mail(o, 1));
    let vr = verify_signup(a, s.signup_token, last_code(o), meta());
    guard let v = vr else { panic("verify"); }
    let ar = authenticate(a, v.session_token);
    guard let found = ar else { panic("auth"); }
    guard let session = found else { panic("none"); }
    let _l = logout(a, session, meta());
    let after = authenticate(a, v.session_token);
    guard let none_now = after else { panic("auth err"); }
    if let _x = none_now { panic("revoked session accepted with redis"); }

    f.eph_down = true;
    let off = authenticate(a, v.session_token);
    guard let none_off = off else { panic("auth err without redis"); }
    if let _x = none_off { panic("revoked session accepted without redis"); }
}

fn test_should_revoke_every_session_on_password_reset() {
    let f = new_fake();
    let a = fresh(f);
    let o = new_outbox();
    let s = signed_up(a, o, "resetter");
    assert(wait_for_mail(o, 1));
    let vr = verify_signup(a, s.signup_token, last_code(o), meta());
    guard let v = vr else { panic("verify"); }
    f.last_send = {};
    assert(is_none_failed(forgot_password(a, mailer(o), "resetter@say.test", meta())));
    assert(wait_for_mail(o, 2));
    let rr = reset_password(a, "resetter@say.test", last_code(o), "brand new horse", meta());
    guard let revoked = rr else let fl = err_of(rr) { panic(inspect(fl.why)); }
    assert(revoked == 1);
    let after = authenticate(a, v.session_token);
    guard let none_now = after else { panic("auth err"); }
    if let _x = none_now { panic("old session survived reset"); }
    let good = login(a, "resetter@say.test", "brand new horse", meta());
    guard let _g = good else { panic("new password refused"); }
}

fn is_none_failed(o: opt[Failed]) -> bool {
    if let _f = o { return false; }
    return true;
}

fn test_should_not_let_a_verify_code_reset_a_password() {
    let f = new_fake();
    let a = fresh(f);
    let o = new_outbox();
    let _s = signed_up(a, o, "crosser");
    assert(wait_for_mail(o, 1));
    let r = reset_password(a, "crosser@say.test", last_code(o), "brand new horse", meta());
    guard let _x = r else let fl = err_of(r) {
        assert(fl.why == Why.OtpExpired || fl.why == Why.OtpInvalid, inspect(fl.why));
        return;
    }
    panic("verify code reset the password");
}

fn test_should_answer_forgot_password_the_same_for_unknown_emails() {
    let f = new_fake();
    let a = fresh(f);
    let o = new_outbox();
    assert(is_none_failed(forgot_password(a, mailer(o), "ghost@say.test", meta())));
    time.sleep(10000000);
    assert(len(o.mails) == 0);
}

fn test_should_keep_the_current_session_on_password_change() {
    let f = new_fake();
    let a = fresh(f);
    let o = new_outbox();
    let s = signed_up(a, o, "changer");
    assert(wait_for_mail(o, 1));
    let vr = verify_signup(a, s.signup_token, last_code(o), meta());
    guard let v = vr else { panic("verify"); }
    let other = login(a, "changer@say.test", "correct horse", meta());
    guard let second = other else { panic("second login"); }
    let ar = authenticate(a, v.session_token);
    guard let found = ar else { panic("auth"); }
    guard let current = found else { panic("none"); }
    let cr = change_password(a, current, "correct horse", "another long one", meta());
    guard let n = cr else let fl = err_of(cr) { panic(inspect(fl.why)); }
    assert(n == 1, inspect(n));
    let still = authenticate(a, v.session_token);
    guard let keep = still else { panic("auth"); }
    guard let _k = keep else { panic("current session revoked"); }
    let gone = authenticate(a, second.session_token);
    guard let g = gone else { panic("auth"); }
    if let _x = g { panic("other session survived"); }
}

fn test_should_refuse_to_unlink_google_from_a_password_less_account() {
    let f = new_fake();
    let a = fresh(f);
    let cr = f_create_google(f, GoogleSignup {
        account_id: "g1", username: "googler", email: "g@say.test", subject: "sub-1",
        session: NewSession { token_hash: hash_token("t"), ttl_seconds: 60, ip: "", user_agent: "" }
    });
    guard let _c = cr else { panic("create"); }
    let r = unlink_google(a, Session { account_id: "g1", token_hash: hash_token("t") }, meta());
    guard let _x = r else let fl = err_of(r) {
        assert(fl.why == Why.LastSignInMethod, inspect(fl.why));
        return;
    }
    panic("unlinked the last sign-in method");
}

fn test_should_suggest_names_for_a_taken_username() {
    let f = new_fake();
    let a = fresh(f);
    let _s = signed_up(a, new_outbox(), "taken");
    let r = check_username(a, "Taken", "10.0.0.2");
    guard let c = r else { panic("check"); }
    assert(!c.available);
    assert(c.reason == "USERNAME_TAKEN");
    assert(len(c.suggestions) == 3, inspect(c.suggestions));
    let reserved = check_username(a, "admin", "10.0.0.2");
    guard let rc = reserved else { panic("check"); }
    assert(rc.reason == "USERNAME_RESERVED");
    let bad = check_username(a, "a", "10.0.0.2");
    guard let bc = bad else { panic("check"); }
    assert(bc.reason == "USERNAME_INVALID");
    let free = check_username(a, "freebird", "10.0.0.2");
    guard let fc = free else { panic("check"); }
    assert(fc.available);
}

fn test_should_treat_a_held_name_as_taken() {
    let f = new_fake();
    let a = fresh(f);
    let _h = hold_username(a, "heldname", "10.0.0.3");
    let second = hold_username(a, "heldname", "10.0.0.4");
    guard let _x = second else let fl = err_of(second) {
        assert(fl.why == Why.UsernameTaken);
        let c = check_username(a, "heldname", "10.0.0.4");
        guard let cc = c else { panic("check"); }
        assert(!cc.available && cc.reason == "USERNAME_TAKEN");
        return;
    }
    panic("double hold");
}

fn test_should_round_trip_a_sealed_code() {
    let key = to_bytes("k-0123456789abcdef0123456789abcdef");
    let sealed = seal_code(key, b"nonce-1", "042917");
    assert(sealed != "042917");
    assert((unseal_code(key, b"nonce-1", sealed) ?? "") == "042917");
    assert((unseal_code(key, b"nonce-2", sealed) ?? "") != "042917");
}

fn test_should_back_off_exponentially_to_an_hour() {
    assert(outbox_backoff_seconds(0) == 1);
    assert(outbox_backoff_seconds(3) == 8);
    assert(outbox_backoff_seconds(30) == 3600);
}

fn test_should_list_an_operator_roles() {
    let f = new_fake();
    let r = roles_of(fresh(f), "admin-1");
    guard let roles = r else { panic("roles"); }
    assert(len(roles) == 1 && roles[0] == "admin");
}

fn test_should_refuse_unknown_roles() {
    let f = new_fake();
    if let _ok = grant_role(fresh(f), "admin-1", "owner") {
        panic("unknown role accepted");
    }
}
