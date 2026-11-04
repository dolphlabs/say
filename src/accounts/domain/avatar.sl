import "crypto";
import "encoding";
import "strings";

pub gc struct AvatarKeys {
    cloud_name: str,
    api_key: str,
    api_secret: str
}

pub gc struct AvatarUpload {
    url: str,
    fields: map[str]str
}

pub fn avatars_enabled(k: AvatarKeys) -> bool {
    return len(k.cloud_name) > 0 && len(k.api_key) > 0 && len(k.api_secret) > 0;
}

// One fixed slot per account: an upload can only ever replace the caller's own photo.
pub fn avatar_public_id(account_id: str) -> str {
    return "say/avatars/" + account_id;
}

fn signed(params: [str], secret: str) -> str {
    return encoding.hex_encode(crypto.sha1(to_bytes(strings.join(params, "&") + secret)));
}

// Cloudinary signs every upload parameter except file, api_key, cloud_name and
// resource_type, joined in alphabetical order.
pub fn avatar_upload(k: AvatarKeys, account_id: str, now_seconds: int) -> AvatarUpload {
    let public_id = avatar_public_id(account_id);
    let formats = "jpg,jpeg,png,webp";
    let shrink = "c_limit,h_1024,w_1024";
    let ts = to_str(now_seconds);
    let fields: map[str]str = {};
    fields["allowed_formats"] = formats;
    fields["invalidate"] = "true";
    fields["overwrite"] = "true";
    fields["public_id"] = public_id;
    fields["timestamp"] = ts;
    fields["transformation"] = shrink;
    fields["api_key"] = k.api_key;
    fields["signature"] = signed(["allowed_formats=" + formats, "invalidate=true", "overwrite=true",
        "public_id=" + public_id, "timestamp=" + ts, "transformation=" + shrink], k.api_secret);
    return AvatarUpload { url: "https://api.cloudinary.com/v1_1/" + k.cloud_name + "/image/upload", fields: fields };
}

// Cloudinary's upload response carries this signature, so only a file that
// really landed in the caller's slot can become their avatar.
pub fn upload_response_valid(k: AvatarKeys, account_id: str, public_id: str, version: str, signature: str) -> bool {
    if public_id != avatar_public_id(account_id) || len(version) == 0 || len(version) > 20 {
        return false;
    }
    for b in to_bytes(version) {
        if b < 48 || b > 57 { return false; }
    }
    return signature == signed(["public_id=" + public_id, "version=" + version], k.api_secret);
}

pub fn avatar_url(k: AvatarKeys, account_id: str, version: str) -> str {
    return "https://res.cloudinary.com/" + k.cloud_name + "/image/upload/c_fill,g_face,h_256,w_256/f_auto/q_auto/v" +
        version + "/" + avatar_public_id(account_id);
}
