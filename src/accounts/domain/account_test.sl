import "encoding";

fn is_none_str(o: opt[str]) -> bool {
    if let _v = o {
        return false;
    }
    return true;
}

fn test_should_accept_usernames_matching_the_spec_regex() {
    for u in ["abc", "a.b", "a_b", "ab_", "name99", "x1234567890123456789", "0ab"] {
        assert(is_none_str(username_problem(u)), "rejected " + u);
    }
}

fn test_should_reject_usernames_outside_the_spec_regex() {
    for u in ["ab", "x12345678901234567890", "_ab", ".ab", "ab.", "a-b", "a b", "Abc", "ab!", "é12"] {
        assert(!is_none_str(username_problem(u)), "accepted " + u);
    }
}

fn test_should_normalize_username_to_lowercase_and_trimmed() {
    assert(normalize_username("  Utee_X ") == "utee_x");
}

fn test_should_detect_reserved_usernames() {
    let reserved = ["say", "admin"];
    assert(is_reserved("admin", reserved));
    assert(!is_reserved("admins", reserved));
}

fn test_should_offer_valid_unreserved_distinct_suggestions() {
    let reserved = ["name_says"];
    let c = suggestion_candidates("name", reserved);
    assert(len(c) >= 3, inspect(c));
    assert(c[0] == "name.ng", inspect(c));
    assert(c[1] == "name99", inspect(c));
    for s in c {
        assert(is_none_str(username_problem(s)), "invalid suggestion " + s);
        assert(s != "name" && s != "name_says", s);
    }
}

fn test_should_fit_suggestions_for_a_twenty_char_base() {
    let c = suggestion_candidates("abcdefghijklmnopqrst", []);
    assert(len(c) >= 3, inspect(c));
    for s in c {
        assert(len(s) <= 20, s);
        assert(is_none_str(username_problem(s)), s);
    }
}

fn test_should_pick_the_first_suggestions_nobody_holds() {
    let picked = pick_suggestions(["a1", "a2", "a3", "a4"], ["A2"], 3);
    assert(inspect(picked) == inspect(["a1", "a3", "a4"]), inspect(picked));
}

fn test_should_normalize_and_validate_email() {
    assert(normalize_email("  Joe@Say.Exchange ") == "joe@say.exchange");
    assert(is_none_str(email_problem("joe@say.exchange")));
    for bad in ["", "joe", "@x.com", "joe@x", "joe@x.", "jo e@x.com", "a@b@c.com"] {
        assert(!is_none_str(email_problem(bad)), "accepted " + bad);
    }
}

fn test_should_mask_email_to_first_letter_and_domain() {
    assert(mask_email("utee@gmail.com") == "u•••@gmail.com");
}

fn test_should_enforce_password_length_bounds() {
    assert(!is_none_str(password_problem("short")));
    assert(is_none_str(password_problem("longenough")));
    let big = "";
    for i in 0..129 {
        big = big + "a";
    }
    assert(!is_none_str(password_problem(big)));
    assert(!is_none_str(password_problem("        ")));
}

fn test_should_score_password_strength_from_zero_to_four() {
    assert(password_strength("short") == 0);
    assert(password_strength("abcdefgh") == 1);
    assert(password_strength("Abcdefgh1234") == 3);
    assert(password_strength("Abcdefgh1234!@#$") == 4);
}

fn test_should_make_six_digit_codes_from_four_bytes() {
    assert((code_from(b"\x00\x00\x00\x07") ?? "") == "000007");
    assert((code_from(b"\x00\x0f\x42\x3f") ?? "") == "999999");
    assert(is_none_str(code_from(b"\xff\xff\xff\xff")));
    assert(is_none_str(code_from(b"\x00\x00")));
}

fn test_should_recognise_only_six_digit_codes() {
    assert(is_code_shape("012345"));
    assert(!is_code_shape("12345"));
    assert(!is_code_shape("12345a"));
}

fn test_should_bind_purpose_and_account_into_the_code_hmac() {
    let key = b"0123456789abcdef0123456789abcdef";
    let v = code_hmac(key, purpose_verify_email(), "acc-1", "123456");
    assert(len(v) == 32);
    assert(encoding.hex_encode(v) == encoding.hex_encode(code_hmac(key, purpose_verify_email(), "acc-1", "123456")));
    assert(encoding.hex_encode(v) != encoding.hex_encode(code_hmac(key, purpose_reset_password(), "acc-1", "123456")));
    assert(encoding.hex_encode(v) != encoding.hex_encode(code_hmac(key, purpose_verify_email(), "acc-2", "123456")));
}

fn test_should_lock_a_code_after_five_misses() {
    assert(otp_state(4, false, false) == OtpState.Live);
    assert(otp_state(5, false, false) == OtpState.Locked);
    assert(otp_state(0, true, false) == OtpState.Expired);
    assert(otp_state(0, false, true) == OtpState.Consumed);
    assert(attempts_left(1) == 4);
    assert(attempts_left(7) == 0);
}

fn test_should_not_auto_link_google_to_an_existing_email() {
    let none_str: opt[str] = none;
    assert(google_link_policy("login", none_str, some("acc-1"), none_str) == GoogleOutcome.EmailInUse);
    assert(google_link_policy("signup", none_str, some("acc-1"), none_str) == GoogleOutcome.EmailInUse);
}

fn test_should_log_in_a_known_google_identity_and_start_signup_for_a_new_one() {
    let none_str: opt[str] = none;
    assert(google_link_policy("login", some("acc-1"), some("acc-1"), none_str) == GoogleOutcome.LogIn);
    assert(google_link_policy("signup", none_str, none_str, none_str) == GoogleOutcome.StartSignup);
}

fn test_should_link_google_only_for_a_signed_in_account() {
    let none_str: opt[str] = none;
    assert(google_link_policy("link", none_str, none_str, none_str) == GoogleOutcome.NeedSession);
    assert(google_link_policy("link", none_str, none_str, some("me")) == GoogleOutcome.Link);
    assert(google_link_policy("link", some("me"), none_str, some("me")) == GoogleOutcome.AlreadyLinked);
    assert(google_link_policy("link", some("other"), none_str, some("me")) == GoogleOutcome.LinkedElsewhere);
}

fn test_should_keep_one_sign_in_method_when_unlinking() {
    assert(can_unlink_google(true));
    assert(!can_unlink_google(false));
}
