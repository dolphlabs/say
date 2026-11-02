fn keys() -> AvatarKeys {
    return AvatarKeys { cloud_name: "demo", api_key: "123", api_secret: "secret" };
}

fn test_should_sign_parameters_the_way_cloudinary_documents() {
    assert(signed(["eager=w_400,h_300,c_pad|w_260,h_200,c_crop", "public_id=sample_image", "timestamp=1315060510"], "abcd") ==
        "bfd09f95f331f558cbd1320e67aa8d488770583e");
}

fn test_should_pin_the_upload_to_the_callers_own_slot() {
    let u = avatar_upload(keys(), "acc-1", 1700000000);
    assert(u.url == "https://api.cloudinary.com/v1_1/demo/image/upload", u.url);
    assert(u.fields["public_id"] == "say/avatars/acc-1");
    assert(u.fields["overwrite"] == "true");
    assert(u.fields["api_key"] == "123");
    assert(len(u.fields["signature"]) == 40);
    let other = avatar_upload(keys(), "acc-2", 1700000000);
    assert(other.fields["signature"] != u.fields["signature"]);
}

fn test_should_accept_only_a_genuine_upload_response_for_the_callers_slot() {
    let k = keys();
    assert(upload_response_valid(k, "acc-1", "say/avatars/acc-1", "1700000000", "1c2d4687c2e3369656236f7dd548aacdfcfe8ff0"));
    assert(!upload_response_valid(k, "acc-2", "say/avatars/acc-1", "1700000000", "1c2d4687c2e3369656236f7dd548aacdfcfe8ff0"));
    assert(!upload_response_valid(k, "acc-1", "say/avatars/acc-1", "1700000001", "1c2d4687c2e3369656236f7dd548aacdfcfe8ff0"));
    assert(!upload_response_valid(k, "acc-1", "say/avatars/acc-1", "17e9", "1c2d4687c2e3369656236f7dd548aacdfcfe8ff0"));
}

fn test_should_build_a_cropped_avatar_url_and_know_when_uploads_are_off() {
    assert(avatar_url(keys(), "acc-1", "17") == "https://res.cloudinary.com/demo/image/upload/c_fill,g_face,h_256,w_256/f_auto/q_auto/v17/say/avatars/acc-1");
    assert(avatars_enabled(keys()));
    assert(!avatars_enabled(AvatarKeys { cloud_name: "demo", api_key: "", api_secret: "secret" }));
}
