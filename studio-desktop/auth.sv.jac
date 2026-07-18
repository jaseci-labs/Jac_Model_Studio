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

"""True when the server was started for local single-user desktop use
(start.sh sets JAC_LOCAL_USER=1). The client uses this to auto-provision a
local session and skip the login screen. `def:pub` so a logged-out client can
read it; prod (start_prod.sh) leaves the env unset, so this returns False and
the real login gate is shown."""
def:pub local_mode() -> bool {
    return bool(os.environ.get("JAC_LOCAL_USER", ""));
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
