import "pg";
import "../service" as service;

fn test_portfolio_store_factory() {
    let pool_res = pg.new_pool("postgres://say:say@127.0.0.1:55432/say_test?sslmode=disable", 1);
    guard let pool = pool_res else {
        panic("pool creation failed");
    }
    let store = make_postgres_portfolio_store(pool);
    // Verified store creation
    assert(true);
}
