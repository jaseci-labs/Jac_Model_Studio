"""studio - symmetric encryption for secrets at rest (env-keyed).

Threat model: protect stored third-party credentials (currently the per-user
Spheron API key on `SpheronCred.api_key`) from anyone who can read the OSP graph
database or a `backup_graph.sh` tarball. It is NOT a defense against an attacker
who already has the running process's environment (they hold the master key).

Construction (stdlib only — the frozen `jac` binary ships no `cryptography`):
encrypt-then-MAC with an HMAC-SHA256 keystream. A random 16-byte nonce seeds a
counter-mode PRF keystream (HMAC(enc_key, nonce||counter)); the ciphertext is
XORed against it and authenticated with HMAC(mac_key, nonce||ct). enc_key /
mac_key are independent HKDF-style subkeys of the master. Output is
`enc:v1:<base64(nonce||tag||ct)>`.

Master key: `JAC_SECRET_KEY` if set, else `JWT_SECRET` (already mandatory in
`start_prod.sh`). With NO master key configured (local desktop / dev), encrypt()
is a no-op passthrough so a single-user machine keeps working — those values sit
on the user's own disk. `decrypt()` returns non-`enc:v1:` input unchanged, so
legacy plaintext keys stored before this module migrate transparently on read
and re-encrypt on the next write.
"""

import os;
import hmac;
import hashlib;
import base64;

def _master() -> bytes {
    k = os.environ.get("JAC_SECRET_KEY", "");
    if not k { k = os.environ.get("JWT_SECRET", ""); }
    if not k { return b""; }
    return k.encode("utf-8");
}

"""True when a master key is present — encryption is active. Off on local
desktop/dev, where secrets stay as plaintext on the user's own disk."""
def is_configured() -> bool {
    return len(_master()) > 0;
}

def _subkey(master: bytes, label: bytes) -> bytes {
    return hmac.new(master, label, hashlib.sha256).digest();
}

def _keystream(enc_key: bytes, nonce: bytes, n: int) -> bytes {
    out = b"";
    counter = 0;
    while len(out) < n {
        block = hmac.new(enc_key, nonce + counter.to_bytes(8, "big"), hashlib.sha256).digest();
        out += block;
        counter += 1;
    }
    return out[:n];
}

def _xor(a: bytes, b: bytes) -> bytes {
    return bytes([a[i] ^ b[i] for i in range(len(a))]);
}

"""Encrypt a UTF-8 string. Returns `enc:v1:<b64>`, or the plaintext unchanged
when no master key is configured (dev/desktop)."""
def encrypt(plaintext: str) -> str {
    master = _master();
    if not master { return plaintext; }
    enc_key = _subkey(master, b"studio-enc-v1");
    mac_key = _subkey(master, b"studio-mac-v1");
    nonce = os.urandom(16);
    pt = plaintext.encode("utf-8");
    ct = _xor(pt, _keystream(enc_key, nonce, len(pt)));
    tag = hmac.new(mac_key, nonce + ct, hashlib.sha256).digest();
    blob = nonce + tag + ct;
    return "enc:v1:" + base64.b64encode(blob).decode("ascii");
}

"""Decrypt a token from encrypt(). A value without the `enc:v1:` prefix is
treated as legacy plaintext and returned unchanged (transparent migration).
Raises ValueError on a tampered/blank ciphertext or a missing master key."""
def decrypt(token: str) -> str {
    if not token.startswith("enc:v1:") { return token; }
    master = _master();
    if not master { raise ValueError("JAC_SECRET_KEY/JWT_SECRET required to decrypt stored secret"); }
    blob = base64.b64decode(token[7:]);
    if len(blob) < 48 { raise ValueError("ciphertext too short"); }
    nonce = blob[:16];
    tag = blob[16:48];
    ct = blob[48:];
    enc_key = _subkey(master, b"studio-enc-v1");
    mac_key = _subkey(master, b"studio-mac-v1");
    expected = hmac.new(mac_key, nonce + ct, hashlib.sha256).digest();
    if not hmac.compare_digest(tag, expected) { raise ValueError("ciphertext tampered or wrong key"); }
    pt = _xor(ct, _keystream(enc_key, nonce, len(ct)));
    return pt.decode("utf-8");
}
