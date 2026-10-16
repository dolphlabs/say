// What a note is, and the rules every note keeps. Pure: no I/O, no clock,
// no configuration, no zokor -- so each rule is tested directly
// (note_test.sl), and the layers above can trust a Note they are given.

pub gc struct Note {
    id: str,
    tenant_id: str,
    title: str,
    body: str,
}

// A rule a note's field broke, named by the field the client sent.
pub gc struct Problem {
    field: str,
    reason: str,
}

pub fn max_title_bytes() -> int {
    return 200;
}

pub fn max_body_bytes() -> int {
    return 10000;
}

// Every problem with a note's fields at once; empty when it is valid.
pub fn problems(title: str, body: str) -> [Problem] {
    let out: [Problem] = [];
    if len(title) == 0 {
        push(out, Problem { field: "title", reason: "must not be empty" });
    } else if len(title) > max_title_bytes() {
        push(out, Problem { field: "title",
                            reason: "must be at most " + to_str(max_title_bytes()) + " bytes" });
    }
    if len(body) > max_body_bytes() {
        push(out, Problem { field: "body",
                            reason: "must be at most " + to_str(max_body_bytes()) + " bytes" });
    }
    return out;
}
