import "proc";
import "pg";
import "time";
import "zokor";

fn test_app_role_cannot_rewrite_approval_facts() {
    let url=proc.getenv("TEST_APP_DATABASE_URL") ?? "";
    if len(url)==0 { println("skip approval privilege integration test (TEST_APP_DATABASE_URL not set)"); return; }
    let values: map[str]str={}; values["DATABASE_URL"]=url;
    let opened=zokor.pg_from_config(zokor.config_from_values(values));
    guard let pool=opened else let e=err_of(opened) { panic(e); }
    let args: [pg.Arg]=[];
    denied(pool,"update approval_requests set reason='rewritten' where false");
    denied(pool,"delete from approval_decisions where false");
    denied(pool,"truncate approval_transitions");
    zokor.pg_close(pool);
}

fn denied(pool: pg.Pool, sql: str) {
    let args: [pg.Arg]=[];
    let r=pg.pool_query(pool,sql,args,until_of(time.mono()+2000000000));
    if let _rows=r { panic("immutable approval facts were writable"); }
}
