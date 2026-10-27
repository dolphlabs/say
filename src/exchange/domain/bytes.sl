pub struct ByteWriter {
    memory: arena,
    data: wire,
    position: int,
    failed: bool,
}

pub fn byte_writer(capacity: int) -> ByteWriter {
    assert(capacity > 0 && capacity <= 1073741824);
    let memory = arena_new(capacity + 64);
    let data = memory.wire(capacity);
    return ByteWriter { memory: memory, data: data, position: 0, failed: false };
}

pub fn reset_writer(w: &mut ByteWriter) {
    w.position = 0;
    w.failed = false;
}

pub fn write_byte(w: &mut ByteWriter, value: int) {
    if w.failed { return; }
    if w.position == len(w.data) { w.failed = true; return; }
    w.data[w.position] = value;
    w.position += 1;
}

pub fn write_raw(w: &mut ByteWriter, value: str) {
    if w.failed { return; }
    if len(value) > len(w.data) - w.position { w.failed = true; return; }
    w.position += wire_put(w.data, w.position, value);
}

pub fn write_span(w: &mut ByteWriter, source: wire, start: int, size: int) {
    if w.failed { return; }
    if start < 0 || size < 0 || start > len(source) || size > len(source) - start || size > len(w.data) - w.position {
        w.failed = true;
        return;
    }
    for i in 0..size { w.data[w.position + i] = source[start + i]; }
    w.position += size;
}

pub fn decimal_size(value: int) -> int {
    let n = value;
    let size = 1;
    if n < 0 { size += 1; }
    while n <= -10 || n >= 10 { n /= 10; size += 1; }
    return size;
}

pub fn write_decimal(w: &mut ByteWriter, value: int) {
    let size = decimal_size(value);
    if w.failed { return; }
    if size > len(w.data) - w.position { w.failed = true; return; }
    let n = value;
    if n > 0 { n = 0 - n; }
    let i = w.position + size - 1;
    while true {
        w.data[i] = 48 - n % 10;
        n /= 10;
        i -= 1;
        if n == 0 { break; }
    }
    if value < 0 { w.data[w.position] = 45; }
    w.position += size;
}

pub fn write_text(w: &mut ByteWriter, value: str) {
    write_decimal(&mut *w, len(value));
    write_byte(&mut *w, 58);
    write_raw(&mut *w, value);
}

pub fn write_int(w: &mut ByteWriter, value: int) {
    write_decimal(&mut *w, decimal_size(value));
    write_byte(&mut *w, 58);
    write_decimal(&mut *w, value);
}

pub fn write_bool(w: &mut ByteWriter, value: bool) {
    if value { write_raw(&mut *w, "1:1"); } else { write_raw(&mut *w, "1:0"); }
}

pub fn hex_digit(n: int) -> int {
    if n < 10 { return 48 + n; }
    return 87 + n;
}

pub fn write_hex(w: &mut ByteWriter, source: wire, start: int, size: int) {
    if start < 0 || size < 0 || start > len(source) || size > len(source) - start {
        w.failed = true;
        return;
    }
    for i in 0..size {
        let value = source[start + i];
        write_byte(&mut *w, hex_digit(value >> 4));
        write_byte(&mut *w, hex_digit(value & 15));
    }
}
