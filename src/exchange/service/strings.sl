import "strings";
import "../domain" as core;

fn key_slice(text: str, start: int, size: int) -> str { return strings.slice(text, start, start + size); }
pub fn valid_uuid(value: str) -> bool {
    let scratch = core.byte_writer(36);
    return core.canonical_uuid(value, scratch.data);
}

import "json";

fn same_record(a: Record, b: Record) -> bool { return json.encode(a) == json.encode(b); }
