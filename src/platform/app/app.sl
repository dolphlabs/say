import "zokor";
import "../config" as config;
import "../../notes/service" as notes;
import "../../notes/store" as notes_store;

pub gc struct App {
    notes: notes.Notes[notes_store.Store],
    settings: config.Settings
}

pub fn build(s: config.Settings) -> result[App, str] {
    return ok(App {
        notes: notes.new_notes(notes_store.in_memory(), zokor.new_session_id),
        settings: s
    });
}

pub fn for_tests(s: config.Settings) -> App {
    return App {
        notes: notes.new_notes(notes_store.in_memory(), zokor.new_session_id),
        settings: s
    };
}
