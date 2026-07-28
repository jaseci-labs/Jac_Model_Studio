"""studio - unit tests for crypto.sv.jac (secret-at-rest encryption).

Pure-logic coverage: sets/clears the master key via the process env inside each
test so no server or data_root is involved. Annex file — pairs with
crypto.sv.jac and sees its private `def`s directly. Run with
`jac test crypto.sv.jac`.
"""

import os;

test "roundtrip with a master key recovers the plaintext" {
    os.environ["JAC_SECRET_KEY"] = "test-master-key-please-ignore";
    secret = "spheron-abc123-DEADBEEF";
    token = encrypt(secret);
    assert token.startswith("enc:v1:");
    assert token != secret;
    assert decrypt(token) == secret;
    del os.environ["JAC_SECRET_KEY"];
}

test "two encryptions of the same plaintext differ (random nonce)" {
    os.environ["JAC_SECRET_KEY"] = "test-master-key-please-ignore";
    a = encrypt("same");
    b = encrypt("same");
    assert a != b;
    assert decrypt(a) == "same";
    assert decrypt(b) == "same";
    del os.environ["JAC_SECRET_KEY"];
}

test "tampered ciphertext is rejected" {
    os.environ["JAC_SECRET_KEY"] = "test-master-key-please-ignore";
    import base64;
    token = encrypt("secret");
    blob = bytearray(base64.b64decode(token[7:]));
    blob[-1] = blob[-1] ^ 0x01;
    forged = "enc:v1:" + base64.b64encode(bytes(blob)).decode("ascii");
    raised = False;
    try {
        decrypt(forged);
    } except ValueError {
        raised = True;
    }
    assert raised;
    del os.environ["JAC_SECRET_KEY"];
}

test "wrong master key cannot decrypt" {
    os.environ["JAC_SECRET_KEY"] = "key-one";
    token = encrypt("secret");
    os.environ["JAC_SECRET_KEY"] = "key-two";
    raised = False;
    try {
        decrypt(token);
    } except ValueError {
        raised = True;
    }
    assert raised;
    del os.environ["JAC_SECRET_KEY"];
}

test "legacy plaintext (no prefix) passes through decrypt unchanged" {
    os.environ["JAC_SECRET_KEY"] = "test-master-key-please-ignore";
    assert decrypt("raw-legacy-key") == "raw-legacy-key";
    del os.environ["JAC_SECRET_KEY"];
}

test "no master key: encrypt is a passthrough (dev/desktop)" {
    os.environ.pop("JAC_SECRET_KEY", None);
    os.environ.pop("JWT_SECRET", None);
    assert not is_configured();
    assert encrypt("plain") == "plain";
    assert decrypt("plain") == "plain";
}

test "JWT_SECRET is used as the master key when JAC_SECRET_KEY is unset" {
    os.environ.pop("JAC_SECRET_KEY", None);
    os.environ["JWT_SECRET"] = "jwt-fallback-master";
    assert is_configured();
    token = encrypt("secret");
    assert token.startswith("enc:v1:");
    assert decrypt(token) == "secret";
    del os.environ["JWT_SECRET"];
}
