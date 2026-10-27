import "encoding";
import "crypto";
import "strings";

fn test_canonical_bytes_cover_unicode_and_integer_extremes() {
    let w = byte_writer(256);
    write_text(&mut w, "₦é");
    write_int(&mut w, 0);
    write_int(&mut w, 9223372036854775807);
    write_int(&mut w, 0 - 9223372036854775807 - 1);
    write_bool(&mut w, true);
    write_bool(&mut w, false);
    assert(!w.failed);
    assert(strings.slice(to_str(to_bytes(w.data)), 0, w.position) == "5:₦é1:019:922337203685477580720:-92233720368547758081:11:0");
    let tiny = byte_writer(2);
    write_text(&mut tiny, "long");
    assert(tiny.failed && tiny.position == 2);
    reset_writer(&mut tiny);
    write_decimal(&mut tiny, -9);
    assert(!tiny.failed && tiny.position == 2);
}

fn test_sha256_known_answers_and_padding_boundaries() {
    let memory = arena_new(4096);
    let input = memory.wire(2048);
    let digest = byte_writer(64);
    let output = digest.data;
    let s = sha256_workspace();
    let h = byte_writer(64);
    for text in ["", "abc", "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"] {
        wire_put(input, 0, text);
        assert(sha256_into(&mut s, input, len(text), output, 0));
        reset_writer(&mut h);
        write_hex(&mut h, output, 0, 32);
        assert(to_str(to_bytes(h.data)) == encoding.hex_encode(crypto.sha256(to_bytes(text))));
    }
    for size in [1, 55, 56, 63, 64, 65, 119, 120, 127, 128, 1000] {
        let text = strings.repeat("a", size);
        wire_put(input, 0, text);
        assert(sha256_into(&mut s, input, size, output, 16));
        reset_writer(&mut h);
        write_hex(&mut h, output, 16, 32);
        assert(to_str(to_bytes(h.data)) == encoding.hex_encode(crypto.sha256(to_bytes(text))), to_str(size));
    }
    assert(!sha256_into(&mut s, input, 2049, output, 0));
    assert(!sha256_into(&mut s, input, 0, output, 33));
}
