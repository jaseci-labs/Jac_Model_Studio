"""studio - BYO GPU clusters (bring-your-own SSH box).

Replaces the Spheron *marketplace* flow (search offers → deploy → destroy via a
vendor REST API) with a vendor-neutral one: the user generates an ed25519
keypair HERE (this app runs on their own machine), pastes the PUBLIC half into
whatever GPU console they like (Spheron dashboard, RunPod, Lambda, a bare-metal
box's authorized_keys), gets an ssh connection string back, and pastes that in.
JMS parses it, probes it, and stores it as a reusable `Cluster` that any
training run can target. No API key, no billing integration, no provider SDK.

Key material policy
  * The PRIVATE key NEVER enters the OSP graph. It is written to
    `~/.jms/ssh_keys/<key_id>` (0600) — outside the git repo on purpose, so
    `paths.studio_root()` (the jms/ dir, which IS inside the repo) is never a
    candidate. Override the directory with `JMS_SSH_KEY_DIR` (tests use this).
  * Only the PUBLIC key + its SHA256 fingerprint live on the graph. Both are
    safe to return to the client and to log — that is the whole point of a
    public key. crypto.sv.jac is therefore NOT used here: there is no secret at
    rest in the graph to encrypt.
  * Audit records carry ids/labels/hosts only — never a key path, never key
    material, never a full ssh command.

Multi-tenancy: `SshKey` and `Cluster` hang off the CALLER's own root
(`[root -->][?:Type]`), same shape as spheron.sv.jac's `SpheronCred` /
`SpheronDeployment`, so one tenant can never see or use another's cluster.

Return convention (matches spheron.sv.jac exactly): every client-facing `def`
returns a dict that always contains `ok: bool` and `error: str`. `ok=True`
means the operation succeeded; a failed *connection probe* is NOT a failed
operation (see `add_cluster`) — that is reported via `test_ok`/`test_message`.

Checker notes (jaclang 0.16.1): `root ++> X(...)` evaluates to a LIST — bind
the node first and connect on its own statement (same trick spheron.sv.jac:495
uses). `re` match groups are untyped, so every group read is wrapped in str().
"""

import os;
import re;
import shlex;
import subprocess;
import datetime;
import audit;
import jobs;
import from pathlib { Path }
import from uuid { uuid4 }

# Marker echoed by the remote end of a successful probe.
glob PROBE_MARKER: str = "JMS_PROBE_OK";

# Seconds ssh may spend connecting / the whole probe may spend running.
glob PROBE_CONNECT_TIMEOUT_S: int = 8;
glob PROBE_TIMEOUT_S: int = 15;
glob KEYGEN_TIMEOUT_S: int = 15;

"""One locally generated ed25519 keypair owned by the caller.

Only the public half is stored here. The private half is a 0600 file at
`_key_dir()/<key_id>` and is referenced by `key_id` alone."""
node SshKey {
    has key_id: str = "",
        label: str = "",
        public_key: str = "",
        fingerprint: str = "",
        created_at: str = "";
}

"""One reusable BYO GPU box the caller can target with a training run.

`key_id` references an `SshKey` on the same root. The `last_test_*` fields are
the cached outcome of the most recent `_probe` (from `add_cluster` or
`retest_cluster`) — they are advisory display state, never a gate."""
node Cluster {
    has cluster_id: str = "",
        label: str = "",
        host: str = "",
        port: int = 22,
        user: str = "",
        key_id: str = "",
        created_at: str = "",
        last_test_ok: bool = False,
        last_test_at: str = "",
        last_test_msg: str = "";
}

def _now() -> str {
    return datetime.datetime.now(datetime.UTC).replace(tzinfo=None).isoformat() + "Z";
}

"""Directory holding private key files. `JMS_SSH_KEY_DIR` overrides (tests set
it to a temp dir); default `~/.jms/ssh_keys`. Deliberately NOT under
paths.studio_root() — that is the jms/ directory inside the git repo.

Created 0700 on every call; makedirs' mode is umask-affected, so it is
re-chmod'ed afterwards."""
def _key_dir() -> Path {
    env = os.environ.get("JMS_SSH_KEY_DIR", "");
    d = Path(env) if env else (Path.home() / ".jms" / "ssh_keys");
    os.makedirs(str(d), mode=0o700, exist_ok=True);
    try {
        os.chmod(str(d), 0o700);
    } except Exception {}
    return d;
}

"""True iff *key_id* is a bare uuid4 hex token (32 lowercase hex chars)."""
def _valid_key_id(key_id: str) -> bool {
    return re.fullmatch(r"[0-9a-f]{32}", str(key_id)) is not None;
}

