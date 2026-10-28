fn test_parse_channel() {
    let c1 = parse_channel("market:m_123:book");
    assert(c1.valid);
    assert(c1.kind == "market.book");
    assert(c1.market_id == "m_123");
    assert(!c1.is_private);

    let c2 = parse_channel("cards");
    assert(c2.valid);
    assert(c2.kind == "cards");

    let c3 = parse_channel("me");
    assert(c3.valid);
    assert(c3.is_private);

    let c4 = parse_channel("invalid:format");
    assert(!c4.valid);
}

fn test_apply_levels_update() {
    let existing = [
        Level { side: "bid", yes_price: 42, qty: 10 },
        Level { side: "ask", yes_price: 55, qty: 8 }
    ];
    let updates = [
        Level { side: "bid", yes_price: 42, qty: 15 }, // updated qty
        Level { side: "ask", yes_price: 55, qty: 0 },  // removed level
        Level { side: "bid", yes_price: 40, qty: 20 }  // new level
    ];
    let res = apply_levels_update(existing, updates);
    assert(len(res) == 2);
    let found_42 = false;
    let found_40 = false;
    for l in res {
        if l.yes_price == 42 {
            assert(l.qty == 15);
            found_42 = true;
        }
        if l.yes_price == 40 {
            assert(l.qty == 20);
            found_40 = true;
        }
        assert(l.yes_price != 55);
    }
    assert(found_42 && found_40);
}

fn test_derive_mirrored_book() {
    let yes_bids = [Level { side: "bid", yes_price: 40, qty: 10 }];
    let yes_asks = [Level { side: "ask", yes_price: 60, qty: 5 }];
    let book = derive_mirrored_book(yes_bids, yes_asks, 100);

    // Yes ask at 60 -> No bid at 100 - 60 = 40
    assert(len(book.no_bids) == 1);
    assert(book.no_bids[0].yes_price == 40);
    assert(book.no_bids[0].qty == 5);

    // Yes bid at 40 -> No ask at 100 - 40 = 60
    assert(len(book.no_asks) == 1);
    assert(book.no_asks[0].yes_price == 60);
    assert(book.no_asks[0].qty == 10);
}

fn test_envelope_builder() {
    let env = make_event_envelope(
        "evt_1",
        "market:m_1:book",
        "book.delta",
        1092,
        1090,
        7,
        "2026-10-28T16:00:00Z",
        "{\"levels\":[]}"
    );
    assert(format_uint64_str(1092) == "1092");
    assert(env != "");
}
