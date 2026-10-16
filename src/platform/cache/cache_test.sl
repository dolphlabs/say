import "zokor";

fn test_without_a_redis_url_the_cache_pool_says_so() {
    let m: map[str]str = {};
    let r = open(zokor.config_from_values(m));
    if let _p = r {
        panic("a pool opened with no REDIS_URL");
    }
}

fn test_in_memory_cache_crud() {
    let c = in_memory();
    let s_res = set_ex(c, "test_key", 60, "test_value");
    guard let _ok = s_res else { panic("set_ex failed"); }

    let g_res = get(c, "test_key");
    guard let got = g_res else { panic("get failed"); }
    guard let val = got else { panic("value missing"); }
    assert(val == "test_value");

    let d_res = delete_key(c, "test_key");
    guard let _del_ok = d_res else { panic("delete_key failed"); }

    let missing = get(c, "test_key");
    guard let m = missing else { panic("get missing failed"); }
    if let _v = m {
        panic("value should have been deleted");
    }
}
