"""studio - unit tests for clusters.sv.jac (BYO GPU cluster registry).

Three areas, all hermetic:
  * `_parse_ssh_link` over every vendor link shape the UI promises to accept,
    plus the malformed / out-of-range paths.
  * `_key_paths` path-traversal rejection (a client-supplied key_id crosses an
    HTTP boundary, so it must never escape the key directory).
  * A real generate_ssh_key → list_ssh_keys → delete_ssh_key round trip against
    a TEMP key directory. `JMS_SSH_KEY_DIR` is set for the duration of the test
    so the developer's real `~/.jms/ssh_keys` is never touched, and the private
    key file's 0600 mode is asserted on disk.

No network: nothing here calls `_probe`. Annex file — pairs with
clusters.sv.jac and sees its private `def`s directly. Run with
`jac test clusters.test.jac`.
"""

import os;
import shutil;
import tempfile;
import from pathlib { Path }

def _use_temp_keydir() -> str {
    d = tempfile.mkdtemp(prefix="jms-ssh-keys-test-");
    os.environ["JMS_SSH_KEY_DIR"] = d;
    return d;
}

def _drop_temp_keydir(d: str) -> None {
    try {
        shutil.rmtree(d, ignore_errors=True);
    } except Exception {}
    if "JMS_SSH_KEY_DIR" in os.environ {
        del os.environ["JMS_SSH_KEY_DIR"];
    }
}

# ---------------------------------------------------------------------------
# _parse_ssh_link
# ---------------------------------------------------------------------------

test "parses `ssh user@host -p PORT`" {
    r = _parse_ssh_link("ssh root@203.0.113.10 -p 2222");
    assert r["ok"], r;
    assert r["user"] == "root", r;
    assert r["host"] == "203.0.113.10", r;
    assert r["port"] == 2222, r;
    assert r["error"] == "", r;
}

test "parses `ssh -p PORT user@host` (flag first)" {
    r = _parse_ssh_link("ssh -p 2222 ubuntu@gpu-1.example.com");
    assert r["ok"], r;
    assert r["user"] == "ubuntu", r;
    assert r["host"] == "gpu-1.example.com", r;
    assert r["port"] == 2222, r;
}

test "parses an ssh:// URL with an inline port" {
    r = _parse_ssh_link("ssh://root@203.0.113.10:2222");
    assert r["ok"], r;
    assert r["user"] == "root", r;
    assert r["host"] == "203.0.113.10", r;
    assert r["port"] == 2222, r;
}

test "parses a bare `user@host:port`" {
    r = _parse_ssh_link("root@ssh.runpod.io:22007");
    assert r["ok"], r;
    assert r["user"] == "root", r;
    assert r["host"] == "ssh.runpod.io", r;
    assert r["port"] == 22007, r;
}

test "parses `user@host -p PORT` with no leading ssh token" {
    r = _parse_ssh_link("root@203.0.113.10 -p 2222");
    assert r["ok"], r;
    assert r["port"] == 2222, r;
    assert r["host"] == "203.0.113.10", r;
}

test "bare user@host defaults to port 22" {
    r = _parse_ssh_link("ayush@my-box.local");
    assert r["ok"], r;
    assert r["user"] == "ayush", r;
    assert r["host"] == "my-box.local", r;
    assert r["port"] == 22, r;
}

test "surrounding whitespace, quotes and a shell prompt are tolerated" {
    r = _parse_ssh_link("  `ssh root@10.0.0.5 -p 22`  ");
    assert r["ok"], r;
    assert r["host"] == "10.0.0.5", r;
    r2 = _parse_ssh_link("$ ssh root@10.0.0.5");
    assert r2["ok"], r2;
    assert r2["host"] == "10.0.0.5", r2;
}

test "a glued -pPORT flag is understood" {
    r = _parse_ssh_link("ssh -p2222 root@10.0.0.5");
    assert r["ok"], r;
    assert r["port"] == 2222, r;
}

test "an explicit -p overrides an inline :port" {
    r = _parse_ssh_link("ssh root@10.0.0.5:22 -p 2222");
    assert r["ok"], r;
    assert r["port"] == 2222, r;
}

test "input with no user@host is rejected with a human error" {
    r = _parse_ssh_link("just some words the user pasted");
    assert not r["ok"], r;
    assert "user@host" in str(r["error"]), r;
}

test "empty input is rejected" {
    r = _parse_ssh_link("   ");
    assert not r["ok"], r;
    assert r["error"] != "", r;
}

test "an out-of-range port is rejected" {
    r = _parse_ssh_link("ssh root@10.0.0.5 -p 99999");
    assert not r["ok"], r;
    assert "65535" in str(r["error"]), r;
}

test "a non-numeric port is rejected, not crashed on" {
    r = _parse_ssh_link("ssh root@10.0.0.5 -p abc");
    assert not r["ok"], r;
    assert r["error"] != "", r;
}

# ---------------------------------------------------------------------------
# _key_paths / _valid_key_id
# ---------------------------------------------------------------------------

test "_key_paths rejects path-traversal and other non-uuid key ids" {
    for bogus in ["../../etc/passwd", "..", "", "abc", "/etc/shadow",
                  "0123456789abcdef0123456789abcdeF", "0123456789abcdef0123456789abcde/"] {
        assert not _valid_key_id(bogus), bogus;
        raised = False;
        try {
            _key_paths(bogus);
        } except ValueError {
            raised = True;
        }
        assert raised, bogus;
    }
}

