import "zokor";
import "platform/app" as app;
import "platform/config" as config;
import "notes/server" as notes;

let cfg = zokor.load_config();
let settings = config.settings_from(cfg);
let checked = zokor.check(cfg);

guard let _ok = checked else let e = err_of(checked) {
    println(e);
    exit(2);
}

let built = app.build(settings);
guard let state = built else let e = err_of(built) {
    println("cannot start: " + e);
    exit(1);
}

let r = zokor.new_router(state);
r.health();
notes.mount(r);

settings.server.request_ids = false;
// settings.server.logger = zokor.no_logger();

let served = zokor.listen_and_serve_with(r, settings.port, settings.server);

guard let _done = served else {
    exit(1);
}
