fn test_base32_roundtrip() {
    let text = "Hello, Say Exchange!";
    let b = to_bytes(text);
    let encoded = base32_encode(b);
    let decoded_res = base32_decode(encoded);
    guard let decoded = decoded_res else let e = err_of(decoded_res) {
        panic("base32_decode failed: " + e);
    }
    assert(to_str(decoded) == text);
}

fn test_totp_generation_and_verification() {
    let sec_res = generate_totp_secret();
    guard let secret = sec_res else let e = err_of(sec_res) {
        panic("generate_totp_secret failed: " + e);
    }
    assert(len(secret) == 32);

    let t = 1700000000;
    let code = totp_code_at(secret, t);
    assert(len(code) == 6);

    // Verifying with valid code and time
    let v_res = verify_totp(secret, code, t, 0);
    guard let step = v_res else let e = err_of(v_res) {
        panic("verify_totp failed: " + e);
    }
    assert(step == compute_step(t));

    // Replay with same step should fail
    let replay_res = verify_totp(secret, code, t, step);
    if let _ = replay_res { panic("expected replay error"); }

    // Wrong code should fail
    let wrong_code = "000000";
    if code == "000000" {
        wrong_code = "111111";
    }
    let bad_res = verify_totp(secret, wrong_code, t, 0);
    if let _ = bad_res { panic("expected error for wrong code"); }

    // Previous step within window should succeed if not replayed
    let code_prev = totp_code_at(secret, t);
    let t_next = t + 25; // still in grace or next
    let v_next = verify_totp(secret, code_prev, t_next, 0);
    guard let _ = v_next else let e = err_of(v_next) {
        panic("expected v_next to succeed: " + e);
    }
}
