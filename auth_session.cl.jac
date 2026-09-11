"""Client auth session helpers — bearer headers, local re-mint, expiry signaling.

`local_session()` runs once on mount in frontend.cl.jac; mid-session JWT expiry
otherwise 401s every call with no recovery. This module centralizes proactive
refresh (local desktop re-mint) and reactive recovery (401 → re-mint or logout
+ `jac-auth-expired` event so the shell bounces to <Login/>).

All helpers are `:pub` — the cl compiler only emits JS `export` for public
symbols; without that, importers (frontend / Chat / AppShell) fail at runtime
with `does not provide an export named '…'` and the UI never paints.
"""

import from "@jac/runtime" { jacIsLoggedIn, jacLogout, __setLocalStorage }
sv import from .auth { local_mode, local_session, session_alive }

glob:pub AUTH_EVENT: str = "jac-auth-expired";

# glob does not cross the compiled-module boundary; expose via accessor.
def:pub authEventName() -> str { return AUTH_EVENT; }

"""JSON fetch headers with the current bearer token (for raw SSE fetch)."""
def:pub bearerHeaders() -> dict {
    tk: str = "";
    try {
        w: any = window;
        tk = str(w.localStorage.getItem("jac_token") or "");
    } except Exception {}
    hdrs: dict = {"Content-Type": "application/json"};
    if tk {
        hdrs["Authorization"] = "Bearer " + tk;
    }
    return hdrs;
}

"""True when *tok* looks like a usable session token (non-empty string)."""
def _usableToken(tok: any) -> bool {
    if tok is None { return False; }
    s = str(tok).strip();
    if not s or s == "None" or s == "null" { return False; }
    # Reject accidental object stringifications from a bad RPC unwrap.
    if s.startswith("{") or s.startswith("[") { return False; }
    return True;
}

"""Re-mint the implicit local-desktop JWT. No-op (returns False) in prod.

MINT FIRST, THEN SWAP — never the other way round. An earlier shape called
`jacLogout()` *before* awaiting `local_session()`, which left localStorage with
no `jac_token` for the ~1 RTT the mint takes. `__doFuncFetch` reads the token at
call time, so every request that started inside that window went out with no
`Authorization` header and came back 401. That is the whole cold-start bug: on
first paint `frontend.cl.jac`'s `[authTick, loggedIn]` effect fires
`touchSession()` (→ here) in the same commit that mounts <Landing/>, whose
`loadGlance()` is already walking `list_projects` → `list_runs` → `list_evals`.
React runs child effects before parent effects, so loadGlance starts first and
its later awaits land squarely inside the hole — hence the red
`POST /function/list_evals 401` on every fresh load, self-healing on the next
call because by then the token is back.

The pre-clear bought nothing: `local_session()` is `def:pub` (auth.sv.jac) and
never looks at the caller's token, so a stale JWT cannot block the mint. The
stale-token protection it was written for is preserved — just moved to the mint
FAILURE path, which is the only branch where a dead token would actually strand
the gate on <Login/>."""
async def:pub refreshLocalSession() -> bool {
    lm: bool = False;
    try {
        lm = await local_mode();
    } except Exception {
        lm = False;
    }
    if not lm {
        return False;
    }
    tok: any = None;
    try {
        tok = await local_session();
    } except Exception {
        tok = None;
    }
    if _usableToken(tok) {
        # Atomic swap: the old token stayed valid right up to this write, so no
        # concurrent request ever saw a token-less localStorage.
        __setLocalStorage("jac_token", str(tok).strip());
        return True;
    }
    # Mint failed — NOW drop whatever is there (typically a JWT from a prior
    # server process, whose signing secret rotated on restart) so the gate falls
    # through to <Login/> instead of 401-storming against a dead token.
    try {
        jacLogout();
    } except Exception {}
    return False;
}

"""Clear session and notify the auth gate to re-render into <Login/>."""
def:pub signalExpired() {
    jacLogout();
    try {
        w: any = window;
        w.dispatchEvent(new(CustomEvent, AUTH_EVENT));  # jac:ignore[E1053]
    } except Exception {}
}

"""Attempt recovery after a 401. Returns True when the session was restored."""
async def:pub handleUnauthorized() -> bool {
    restored: bool = False;
    restored = await refreshLocalSession();
    if restored {
        return True;
    }
    signalExpired();
    return False;
}

"""Proactive keepalive — re-mint locally, ping `session_alive` in prod."""
async def:pub touchSession() -> bool {
    lm: bool = False;
    try {
        lm = await local_mode();
    } except Exception {
        lm = False;
    }
    if lm {
        return await refreshLocalSession();
    }
    if not jacIsLoggedIn() {
        return False;
    }
    try {
        await session_alive();
        return True;
    } except Exception {
        return await handleUnauthorized();
    }
}
