fn test_create_registers_account() {
    let f = fake_store();
    let none_str: opt[str] = none;
    let made = create(fake_accounts(f), "acc_1", some("trader@say.exchange"), none_str, "LOCAL");
    guard let n = made else { panic("create failed"); }
    assert(n.id == "acc_1");
    assert(n.auth_provider == "LOCAL");
    assert(f.calls[0] == "insert acc_1", f.calls[0]);
}

fn test_invalid_auth_provider_is_rejected() {
    let f = fake_store();
    let none_str: opt[str] = none;
    let made = create(fake_accounts(f), "acc_1", some("trader@say.exchange"), none_str, "TWITTER");
    guard let _n = made else let e = err_of(made) {
        assert(e.why == Why.Invalid && e.problems[0].field == "auth_provider");
        assert(len(f.calls) == 0, "the store was called");
        return;
    }
    panic("an invalid auth_provider was accepted");
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
