fn test_should_count_and_render_sorted() {
    let r = new_registry();
    add(r, "b_total", 2);
    add(r, "b_total", 3);
    add(r, "a_total{to=\"ACTIVE\"}", 1);
    set(r, "lag_seconds", 4);
    set(r, "lag_seconds", 7);
    assert(value(r, "b_total") == 5);
    assert(render(r) == "a_total{to=\"ACTIVE\"} 1\nb_total 5\nlag_seconds 7\n", render(r));
}
