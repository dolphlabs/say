pub struct Sha256 {
    constants: [int],
    schedule: [int],
    words: [int],
}

pub fn sha256_workspace() -> Sha256 {
    let constants: [int] = [
        1116352408, 1899447441, 3049323471, 3921009573, 961987163, 1508970993, 2453635748, 2870763221,
        3624381080, 310598401, 607225278, 1426881987, 1925078388, 2162078206, 2614888103, 3248222580,
        3835390401, 4022224774, 264347078, 604807628, 770255983, 1249150122, 1555081692, 1996064986,
        2554220882, 2821834349, 2952996808, 3210313671, 3336571891, 3584528711, 113926993, 338241895,
        666307205, 773529912, 1294757372, 1396182291, 1695183700, 1986661051, 2177026350, 2456956037,
        2730485921, 2820302411, 3259730800, 3345764771, 3516065817, 3600352804, 4094571909, 275423344,
        430227734, 506948616, 659060556, 883997877, 958139571, 1322822218, 1537002063, 1747873779,
        1955562222, 2024104815, 2227730452, 2361852424, 2428436474, 2756734187, 3204031479, 3329325298
    ];
    let schedule: [int] = [];
    let words: [int] = [];
    for i in 0..64 { push(schedule, 0); }
    for i in 0..8 { push(words, 0); }
    return Sha256 { constants: constants, schedule: schedule, words: words };
}

fn rotate32(x: int, n: int) -> int {
    return ((x >> n) | (x << (32 - n))) & 4294967295;
}

fn sha_byte(input: wire, size: int, offset: int, padded: int) -> int {
    if offset < size { return input[offset]; }
    if offset == size { return 128; }
    if offset >= padded - 8 { return ((size * 8) >> ((padded - offset - 1) * 8)) & 255; }
    return 0;
}

pub fn sha256_into(s: &mut Sha256, input: wire, size: int, output: wire, offset: int) -> bool {
    if size < 0 || size > len(input) || offset < 0 || offset > len(output) || len(output) - offset < 32 { return false; }
    s.words[0] = 1779033703;
    s.words[1] = 3144134277;
    s.words[2] = 1013904242;
    s.words[3] = 2773480762;
    s.words[4] = 1359893119;
    s.words[5] = 2600822924;
    s.words[6] = 528734635;
    s.words[7] = 1541459225;
    let padded = ((size + 72) / 64) * 64;
    let base = 0;
    while base < padded {
        for i in 0..16 {
            let at = base + i * 4;
            s.schedule[i] = (sha_byte(input, size, at, padded) << 24) |
                            (sha_byte(input, size, at + 1, padded) << 16) |
                            (sha_byte(input, size, at + 2, padded) << 8) |
                            sha_byte(input, size, at + 3, padded);
        }
        for i in 16..64 {
            let x = s.schedule[i - 15];
            let y = s.schedule[i - 2];
            let a = rotate32(x, 7) ^ rotate32(x, 18) ^ (x >> 3);
            let b = rotate32(y, 17) ^ rotate32(y, 19) ^ (y >> 10);
            s.schedule[i] = (s.schedule[i - 16] + a + s.schedule[i - 7] + b) & 4294967295;
        }
        let a = s.words[0]; let b = s.words[1]; let c = s.words[2]; let d = s.words[3];
        let e = s.words[4]; let f = s.words[5]; let g = s.words[6]; let h = s.words[7];
        for i in 0..64 {
            let sum1 = rotate32(e, 6) ^ rotate32(e, 11) ^ rotate32(e, 25);
            let choice = (e & f) ^ ((4294967295 ^ e) & g);
            let temp1 = (h + sum1 + choice + s.constants[i] + s.schedule[i]) & 4294967295;
            let sum0 = rotate32(a, 2) ^ rotate32(a, 13) ^ rotate32(a, 22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = (sum0 + majority) & 4294967295;
            h = g; g = f; f = e; e = (d + temp1) & 4294967295;
            d = c; c = b; b = a; a = (temp1 + temp2) & 4294967295;
        }
        s.words[0] = (s.words[0] + a) & 4294967295;
        s.words[1] = (s.words[1] + b) & 4294967295;
        s.words[2] = (s.words[2] + c) & 4294967295;
        s.words[3] = (s.words[3] + d) & 4294967295;
        s.words[4] = (s.words[4] + e) & 4294967295;
        s.words[5] = (s.words[5] + f) & 4294967295;
        s.words[6] = (s.words[6] + g) & 4294967295;
        s.words[7] = (s.words[7] + h) & 4294967295;
        base += 64;
    }
    for i in 0..8 {
        for j in 0..4 { output[offset + i * 4 + j] = (s.words[i] >> ((3 - j) * 8)) & 255; }
    }
    return true;
}
