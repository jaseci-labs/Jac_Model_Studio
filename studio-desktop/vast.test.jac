"""studio - integration test for Vast credential encryption at rest.

Exercises the real set_vast_key endpoint in a graph/root context (as `jac test`
provides), then reads the stored VastCred node directly to prove the key is
never persisted in plaintext, and that _api_key() transparently decrypts it back
for use. Annex file — pairs with vast.sv.jac. Run with `jac test vast.sv.jac`.
"""

import os;

test "set_vast_key stores ciphertext, not plaintext, and _api_key decrypts it" {
    os.environ["JAC_SECRET_KEY"] = "vast-test-master-key";
    secret = "vast-SECRET-9f8e7d6c";
    res = set_vast_key(secret, "test-label");
    assert bool(res["ok"]);

    cred = _user_cred();
    assert cred is not None;
    # Persisted value must be encrypted — the raw secret must NOT be on disk.
    assert cred.api_key != secret;
    assert cred.api_key.startswith("enc:v1:");
    # ...but the endpoint resolves it back to the real key for SDK calls.
    assert str(_api_key()) == secret;

    clear_vast_key();
    del os.environ["JAC_SECRET_KEY"];
}

test "credential status never leaks the key" {
    os.environ["JAC_SECRET_KEY"] = "vast-test-master-key";
    set_vast_key("another-secret-key", "lbl");
    st = vast_credential_status();
    assert bool(st["has_user_key"]);
    assert st["source"] == "user";
    # The status dict exposes only metadata, no key material.
    assert "another-secret-key" not in str(st);
    clear_vast_key();
    del os.environ["JAC_SECRET_KEY"];
}
