import "time";
import "../domain" as domain;

pub gc struct CachedProfile {
    profile: domain.Profile,
    cached_at: int
}

pub gc struct ProfileService[C] {
    store: ProfileStore[C],
    cache: map[str]CachedProfile,
    cache_lock: mutex
}

pub fn new_service[C](s: ProfileStore[C]) -> ProfileService[C] {
    return ProfileService[C] {
        store: s,
        cache: {},
        cache_lock: make_mutex()
    };
}

pub gc struct GetProfileOutcome {
    status: str, // "FOUND", "REDIRECT", "NOT_FOUND"
    redirect_username: str,
    profile: opt[domain.Profile]
}

pub fn get_profile[C](svc: ProfileService[C], raw_username: str, base_url: str, now_ms: int) -> result[GetProfileOutcome, str] {
    // 1. Check in-process cache (10 seconds)
    mutex_lock(svc.cache_lock);
    if has(svc.cache, raw_username) {
        let cp = svc.cache[raw_username];
        if (now_ms - cp.cached_at) < 10000 {
            mutex_unlock(svc.cache_lock);
            return ok(GetProfileOutcome {
                status: "FOUND",
                redirect_username: "",
                profile: some(cp.profile)
            });
        }
    }
    mutex_unlock(svc.cache_lock);

    // 2. Query store
    let find_fn = svc.store.find_user;
    let lookup_res = find_fn(svc.store.context, raw_username);
    guard let lookup = lookup_res else let e = err_of(lookup_res) {
        return err(e);
    }

    if !lookup.found {
        let none_prof: opt[domain.Profile] = none;
        return ok(GetProfileOutcome {
            status: "NOT_FOUND",
            redirect_username: "",
            profile: none_prof
        });
    }

    if lookup.redirect_username != "" {
        let none_prof: opt[domain.Profile] = none;
        return ok(GetProfileOutcome {
            status: "REDIRECT",
            redirect_username: lookup.redirect_username,
            profile: none_prof
        });
    }

    if lookup.status == "DELETED" {
        let none_prof: opt[domain.Profile] = none;
        return ok(GetProfileOutcome {
            status: "NOT_FOUND",
            redirect_username: "",
            profile: none_prof
        });
    }

    // 3. Load stats and calls
    let stats_fn = svc.store.load_current_stats;
    let stats_res = stats_fn(svc.store.context, lookup.account_id);
    guard let stats = stats_res else let e = err_of(stats_res) {
        return err(e);
    }

    let calls_fn = svc.store.load_profile_calls;
    let calls_res = calls_fn(svc.store.context, lookup.account_id);
    guard let calls = calls_res else let e = err_of(calls_res) {
        return err(e);
    }

    let share_url = base_url + "/u/" + lookup.username;
    let prof = domain.Profile {
        username: lookup.username,
        avatar_color: lookup.avatar_color,
        joined_season: "Season 01",
        share_url: share_url,
        current_season: stats,
        calls: calls
    };

    // Cache for 10s
    mutex_lock(svc.cache_lock);
    svc.cache[raw_username] = CachedProfile {
        profile: prof,
        cached_at: now_ms
    };
    mutex_unlock(svc.cache_lock);

    return ok(GetProfileOutcome {
        status: "FOUND",
        redirect_username: "",
        profile: some(prof)
    });
}
