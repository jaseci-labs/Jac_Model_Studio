"""studio - unit tests for jms_llm.sv.jac (provider config + key at rest).

Covers the price table (known/unknown), the encrypted key round-trip (set →
stored ciphertext is NOT the plaintext → resolves back → status masks it), the
clear path, and the ANTHROPIC_API_KEY env fallback. A master key is forced on via
JAC_SECRET_KEY so crypto.encrypt actually encrypts (it is a no-op passthrough
with no master key, which is the desktop/dev default).

Annex of jms_llm.sv.jac — shares the persisted `root`; each test manages its own
JmsSettings (0..1 on root) via clear_anthropic_key first. Run with
`jac test jms_llm.sv.jac`; `jac clean --data --force` if a re-run flakes.
"""

import os;

"""Force encryption on so the at-rest assertion is meaningful."""
def _master_on -> None {
    os.environ["JAC_SECRET_KEY"] = "unit-test-master-key-please-ignore";
}

test "price_for returns known rates and zeros for unknown / mlx models" {
    s = price_for("claude-sonnet-5");
    assert s["in"] == 3.0 and s["out"] == 15.0, s;
    h = price_for("claude-haiku-4-5");
    assert h["in"] == 1.0 and h["out"] == 5.0, h;
    z = price_for("some-local-mlx-model");
    assert z["in"] == 0.0 and z["out"] == 0.0, z;
}

test "set/clear/status round-trip stores the key encrypted at rest" {
    _master_on();
    os.environ.pop("ANTHROPIC_API_KEY", None);
    clear_anthropic_key();

    plaintext = "sk-ant-secret-XYZ789";
    r = set_anthropic_key(plaintext);
    assert r["ok"] == True and r["source"] == "user", r;

    # At rest: the stored value is ciphertext, never the plaintext.
    s = _settings();
    assert s is not None, "settings node created";
    assert s.anthropic_key != plaintext, "key must not be stored in plaintext";
    assert s.anthropic_key.startswith("enc:v1:"), s.anthropic_key;

    # But it resolves back to the plaintext for the request that spends on it.
    assert resolved_anthropic_key() == plaintext, resolved_anthropic_key();

    # Status reports configured/user + a masked tail — never the raw key.
    st = llm_status();
    assert st["configured"] == True and st["source"] == "user", st;
    assert st["masked"] == "…Z789", st["masked"];
    assert plaintext not in str(st), "raw key must never appear in status";
    # Provider catalog shape.
    ids = [str(p["id"]) for p in st["providers"]];
    assert "claude" in ids and "mlx" in ids, ids;

    # Clear removes the user key.
    c = clear_anthropic_key();
    assert c["ok"] == True, c;
    assert resolved_anthropic_key() == "", "key cleared";
}

test "resolved key falls back to ANTHROPIC_API_KEY env when no user key" {
    _master_on();
    clear_anthropic_key();
    os.environ["ANTHROPIC_API_KEY"] = "env-fallback-key-abc";
    assert resolved_anthropic_key() == "env-fallback-key-abc", resolved_anthropic_key();
    st = llm_status();
    assert st["source"] == "env", st;
    assert st["configured"] == True, st;
    assert st["masked"] == "", "no masked tail for an env-sourced key";
    os.environ.pop("ANTHROPIC_API_KEY", None);
    # With neither user nor env key, status is unconfigured.
    st2 = llm_status();
    assert st2["source"] == "none" and st2["configured"] == False, st2;
}