"""(private_path, public_path) for *key_id* under `_key_dir()`.

Raises ValueError on anything that is not a bare uuid4 hex token, so a
client-supplied key_id can never traverse out of the key directory (defense in
depth — this is a local desktop app, but the id crosses an HTTP boundary)."""
def _key_paths(key_id: str) -> tuple[Path, Path] {
    if not _valid_key_id(key_id) {
        raise ValueError("invalid key id");
    }
    d = _key_dir();
    return (d / key_id, d / (key_id + ".pub"));
}

"""The caller's SshKey with this key_id, or None. Caller's root only."""
def _find_key(key_id: str) -> SshKey | None {
    for k in [root -->][?:SshKey] {
        if k.key_id == key_id {
            return k;
        }
    }
    return None;
}

"""The caller's Cluster with this cluster_id, or None. Caller's root only."""
def _find_cluster(cluster_id: str) -> Cluster | None {
    for c in [root -->][?:Cluster] {
        if c.cluster_id == cluster_id {
            return c;
        }
    }
    return None;
}

"""Number of the caller's clusters still referencing *key_id*."""
def _key_use_count(key_id: str) -> int {
    n = 0;
    for c in [root -->][?:Cluster] {
        if c.key_id == key_id {
            n += 1;
        }
    }
    return n;
}

# ---------------------------------------------------------------------------
# SSH connection-string parsing
# ---------------------------------------------------------------------------

"""Parse whatever the vendor handed the user into {ok, host, port, user, error}.

Accepted forms (vendors all format this differently):
    ssh user@host -p 2222
    ssh -p 2222 user@host
    ssh://user@host:2222
    user@host:2222
    user@host -p 2222
    user@host                 (port defaults to 22)

An explicit `-p <port>` wins over a `:port` suffix. Never raises: any surprise
comes back as ok:False with a human-readable error."""
def _parse_ssh_link(text: str) -> dict {
    bad = {"ok": False, "host": "", "port": 22, "user": "", "error": ""};
    try {
        s = str(text).strip().strip("'\"" + chr(96) + " ");
        if s.startswith("$ ") {
            s = s[2:].strip();
        }
        if not s {
            bad["error"] = "empty connection string";
            return bad;
        }
        toks: list[str] = [];
        try {
            toks = shlex.split(s);
        } except Exception {
            toks = s.split();
        }
        if len(toks) > 0 and os.path.basename(toks[0]) == "ssh" {
            toks = toks[1:];
        }
        # Pull an explicit port out of the flag stream, keep everything else.
        port = 0;
        rest: list[str] = [];
        i = 0;
        while i < len(toks) {
            t = toks[i];
            if t == "-p" and i + 1 < len(toks) {
                try {
                    port = int(toks[i + 1]);
                } except Exception {
                    port = -1;
                }
                i += 2;
                continue;
            }
            if t.startswith("-p") and len(t) > 2 and t[2:].isdigit() {
                port = int(t[2:]);
                i += 1;
                continue;
            }
            rest.append(t);
            i += 1;
        }
        user = "";
        host = "";
        inline_port = 0;
        for t in rest {
            mu = re.fullmatch(r"ssh://(?:([\w.\-]+)@)?([\w.\-]+)(?::(\d+))?/?", t);
            if mu is not None {
                user = str(mu.group(1)) if mu.group(1) is not None else "";
                host = str(mu.group(2));
                if mu.group(3) is not None {
                    inline_port = int(str(mu.group(3)));
                }
                break;
            }
            mp = re.fullmatch(r"([\w.\-]+)@([\w.\-]+)(?::(\d+))?", t);
            if mp is not None {
                user = str(mp.group(1));
                host = str(mp.group(2));
                if mp.group(3) is not None {
                    inline_port = int(str(mp.group(3)));
                }
                break;
            }
        }
        if not user or not host {
            bad["error"] = "couldn't find a user@host in that — paste the ssh command or link your vendor gave you";
            return bad;
        }
        if port == 0 {
            port = inline_port if inline_port > 0 else 22;
        }
        if port < 1 or port > 65535 {
            bad["user"] = user;
            bad["host"] = host;
            bad["error"] = "port must be between 1 and 65535";
            return bad;
        }
        return {"ok": True, "host": host, "port": port, "user": user, "error": ""};
    } except Exception as e {
        bad["error"] = f"couldn't parse that connection string: {e}";
        return bad;
    }
}

# ---------------------------------------------------------------------------
# Connection probe
# ---------------------------------------------------------------------------

