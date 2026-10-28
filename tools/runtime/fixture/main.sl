import "io";
import "json";
import "pg";
import "proc";
import "time";
import "zokor";
import "../../../src/ledger/service" as ledger;
import "../../../src/ledger/store" as ledger_store;
import "../../../src/exchange/domain" as core;
import "../../../src/exchange/service" as exchange;
import "../../../src/exchange/store" as exchange_store;

gc struct Request { op: str, season_id: str, accounts: [str], amount: int, market_id: str }
gc struct FundArg { request: Request }

fn deadline() -> until { return until_of(time.mono()+120000000000); }

fn fund(conn: pg.Conn,arg: FundArg) -> result[bool,str] {
    let batch=ledger.journal_batch();
    for id in arg.request.accounts {
        let rows=ledger.journal_rows();
        ledger.journal_entry(rows,"system","system:treasury","SEDI","free",0-arg.request.amount,"");
        ledger.journal_entry(rows,"user",id,"SEDI","free",arg.request.amount,"");
        ledger.journal_append(batch,rows,"fixture:"+id,"ADJUSTMENT",arg.request.season_id,"","test",id);
    }
    let posted=ledger_store.post_many_encoded(conn,batch.transactions,deadline());
    guard let _posted=posted else let e=err_of(posted) { return err(e); }
    return ok(true);
}

let url=proc.getenv("TEST_APP_DATABASE_URL") ?? "";
let opened=pg.new_pool(url,2);
guard let pool=opened else let e=err_of(opened) { panic(e); }
let input=io.read_all();
guard let data=input else let e=err_of(input) { panic(e); }
let decoded:result[Request,str]=json.decode(to_str(data));
guard let request=decoded else let e=err_of(decoded) { panic(e); }
if request.op=="fund" {
    let funded=zokor.transaction(pool,FundArg { request:request },fund,deadline());
    guard let _funded=funded else let e=err_of(funded) { panic(e); }
    println("true");
} else if request.op=="reconcile" {
    let store=ledger_store.ledger_store(ledger_store.new_postgres(pool,none,120000000000,50000000));
    let scanned=store.recon_run(store.context,true);
    guard let run=scanned else let e=err_of(scanned) { panic(e); }
    println(json.encode(run));
} else if request.op=="recover" {
    let store=exchange_store.recovery_store(exchange_store.new_postgres(pool,120000000000));
    let restored=exchange.recover_book(store,request.market_id,128);
    guard let book=restored else let e=err_of(restored) { panic(e); }
    println(json.encode(core.snapshot(&book)));
} else { panic("unknown runtime fixture operation"); }
pg.pool_close(pool);
