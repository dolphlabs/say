import "crypto";
import "encoding";
import "http";
import "strings";
import "zokor";
import "../metrics" as metrics;
import "../../accounts/service" as accounts;
import "../../ledger/service" as ledger;
import "../../treasury/service" as treasury;

fn flag(args: [str], name: str) -> str {
    for i in 0..len(args) {
        if args[i] == "--" + name && i + 1 < len(args) {
            return args[i + 1];
        }
    }
    return "";
}

fn usage() -> str {
    return "usage:\n" +
           "  say admin role grant --account <uuid> --role admin|super_admin\n" +
           "  say admin issuance-policy propose --amount <sedis> --cap <sedis per season> --operator <uuid>\n" +
           "  say admin issuance-policy approve --policy <uuid> --operator <uuid>\n" +
           "  say admin issuance-policy show\n" +
           "  say admin bot create --username <name>\n" +
           "  say admin bot key --bot <uuid>\n" +
           "  say admin bot assign --bot <uuid> --market <uuid>";
}

fn show(v: ledger.PolicyView) -> str {
    return v.id + "  " + v.status + "  amount " + to_str(v.amount) + "  cap " + to_str(v.season_cap) +
           "  proposed by " + v.proposed_by + "  approvals " + to_str(len(v.approvals)) + "/2";
}

gc struct NewKey {
    key: str,
    hash: str,
    prefix: str
}

// The key is shown once and never stored: the database keeps its SHA-256,
// which is what bot sign-in looks up.
fn new_bot_key() -> NewKey {
    let rb = crypto.rand(24);
    guard let b = rb else let e = err_of(rb) {
        panic("crypto.rand failed: " + e);
    }
    let key = "say_bot_" + encoding.hex_encode(b);
    return NewKey { key: key, hash: encoding.hex_encode(crypto.sha256(to_bytes(key))), prefix: strings.slice(key, 0, 12) };
}

fn run_bot(a: App, args: [str], what: str) -> int {
    if what == "bot create" {
        let k = new_bot_key();
        let r = treasury.create_bot(a.treasury, flag(args, "username"), k.hash, k.prefix);
        guard let id = r else let e = err_of(r) {
            println("refused: " + e);
            return 1;
        }
        println("bot " + id);
        println("key " + k.key);
        println("store the key now; it is not shown again");
        return 0;
    }
    if what == "bot key" {
        let k = new_bot_key();
        let r = treasury.issue_bot_key(a.treasury, flag(args, "bot"), k.hash, k.prefix);
        guard let _ok = r else let e = err_of(r) {
            println("refused: " + e);
            return 1;
        }
        println("key " + k.key);
        println("every earlier key for this bot is revoked; store this one now");
        return 0;
    }
    if what == "bot assign" {
        let r = treasury.assign_bot(a.treasury, flag(args, "bot"), flag(args, "market"));
        guard let added = r else let e = err_of(r) {
            println("refused: " + e);
            return 1;
        }
        if added {
            println("assigned, paused with nothing allocated: request a top-up, then resume it");
        } else {
            println("already assigned");
        }
        return 0;
    }
    println(usage());
    return 2;
}

// `say admin ...`: operator commands that run once against the database
// and exit. Every issuance approval is audited in the transaction that
// records it.
pub fn run_admin(a: App, args: [str]) -> int {
    if len(args) < 4 {
        println(usage());
        return 2;
    }
    let what = args[2] + " " + args[3];
    if args[2] == "bot" {
        return run_bot(a, args, what);
    }
    if what == "role grant" {
        let r = accounts.grant_role(a.accounts, flag(args, "account"), flag(args, "role"));
        guard let granted = r else let f = err_of(r) {
            println("refused: " + f.detail);
            return 1;
        }
        if granted {
            println("granted");
        } else {
            println("already held, or no such account");
        }
        return 0;
    }
    if what == "issuance-policy propose" {
        let amount = to_int(flag(args, "amount")) ?? 0;
        let cap = to_int(flag(args, "cap")) ?? 0;
        let r = ledger.propose_policy(a.ledger, amount, cap, flag(args, "operator"));
        guard let id = r else let f = err_of(r) {
            println("refused: " + f.detail);
            return 1;
        }
        println("proposed " + id + "; it needs two approvals from operators");
        return 0;
    }
    if what == "issuance-policy approve" {
        let r = ledger.approve_policy(a.ledger, flag(args, "policy"), flag(args, "operator"));
        guard let v = r else let f = err_of(r) {
            println("refused: " + f.detail);
            return 1;
        }
        println(show(v));
        return 0;
    }
    if what == "issuance-policy show" {
        let r = ledger.policies(a.ledger);
        guard let vs = r else let f = err_of(r) {
            println("failed: " + f.detail);
            return 1;
        }
        for v in vs {
            println(show(v));
        }
        return 0;
    }
    println(usage());
    return 2;
}

// Prometheus text, for a scraper holding METRICS_TOKEN.
pub fn metrics_route(c: zokor.Ctx[App]) -> http.Response {
    if !zokor.constant_time_equal(to_bytes(c.bearer()), to_bytes(c.state.settings.ledger.metrics_token)) {
        return zokor.respond(c.errors, "UNAUTHENTICATED", c.request_id);
    }
    metrics.set(c.state.metrics, "ledger_signals_dropped", ledger.dropped_signals(c.state.ledger));
    return zokor.no_store(http.text_response(200, "OK", "text/plain; version=0.0.4", metrics.render(c.state.metrics)));
}