"""Last non-empty line of ssh's stderr — its actual complaint ("Connection
refused", "Permission denied (publickey)", ...) rather than the whole banner."""
def _last_line(text: str) -> str {
    out = "";
    for ln in str(text).splitlines() {
        if ln.strip() {
            out = ln.strip();
        }
    }
    return out;
}

"""One non-interactive ssh round-trip. Returns {ok: bool, message: str}.

BatchMode=yes so a missing/rejected key fails fast instead of prompting for a
password; StrictHostKeyChecking=accept-new so a first connection to a fresh VM
does not hang on the host-key question. Never raises."""
def _probe(host: str, port: int, user: str, key_id: str) -> dict {
    try {
        paths_pair = _key_paths(key_id);
        privpath = paths_pair[0];
    } except Exception {
        return {"ok": False, "message": "unknown ssh key"};
    }
    if not privpath.exists() {
        return {"ok": False, "message": "private key file is missing — regenerate the key"};
    }
    argv = [
        "ssh", "-i", str(privpath), "-p", str(port),
        "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout={PROBE_CONNECT_TIMEOUT_S}",
        "-o", "StrictHostKeyChecking=accept-new",
        f"{user}@{host}", f"echo {PROBE_MARKER}"
    ];
    try {
        p = subprocess.run(argv, capture_output=True, text=True, timeout=PROBE_TIMEOUT_S);
        if p.returncode == 0 and PROBE_MARKER in str(p.stdout) {
            return {"ok": True, "message": "connected"};
        }
        msg = _last_line(str(p.stderr));
        if not msg {
            msg = f"ssh exited {p.returncode}";
        }
        return {"ok": False, "message": msg};
    } except subprocess.TimeoutExpired {
        return {"ok": False, "message": f"timed out after {PROBE_TIMEOUT_S}s — is the box up yet?"};
    } except Exception as e {
        return {"ok": False, "message": str(e)};
    }
}

# ---------------------------------------------------------------------------
# SSH keys
# ---------------------------------------------------------------------------

"""Extract the `SHA256:...` token from an `ssh-keygen -lf` line."""
def _fingerprint_of(pubpath: Path) -> str {
    try {
        p = subprocess.run(
            ["ssh-keygen", "-lf", str(pubpath)],
            capture_output=True, text=True, timeout=KEYGEN_TIMEOUT_S
        );
        if p.returncode != 0 {
            return "";
        }
        for tok in str(p.stdout).split() {
            if tok.startswith("SHA256:") {
                return tok;
            }
        }
        return "";
    } except Exception {
        return "";
    }
}

"""Generate a fresh ed25519 keypair on this machine and record its PUBLIC half.

The private key is written 0600 under `_key_dir()`; the public key + SHA256
fingerprint go on an `SshKey` node on the caller's root. *label* must be
filesystem-safe (`jobs.safe`); empty auto-generates `key-<8 hex>`.

Returns {ok, key_id, label, public_key, fingerprint, error}. `public_key` is
the full one-line `ssh-ed25519 AAAA... jms-<label>` text — that is exactly what
the user pastes into their GPU vendor's console."""
def generate_ssh_key(label: str = "") -> dict {
    fail = {"ok": False, "key_id": "", "label": "", "public_key": "", "fingerprint": "", "error": ""};
    lbl: str = str(label).strip();
    if not lbl {
        lbl = f"key-{uuid4().hex[:8]}";
    } elif not jobs.safe(lbl) {
        fail["error"] = "label may only contain letters, digits, dot, dash and underscore";
        return fail;
    }
    key_id = uuid4().hex;
    try {
        pair = _key_paths(key_id);
    } except Exception as e {
        fail["error"] = str(e);
        return fail;
    }
    privpath = pair[0];
    pubpath = pair[1];
    try {
        p = subprocess.run(
            ["ssh-keygen", "-t", "ed25519", "-f", str(privpath), "-N", "", "-C", f"jms-{lbl}"],
            capture_output=True, text=True, timeout=KEYGEN_TIMEOUT_S
        );
    } except Exception as e {
        fail["error"] = f"ssh-keygen failed: {e}";
        return fail;
    }
    if p.returncode != 0 {
        msg = _last_line(str(p.stderr));
        fail["error"] = msg if msg else f"ssh-keygen exited {p.returncode}";
        return fail;
    }
    try {
        os.chmod(str(privpath), 0o600);
        os.chmod(str(pubpath), 0o644);
    } except Exception {}
    try {
        public_key: str = str(pubpath.read_text()).strip();
    } except Exception as e {
        fail["error"] = f"could not read generated public key: {e}";
        return fail;
    }
    fingerprint = _fingerprint_of(pubpath);
    k = SshKey(
        key_id=key_id,
        label=lbl,
        public_key=public_key,
        fingerprint=fingerprint,
        created_at=_now()
    );
    root ++> k;
    # NB: key_id + label only. Never the private path, never key material.
    audit.log("cluster_key_generate", {"key_id": key_id, "label": lbl});
    return {
        "ok": True,
        "key_id": key_id,
        "label": lbl,
        "public_key": public_key,
        "fingerprint": fingerprint,
        "error": ""
    };
}

