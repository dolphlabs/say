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

fn test_ordered_stream_deduplicates_and_rejects_late_market_events() {
    let c=in_memory();
    let market="00000000-0000-4000-a000-000000000001";
    let first=xadd_ordered(c,"stream:market:"+market,market,100,10,2,
        ["id","first","type","trade"]);
    guard let _first=first else { panic("first ordered event failed"); }
    let duplicate=xadd_ordered(c,"stream:market:"+market,market,100,10,2,
        ["id","duplicate","type","trade"]);
    guard let _duplicate=duplicate else { panic("duplicate ordered event failed"); }
    let late=xadd_ordered(c,"stream:market:"+market,market,100,9,9,
        ["id","late","type","trade"]);
    guard let _late=late else { panic("late ordered event failed"); }
    let stored=get(c,"stream:market:"+market+":"+market+":10:2");
    guard let value=stored else { panic("ordered event read failed"); }
    guard let event=value else { panic("original ordered event was lost"); }
    assert(event=="id\nfirst\ntype\ntrade");
    let rejected=get(c,"stream:market:"+market+":"+market+":9:9");
    guard let missing=rejected else { panic("late event read failed"); }
    if let _event=missing { panic("late event advanced the stream"); }
}
