"""studio - multi-tenant identity + per-user artifact paths.

The security model: in a plain `def` (= `def:priv`) endpoint `root` is the caller's
OWN isolated root, so `jid(root)` is the stable per-user identity. Graph-backed data
(chats, messages, eval nodes, workspaces) is therefore isolated for free by the
framework — `[root -->][?:Chat]` only ever returns the caller's chats. See
`jac guide jac-sv-auth` + `jac-sv-multi-user`.

This module namespaces the NON-graph artifacts (training / eval / builder / cpt job
files + logs) under a per-user directory, so one tenant cannot list, read, stop, or
delete another tenant's detached jobs by guessing a name or id. Defense-in-depth on
top of the graph isolation.

INVARIANT: only call `uid()` / `user_*()` from inside a request context (a `def`
endpoint body, or a helper invoked from one). `root` is unbound outside a served
request, so these must never run at import time or in a plain `jac run` script.
"""

import os;
import models;
import paths;
import from pathlib { Path }
import from jaclang { JacRuntime }

"""True when the server was started for local single-user desktop use
(start.sh sets JAC_LOCAL_USER=1). The client uses this to auto-provision a
local session and skip the login screen. `def:pub` so a logged-out client can
read it; prod (start_prod.sh) leaves the env unset, so this returns False and
the real login gate is shown."""
def:pub local_mode() -> bool {
    return bool(os.environ.get("JAC_LOCAL_USER", ""));
}

# Fixed credentials for the implicit local desktop user. Only ever used against
# a JAC_LOCAL_USER server on the user's own machine; the graph is local.
glob LOCAL_EMAIL: str = "local@studio.local";
glob LOCAL_PASSWORD: str = "local-desktop-session";

"""Local-desktop auto-session: register (idempotent) + login the implicit local
user IN-PROCESS and return a JWT.

Why this exists: the desktop webview target can't reach `/user/register` +
`/user/login` over HTTP. The only HTTP server in webview mode is the loopback
oauth broker (the `studio` binary), which serves `/__jac/*` + static files and
does NOT proxy `/user/*` to the in-process jac-scale server (that proxying is
wired only in CEF mode via sv_bridge). The in-process API is reachable only
through the native `__jac_invoke` bridge, which dispatches `/walker/*` and
`/function/*` — so the client calls THIS endpoint over that bridge and gets
back a token it can `jacSetToken()` with, after which every authenticated
`def:priv` call succeeds.

Mints the token via `Jac.get_user_manager(base_path=...)` directly — the same
factory `JacAPIServer` itself calls at startup (`Jac.get_user_manager` ->
`UserManager(base_path=...)`), pointed at the same `<base_path>/.jac/data/main.db`
SQLite file the running server's own UserManager reads/writes. Tokens are
opaque `secrets.token_urlsafe` strings looked up by exact match (no JWT, no
secret to reproduce) — a second UserManager instance writing to the same file
is safe and immediately valid.

(An earlier version of this routed through a desktop-webview-only in-process
TestClient bridge; that module does not exist in this jaclang install for
ANY target, desktop included, so it always failed here — hence the rewrite.)

Returns "" on any failure or when not in local mode; the client then falls
back to the production login gate. `def:pub` (no auth) so a logged-out client
can bootstrap. The `local_mode()` guard is defense-in-depth — prod never calls
this."""
def:pub local_session() -> str {
    if not local_mode() { return ""; }
    try {
        um = JacRuntime.get_user_manager(base_path=str(paths.studio_root()));
        # Idempotent — "already exists" on second+ launch is expected.
        try {
            um.create_user(LOCAL_EMAIL, LOCAL_PASSWORD);
        } except Exception { }
        result = um.authenticate(LOCAL_EMAIL, LOCAL_PASSWORD);
        if result is not None and "token" in result {
            return str(result["token"]);
        }
    } except Exception { }
    return "";
}

"""Lightweight auth probe for the client keepalive loop. `def:priv` — a 401 means
the JWT expired or is invalid; the client then re-mints (local) or shows login."""
def session_alive() -> bool {
    return True;
}

"""Stable per-user id — the caller's root jid. Request-context only."""
def uid() -> str {
    return jid(root);
}

"""Per-user results tree: <data_root>/results/users/<uid>/.

Everything a user's SFT/DPO training, eval, and builder jobs write lands here, so
the list/stop/delete endpoints are scoped to the caller. Callers mkdir it on first
use (parents=True, exist_ok=True)."""
def user_results_dir() -> Path {
    return models.results_dir() / "users" / uid();
}

"""Per-user path under the shared workspace checkout (used by CPT, whose corpus
lives in the repo). <workspace_root>/<rel_prefix>/users/<uid>/<rest>."""
def user_workspace_dir(rel_prefix: str, rest: str = "") -> Path {
    base = paths.workspace_root() / rel_prefix / "users" / uid();
    return base / rest if rest else base;
}
