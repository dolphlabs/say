import "zokor";

fn test_without_a_redis_url_the_cache_pool_says_so() {
    let m: map[str]str = {};
    let r = open(zokor.config_from_values(m));
    if let _p = r {
        panic("a pool opened with no REDIS_URL");
    }
}
