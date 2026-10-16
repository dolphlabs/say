fn test_create_registers_account() {
    let f = fake_store();
    let none_str: opt[str] = none;
    let made = create(fake_accounts(f), "acc_1", some("trader@say.exchange"), none_str, "LOCAL");
    guard let n = made else { panic("create failed"); }
    assert(n.id == "acc_1");
    assert(n.auth_provider == "LOCAL");
    assert(f.calls[0] == "insert acc_1", f.calls[0]);
}

fn test_check_username_availability() {
    let f = fake_store();
    let accs = fake_accounts(f);

    // Available
    let ok_res = check_username(accs, "t1", "valid_user");
    guard let _avail = ok_res else { panic("username should be available"); }

    // Invalid username format
    let bad_res = check_username(accs, "t1", "no");
    guard let _b = bad_res else let e = err_of(bad_res) {
        assert(e.why == Why.Invalid);
        return;
    }
    panic("invalid username accepted");
}

fn test_create_with_password_flow() {
    let f = fake_store();
    let accs = fake_accounts(f);
    let meta = AuditMeta {
        ip_address: some("127.0.0.1"),
        user_agent: some("Mozilla/5.0"),
        fingerprint: some("fp123"),
        detail_json: "{\"browser\":\"Chrome\"}"
    };

    let made = create_with_password(accs, "t1", "trader_joe", "joe@say.exchange", "ValidPass123!", some("+2348012345678"), meta);
    guard let a = made else { panic("create_with_password failed"); }
    assert(a.id == "acc_1");
    assert((a.username ?? "") == "trader_joe");
    assert((a.email ?? "") == "joe@say.exchange");
    assert((a.phone_number ?? "") == "+2348012345678");
    guard let h = a.password_hash else { panic("missing password hash"); }
    assert(len(h) > 0);

    // Duplicate username should fail
    let none_str: opt[str] = none;
    let dup_u = create_with_password(accs, "t1", "trader_joe", "other@say.exchange", "ValidPass123!", none_str, meta);
    guard let _d = dup_u else let e = err_of(dup_u) {
        assert(e.why == Why.UsernameTaken);
        return;
    }
    panic("duplicate username accepted");
}

fn test_create_with_password_duplicate_email() {
    let f = fake_store();
    let accs = fake_accounts(f);
    let none_str: opt[str] = none;
    let meta = AuditMeta {
        ip_address: none_str,
        user_agent: none_str,
        fingerprint: none_str,
        detail_json: "{}"
    };

    let _m = create_with_password(accs, "t1", "user_one", "same@say.exchange", "ValidPass123!", none_str, meta);
    let dup_e = create_with_password(accs, "t1", "user_two", "same@say.exchange", "ValidPass123!", none_str, meta);
    guard let _d = dup_e else let e = err_of(dup_e) {
        assert(e.why == Why.EmailTaken);
        return;
    }
    panic("duplicate email accepted");
}

fn test_create_with_password_weak_password_rejected() {
    let f = fake_store();
    let accs = fake_accounts(f);
    let none_str: opt[str] = none;
    let meta = AuditMeta {
        ip_address: none_str,
        user_agent: none_str,
        fingerprint: none_str,
        detail_json: "{}"
    };

    let weak = create_with_password(accs, "t1", "user_weak", "weak@say.exchange", "weakpass", none_str, meta);
    guard let _w = weak else let e = err_of(weak) {
        assert(e.why == Why.Invalid);
        return;
    }
    panic("weak password accepted");
}

fn test_get_by_email() {
    let f = fake_store();
    let none_str: opt[str] = none;
    let _m = create(fake_accounts(f), "acc_1", some("trader@say.exchange"), none_str, "GOOGLE");
    let found = get_by_email(fake_accounts(f), "acc_1", "trader@say.exchange");
    guard let a = found else { panic("not found by email"); }
    assert(a.id == "acc_1");

    let missing = get_by_email(fake_accounts(f), "acc_1", "nobody@say.exchange");
    guard let _none = missing else let e = err_of(missing) {
        assert(e.why == Why.NotFound);
        return;
    }
    panic("found non-existent email");
}

fn test_a_failing_store_is_unavailable_with_its_detail_kept() {
    let f = fake_store();
    f.failure = "connection refused";
    let r = list(fake_accounts(f), "acc_1", 0, 10);
    guard let _rows = r else let e = err_of(r) {
        assert(e.why == Why.Unavailable && e.detail == "connection refused");
        return;
    }
    panic("a failing store succeeded");
}
