import "builder";
import "crypto";
import "encoding";
import "strings";

fn str_to_bytes(s: str) -> bytes {
    return builder.new_bytes().write_str(s).finish();
}

fn hash_password(password: str) -> result[str, str] {
    let pwd = str_to_bytes(password);
    let salt_res = crypto.rand(16);
    guard let salt = salt_res else let e = err_of(salt_res) {
        return err("failed to generate salt: " + e);
    }
    let hash_res = crypto.argon2id_raw(pwd, salt, 1, 64 * 1024, 1, 32);
    guard let h = hash_res else let e = err_of(hash_res) {
        return err("failed to hash password: " + e);
    }
    let salt_hex = encoding.hex_encode(salt);
    let hash_hex = encoding.hex_encode(h);
    return ok("$argon2id$v=19$m=65536,t=1,p=1$" + salt_hex + "$" + hash_hex);
}

fn verify_password(password: str, encoded: str) -> result[bool, str] {
    let parts = strings.split(encoded, "$");
    if len(parts) < 6 {
        return err("invalid password hash format");
    }
    let salt_hex = parts[4];
    let hash_hex = parts[5];
    let salt_bytes_res = encoding.hex_decode(salt_hex);
    guard let salt = salt_bytes_res else let e = err_of(salt_bytes_res) {
        return err("failed to decode salt: " + e);
    }
    let hash_bytes_res = encoding.hex_decode(hash_hex);
    guard let target_hash = hash_bytes_res else let e = err_of(hash_bytes_res) {
        return err("failed to decode hash: " + e);
    }
    let pwd = str_to_bytes(password);
    return crypto.argon2id_verify(pwd, salt, target_hash, 1, 64 * 1024, 1);
}
