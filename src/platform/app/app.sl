import "zokor";
import "../config" as config;
import "../db" as db;
import "../cache" as cache;
import "../../accounts/service" as accounts;
import "../../accounts/store" as accounts_store;

pub gc struct App {
    accounts: accounts.Accounts[accounts_store.Store],
    settings: config.Settings,
    db: opt[db.Db],
    cache: opt[cache.Cache]
}

pub fn build(s: config.Settings, d: db.Db, c: cache.Cache) -> result[App, str] {
    let some_db: opt[db.Db] = some(d);
    let some_cache: opt[cache.Cache] = some(c);
    return ok(App {
        accounts: accounts.new_accounts(accounts_store.on_postgres(d.pool), zokor.new_session_id),
        settings: s,
        db: some_db,
        cache: some_cache
    });
}

pub fn for_tests(s: config.Settings) -> App {
    let none_db: opt[db.Db] = none;
    let none_cache: opt[cache.Cache] = none;
    return App {
        accounts: accounts.new_accounts(accounts_store.in_memory(), zokor.new_session_id),
        settings: s,
        db: none_db,
        cache: none_cache
    };
}
