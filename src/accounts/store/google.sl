import "builder";
import "encoding";
import "httpc";
import "json";
import "strings";
import "time";
import "../service" as service;

fn google_deadline(s: Store) -> until {
    return until_of(time.mono() + s.google_timeout);
}

gc struct TokenResponse {
    id_token: opt[str],
    error: opt[str]
}

fn st_google_exchange(s: Store, code: str, verifier: str, redirect_uri: str) -> result[str, str] {
    let body = "grant_type=authorization_code" +
        "&code=" + encoding.form_encode(code) +
        "&client_id=" + encoding.form_encode(s.google.client_id) +
        "&client_secret=" + encoding.form_encode(s.google.client_secret) +
        "&redirect_uri=" + encoding.form_encode(redirect_uri) +
        "&code_verifier=" + encoding.form_encode(verifier);
    let req = httpc.new_request("POST", s.google.token_url);
    req.headers["content-type"] = "application/x-www-form-urlencoded";
    req.headers["accept"] = "application/json";
    req.body = builder.new_bytes().write_str(body).finish();
    req.max_redirects = 0;
    let r = s.http.send(req, google_deadline(s));
    guard let resp = r else let e = err_of(r) {
        return err("google token endpoint: " + e);
    }
    let text = strings.from_bytes(resp.body, 0, len(resp.body));
    let tr: result[TokenResponse, str] = json.decode(text);
    guard let tok = tr else {
        return err("google token endpoint answered " + to_str(resp.status) + " with no JSON");
    }
    if resp.status != 200 {
        return err("google token endpoint " + to_str(resp.status) + ": " + (tok.error ?? "error"));
    }
    guard let id_token = tok.id_token else {
        return err("google token endpoint returned no id_token");
    }
    return ok(id_token);
}

fn max_age_of(cache_control: str) -> int {
    for part in strings.split(cache_control, ",") {
        let p = strings.trim(part);
        if strings.has_prefix(p, "max-age=") {
            return to_int(strings.slice(p, 8, len(p))) ?? 0;
        }
    }
    return 0;
}

fn st_google_jwks(s: Store) -> result[service.JwksDoc, str] {
    let req = httpc.new_request("GET", s.google.jwks_url);
    req.max_redirects = 0;
    let r = s.http.send(req, google_deadline(s));
    guard let resp = r else let e = err_of(r) {
        return err("google jwks: " + e);
    }
    if resp.status != 200 {
        return err("google jwks answered " + to_str(resp.status));
    }
    return ok(service.JwksDoc {
        body: strings.from_bytes(resp.body, 0, len(resp.body)),
        max_age_seconds: max_age_of(resp.header("cache-control") ?? "")
    });
}
