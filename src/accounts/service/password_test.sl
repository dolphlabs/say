fn test_password_hashing_and_verification() {
    let raw = "ValidPass123!";
    let res = hash_password(raw);
    guard let h = res else let e = err_of(res) {
        assert(false, "hash failed: " + e);
        return;
    }

    let ok_res = verify_password(raw, h);
    guard let matched = ok_res else let e = err_of(ok_res) {
        assert(false, "verify failed: " + e);
        return;
    }
    assert(matched, "password should match");

    let bad_res = verify_password("WrongPassword123!", h);
    guard let bad_matched = bad_res else let e = err_of(bad_res) {
        assert(false, "verify bad failed: " + e);
        return;
    }
    assert(!bad_matched, "wrong password should not match");
}
