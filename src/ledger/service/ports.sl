import "../domain" as domain;

pub gc struct SeasonStore[C] {
    context: C,
    current: fn(C) -> result[opt[domain.Season], str]
}
