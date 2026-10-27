import "strings";

fn key_slice(text: str, start: int, size: int) -> str { return strings.slice(text, start, start + size); }

import "json";

fn same_record(a: Record, b: Record) -> bool { return json.encode(a) == json.encode(b); }