"""The caller's keypairs, newest first. Returns
{ok, keys:[{key_id, label, public_key, fingerprint, created_at}], error}.
Public material only — no private key is ever returned."""
def list_ssh_keys() -> dict {
    out: list[dict] = [];
    for k in [root -->][?:SshKey] {
        out.append({
            "key_id": k.key_id,
            "label": k.label,
            "public_key": k.public_key,
            "fingerprint": k.fingerprint,
            "created_at": k.created_at
        });
    }
    out.sort(key=lambda d: dict -> str { return str(d["created_at"]); }, reverse=True);
    return {"ok": True, "keys": out, "error": ""};
}

"""Delete a keypair: both files on disk plus the graph node.

Refuses while any of the caller's clusters still references it (deleting would
strand them). Returns {ok, error}."""
def delete_ssh_key(key_id: str) -> dict {
    k = _find_key(key_id);
    if k is None {
        return {"ok": False, "error": "unknown ssh key"};
    }
    used = _key_use_count(key_id);
    if used > 0 {
        return {"ok": False, "error": f"key is in use by {used} cluster(s)"};
    }
    try {
        pair = _key_paths(key_id);
        for pth in [pair[0], pair[1]] {
            try {
                pth.unlink();
            } except Exception {}
        }
    } except Exception {}
    lbl = k.label;
    del k;
    audit.log("cluster_key_delete", {"key_id": key_id, "label": lbl});
    return {"ok": True, "error": ""};
}

# ---------------------------------------------------------------------------
# Clusters
# ---------------------------------------------------------------------------

"""Save a BYO GPU box the user already provisioned somewhere else.

*link_text* is whatever their vendor gave them (see `_parse_ssh_link` for the
accepted forms); *key_id* names one of the caller's `SshKey`s — the public half
must already be installed on that box.

The connection is probed once, but the cluster is SAVED EITHER WAY: a fresh VM
is often still booting when the user pastes the link, and they can
`retest_cluster` later. So ok=True with test_ok=False is the normal
"saved, not reachable yet" outcome — do not treat it as an error.

Returns {ok, cluster_id, test_ok, test_message, error}."""
def add_cluster(label: str, link_text: str, key_id: str) -> dict {
    fail = {"ok": False, "cluster_id": "", "test_ok": False, "test_message": "", "error": ""};
    lbl = str(label).strip();
    if not jobs.safe(lbl) {
        fail["error"] = "label is required and may only contain letters, digits, dot, dash and underscore";
        return fail;
    }
    if _find_key(key_id) is None {
        fail["error"] = "unknown ssh key";
        return fail;
    }
    parsed = _parse_ssh_link(link_text);
    if not parsed["ok"] {
        fail["error"] = str(parsed["error"]);
        return fail;
    }
    host = str(parsed["host"]);
    port = int(str(parsed["port"]));
    user = str(parsed["user"]);
    probe = _probe(host, port, user, key_id);
    test_ok = bool(probe["ok"]);
    test_msg = str(probe["message"]);
    cluster_id = uuid4().hex;
    c = Cluster(
        cluster_id=cluster_id,
        label=lbl,
        host=host,
        port=port,
        user=user,
        key_id=key_id,
        created_at=_now(),
        last_test_ok=test_ok,
        last_test_at=_now(),
        last_test_msg=test_msg
    );
    root ++> c;
    # host/port are the user's own infra, not a secret; the key path and the
    # assembled ssh command are never logged.
    audit.log("cluster_add", {
        "cluster_id": cluster_id, "label": lbl, "host": host,
        "port": port, "key_id": key_id, "test_ok": test_ok
    });
    return {
        "ok": True,
        "cluster_id": cluster_id,
        "test_ok": test_ok,
        "test_message": test_msg,
        "error": ""
    };
}

