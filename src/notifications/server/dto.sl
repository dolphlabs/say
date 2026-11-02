gc struct ReadNotifDto {
    ids: opt[[str]],
    all: opt[bool]
}

gc struct UpdatePrefDto {
    kind: str,
    in_app: opt[bool],
    email: opt[bool]
}
