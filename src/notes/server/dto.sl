import "zokor";
import "../domain" as domain;

gc struct NewNote {
    title: str,
    body: str,
}

fn note_json(n: domain.Note) -> zokor.Json {
    return zokor.jobj().set_str("id", n.id).set_str("title", n.title).set_str("body", n.body);
}

fn notes_json(ns: [domain.Note]) -> str {
    let arr = zokor.jarr();
    for n in ns {
        arr.add(note_json(n));
    }
    return zokor.jobj().set("data", arr).render();
}
