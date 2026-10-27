import "fs";
import "os";
import "strings";

fn read_text(path: str) -> str {
    let or = fs.open(path);
    guard let fd = or else let e = err_of(or) { panic(path + ": " + e); }
    let parts: [str] = [];
    while true {
        let r = fs.read(fd as int, 65536);
        guard let chunk = r else let e = err_of(r) { panic(path + ": " + e); }
        if len(chunk) == 0 {
            break;
        }
        push(parts, strings.from_bytes(chunk, 0, len(chunk)));
    }
    let _c = fs.close(fd as int);
    return strings.join(parts, "");
}

fn sources(dir: str, out: [str]) {
    let r = os.read_dir(dir);
    guard let names = r else { return; }
    for n in names {
        let p = dir + "/" + n;
        if os.is_dir(p) {
            sources(p, out);
        } else if strings.has_suffix(n, ".sl") && !strings.has_suffix(n, "_test.sl") {
            push(out, p);
        }
    }
}

fn money_tables() -> [str] {
    return ["ledger_transactions", "ledger_entries", "wallets", "holds", "issuance_grants", "issuance_budget",
            "issuance_policies", "issuance_policy_approvals", "grant_runs", "system_balances", "trading_halt",
            "ledger_watermarks", "reconciliation_runs"];
}

// Postgres cannot tell features apart under one role, so the rule "only
// the ledger writes money" is checked here: no SQL outside the ledger's
// store inserts into, updates or deletes from a money table.
fn test_should_write_money_tables_only_from_the_ledger_store() {
    let files: [str] = [];
    sources("src", files);
    assert(len(files) > 10, "run from the repository root");
    let offenders: [str] = [];
    for f in files {
        if strings.has_prefix(f, "src/ledger/store/") {
            continue;
        }
        let text = strings.to_lower(read_text(f));
        for t in money_tables() {
            for verb in [["insert", "into"], ["update"], ["delete", "from"]] {
                let head = strings.join(verb, " ") + " " + t;
                if strings.contains(text, head + " ") || strings.contains(text, head + "(") {
                    push(offenders, f + ": " + head);
                }
            }
        }
    }
    assert(len(offenders) == 0, inspect(offenders));
}
