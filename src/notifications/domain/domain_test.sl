fn test_order_filled_template() {
    let final_notice = order_filled_template("Enyimba Yes", "YES", 6, 6, 54, true);
    assert(final_notice.title == "Order filled");
    assert(final_notice.body == "6 Enyimba Yes YES @ S 54.");

    let partial_notice = order_filled_template("Enyimba", "Yes", 4, 6, 54, false);
    assert(partial_notice.title == "Order partly filled");
    assert(partial_notice.body == "4 of 6 Enyimba Yes @ S 54. The rest is still waiting.");
}

fn test_market_settled_template() {
    let win = market_settled_template("Remo Stars", true, "Remo Stars", 1000, 599);
    assert(win.title == "You called it");
    assert(win.body == "Remo Stars won. S 1000 paid out (+599).");

    let loss = market_settled_template("Abuja rain", false, "No rain", 0, -151);
    assert(loss.title == "Not this time");
    assert(loss.body == "Abuja rain went the other way (−S 151).");
}

fn test_unsubscribe_token_lifecycle() {
    let secret = "test-secret-key-123";
    let token = sign_unsubscribe_token(secret, "acc-1", "market_settled", 2000000000);

    let verify_res = verify_unsubscribe_token(secret, token, 1700000000);
    guard let tok = verify_res else {
        panic("verify failed");
    }
    assert(tok.account_id == "acc-1");
    assert(tok.kind == "market_settled");
    assert(tok.expires_at == 2000000000);

    // Tampered token
    let bad_token = "acc-2.market_settled.2000000000.invalidsig";
    let bad_res = verify_unsubscribe_token(secret, bad_token, 1700000000);
    if let _ = bad_res {
        panic("expected failure for tampered token");
    }

    // Expired token
    let exp_res = verify_unsubscribe_token(secret, token, 2100000000);
    if let _ = exp_res {
        panic("expected failure for expired token");
    }
}