test "_key_paths accepts a real uuid4 hex and stays inside the key dir" {
    d = _use_temp_keydir();
    try {
        kid = "0123456789abcdef0123456789abcdef";
        assert _valid_key_id(kid);
        pair = _key_paths(kid);
        assert str(pair[0]) == str(Path(d) / kid), pair;
        assert str(pair[1]) == str(Path(d) / (kid + ".pub")), pair;
        # _key_dir() creates the directory 0700.
        assert (os.stat(d).st_mode & 0o777) == 0o700, oct(os.stat(d).st_mode);
    } finally {
        _drop_temp_keydir(d);
    }
}

# ---------------------------------------------------------------------------
# generate / list / delete round trip (real ssh-keygen, temp key dir)
# ---------------------------------------------------------------------------

test "generate_ssh_key → list_ssh_keys → delete_ssh_key round trip" {
    d = _use_temp_keydir();
    try {
        gen = generate_ssh_key("unit-test-key");
        assert gen["ok"], gen;
        kid = str(gen["key_id"]);
        assert _valid_key_id(kid), kid;
        assert gen["label"] == "unit-test-key", gen;
        assert str(gen["public_key"]).startswith("ssh-ed25519 "), gen;
        assert "jms-unit-test-key" in str(gen["public_key"]), gen;
        assert str(gen["fingerprint"]).startswith("SHA256:"), gen;

        # Files land in the temp dir with the right modes; the PRIVATE key is
        # on disk only and never in the returned dict.
        priv = Path(d) / kid;
        pub = Path(d) / (kid + ".pub");
        assert priv.exists(), str(priv);
        assert pub.exists(), str(pub);
        assert (os.stat(str(priv)).st_mode & 0o777) == 0o600, oct(os.stat(str(priv)).st_mode);
        assert "PRIVATE KEY" not in str(gen), "private key material leaked into the response";

        listed = list_ssh_keys();
        assert listed["ok"], listed;
        ids = [str(k["key_id"]) for k in listed["keys"]];
        assert kid in ids, listed;
        for k in listed["keys"] {
            if str(k["key_id"]) == kid {
                assert k["fingerprint"] == gen["fingerprint"], k;
                assert k["public_key"] == gen["public_key"], k;
                assert str(k["created_at"]).endswith("Z"), k;
            }
        }

        rm = delete_ssh_key(kid);
        assert rm["ok"], rm;
        assert not priv.exists(), "private key file survived delete";
        assert not pub.exists(), "public key file survived delete";
        after = [str(k["key_id"]) for k in list_ssh_keys()["keys"]];
        assert kid not in after, after;
    } finally {
        _drop_temp_keydir(d);
    }
}

test "generate_ssh_key rejects an unsafe label and auto-names an empty one" {
    d = _use_temp_keydir();
    try {
        bad = generate_ssh_key("evil; rm -rf /");
        assert not bad["ok"], bad;
        assert bad["key_id"] == "", bad;

        auto = generate_ssh_key("");
        assert auto["ok"], auto;
        assert str(auto["label"]).startswith("key-"), auto;
        delete_ssh_key(str(auto["key_id"]));
    } finally {
        _drop_temp_keydir(d);
    }
}

test "delete_ssh_key refuses while a cluster still references the key" {
    d = _use_temp_keydir();
    try {
        gen = generate_ssh_key("in-use-key");
        assert gen["ok"], gen;
        kid = str(gen["key_id"]);
        # Attach a Cluster directly (add_cluster would probe the network).
        c = Cluster(
            cluster_id="test-cluster-1",
            label="held",
            host="10.0.0.5",
            port=22,
            user="root",
            key_id=kid,
            created_at="2026-01-01T00:00:00Z"
        );
        root ++> c;

        refused = delete_ssh_key(kid);
        assert not refused["ok"], refused;
        assert "in use" in str(refused["error"]), refused;

        # cluster_ssh_override is the cross-module contract — exact string shape.
        ovr = cluster_ssh_override("test-cluster-1");
        assert ovr == f"ssh -i {str(Path(d) / kid)} -p 22 root@10.0.0.5", ovr;
        assert cluster_ssh_override("no-such-cluster") == "";

        rn = rename_cluster("test-cluster-1", "held-renamed");
        assert rn["ok"], rn;
        rows = list_clusters();
        assert rows["ok"], rows;
        found = [r for r in rows["clusters"] if str(r["cluster_id"]) == "test-cluster-1"];
        assert len(found) == 1, rows;
        assert found[0]["label"] == "held-renamed", found;
        assert found[0]["key_label"] == "in-use-key", found;

        gone = remove_cluster("test-cluster-1");
        assert gone["ok"], gone;
        assert remove_cluster("test-cluster-1")["ok"] == False;
        # With the cluster gone the key deletes cleanly.
        assert delete_ssh_key(kid)["ok"];
    } finally {
        _drop_temp_keydir(d);
    }
}

test "unknown ids are reported, never crashed on" {
    assert not delete_ssh_key("0123456789abcdef0123456789abcdef")["ok"];
    assert not retest_cluster("nope")["ok"];
    assert not rename_cluster("nope", "fine-label")["ok"];
    assert not remove_cluster("nope")["ok"];
    assert cluster_ssh_override("nope") == "";
}
