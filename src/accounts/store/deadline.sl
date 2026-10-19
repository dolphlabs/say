import "time";
import "../service" as service;

// httpc does not apply a request's deadline to connecting (net.dial and
// net.tls_dial take none), so an unreachable host holds a call for the
// OS connect timeout, over a minute. The call runs in its own task and
// races a timer; the caller always has an answer by the deadline. A lost
// call finishes on its own and its answer is dropped.
fn timer[T](out: chan[result[T, str]], ns: int, what: str) {
    time.sleep(ns);
    select {
        case chan_send(out, err(what + " timed out")) {}
        default {}
    }
}

fn first_answer[T](out: chan[result[T, str]], ns: int, what: str) -> result[T, str] {
    spawn timer(out, ns, what);
    let got = chan_recv(out);
    guard let r = got else {
        return err(what + " gave no answer");
    }
    return r;
}

gc struct ExchangeCall {
    s: Store,
    code: str,
    verifier: str,
    redirect_uri: str,
    out: chan[result[str, str]]
}

fn run_exchange(x: ExchangeCall) {
    let r = google_exchange_now(x.s, x.code, x.verifier, x.redirect_uri);
    select {
        case chan_send(x.out, r) {}
        default {}
    }
}

gc struct JwksCall {
    s: Store,
    out: chan[result[service.JwksDoc, str]]
}

fn run_jwks(x: JwksCall) {
    let r = google_jwks_now(x.s);
    select {
        case chan_send(x.out, r) {}
        default {}
    }
}

fn st_google_exchange(s: Store, code: str, verifier: str, redirect_uri: str) -> result[str, str] {
    let out: chan[result[str, str]] = make_chan(2);
    spawn run_exchange(ExchangeCall { s: s, code: code, verifier: verifier, redirect_uri: redirect_uri, out: out });
    return first_answer(out, s.google_timeout, "google token endpoint");
}

fn st_google_jwks(s: Store) -> result[service.JwksDoc, str] {
    let out: chan[result[service.JwksDoc, str]] = make_chan(2);
    spawn run_jwks(JwksCall { s: s, out: out });
    return first_answer(out, s.google_timeout, "google jwks");
}