"""The caller's saved clusters, newest first. Returns
{ok, clusters:[{cluster_id, label, host, port, user, key_id, key_label,
created_at, last_test_ok, last_test_at, last_test_msg}], error}.

`key_label` is resolved from the referenced SshKey and is "" when that key has
since been deleted (a cluster is never orphan-crashed by a missing key)."""
def list_clusters() -> dict {
    labels: dict[str, str] = {};
    for k in [root -->][?:SshKey] {
        labels[k.key_id] = k.label;
    }
    out: list[dict] = [];
    for c in [root -->][?:Cluster] {
        out.append({
            "cluster_id": c.cluster_id,
            "label": c.label,
            "host": c.host,
            "port": c.port,
            "user": c.user,
            "key_id": c.key_id,
            "key_label": labels.get(c.key_id, ""),
            "created_at": c.created_at,
            "last_test_ok": c.last_test_ok,
            "last_test_at": c.last_test_at,
            "last_test_msg": c.last_test_msg
        });
    }
    out.sort(key=lambda d: dict -> str { return str(d["created_at"]); }, reverse=True);
    return {"ok": True, "clusters": out, "error": ""};
}

"""Re-probe a saved cluster and cache the outcome on its node.

ok=False only when the cluster_id is unknown — an unreachable box is a
successful test that reports test_ok=False.
Returns {ok, test_ok, test_message, error}."""
def retest_cluster(cluster_id: str) -> dict {
    c = _find_cluster(cluster_id);
    if c is None {
        return {"ok": False, "test_ok": False, "test_message": "", "error": "unknown cluster"};
    }
    probe = _probe(c.host, int(c.port), c.user, c.key_id);
    c.last_test_ok = bool(probe["ok"]);
    c.last_test_msg = str(probe["message"]);
    c.last_test_at = _now();
    return {
        "ok": True,
        "test_ok": c.last_test_ok,
        "test_message": c.last_test_msg,
        "error": ""
    };
}

"""Change a cluster's display label (nothing else moves). Returns {ok, error}."""
def rename_cluster(cluster_id: str, label: str) -> dict {
    lbl = str(label).strip();
    if not jobs.safe(lbl) {
        return {"ok": False, "error": "label is required and may only contain letters, digits, dot, dash and underscore"};
    }
    c = _find_cluster(cluster_id);
    if c is None {
        return {"ok": False, "error": "unknown cluster"};
    }
    old = c.label;
    c.label = lbl;
    audit.log("cluster_rename", {"cluster_id": cluster_id, "from": old, "to": lbl});
    return {"ok": True, "error": ""};
}

"""Forget a cluster. The SSH key it used is left alone (other clusters may
share it, and it is still installed on the remote box). Returns {ok, error}."""
def remove_cluster(cluster_id: str) -> dict {
    c = _find_cluster(cluster_id);
    if c is None {
        return {"ok": False, "error": "unknown cluster"};
    }
    detail = {"cluster_id": cluster_id, "label": c.label, "host": c.host};
    del c;
    audit.log("cluster_remove", detail);
    return {"ok": True, "error": ""};
}

# ---------------------------------------------------------------------------
# Cross-module contract (server-side only — NOT an HTTP endpoint)
# ---------------------------------------------------------------------------

"""Resolved ssh command for a saved cluster, for remote/supervisor.py.

CONTRACT (this is the surface cloudruns.sv.jac / jms_train.sv.jac consume —
call it directly, the way spheron.resolved_api_key() is called today; it is
deliberately NOT registered in main.jac, so it is never HTTP-reachable):

    returns exactly  f"ssh -i {shlex.quote(str(privpath))} -p {port} {user}@{host}"

    e.g.  ssh -i /Users/me/.jms/ssh_keys/9f3c...e1 -p 2222 root@203.0.113.10

That string is what `Transport.__init__` in remote/supervisor.py parses, and is
what belongs in runspec.json as `ssh_override` (supervisor.resolve_transport()
prefers ssh_override over any API-supplied sshCommand). The supervisor adds its
own -o BatchMode/ConnectTimeout/StrictHostKeyChecking/UserKnownHostsFile flags,
so do NOT add them here.

Returns "" (empty string) when the cluster_id is unknown, when its SshKey has
been deleted, or when the private key file is missing — the caller decides how
to surface "this cluster is no longer usable". Never raises. The result
contains a filesystem path to private key material: pass it into runspec.json,
never into audit.log or a client response."""
def cluster_ssh_override(cluster_id: str) -> str {
    c = _find_cluster(cluster_id);
    if c is None {
        return "";
    }
    if _find_key(c.key_id) is None {
        return "";
    }
    try {
        pair = _key_paths(c.key_id);
    } except Exception {
        return "";
    }
    privpath = pair[0];
    if not privpath.exists() {
        return "";
    }
    return f"ssh -i {shlex.quote(str(privpath))} -p {int(c.port)} {c.user}@{c.host}";
}
