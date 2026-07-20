"""Client auth session helpers — bearer headers, local re-mint, expiry signaling.

`local_session()` runs once on mount in frontend.cl.jac; mid-session JWT expiry
otherwise 401s every call with no recovery. This module centralizes proactive
refresh (local desktop re-mint) and reactive recovery (401 → re-mint or logout
+ `jac-auth-expired` event so the shell bounces to <Login/>).

All helpers are `:pub` — the cl compiler only emits JS `export` for public
symbols; without that, importers (frontend / Chat / AppShell) fail at runtime
with `does not provide an export named '…'` and the UI never paints.
"""

import from "@jac/runtime" { jacIsLoggedIn, jacLogout, jacSetToken }
sv import from .auth { local_mode, local_session, session_alive }

glob:pub AUTH_EVENT: str = "jac-auth-expired";

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

"""True when *tok* looks like a usable JWT (non-empty string)."""
def _usableToken(tok: any) -> bool {
    if tok is None { return False; }
    s = str(tok).strip();
    if not s or s == "None" or s == "null" { return False; }
    # Reject accidental object stringifications from a bad RPC unwrap.
    if s.startswith("{") or s.startswith("[") { return False; }
    return True;
}

"""Re-mint the implicit local-desktop JWT. No-op (returns False) in prod.

Clears the client endpoint cache before calling `local_session` so a cached
empty/stale result cannot permanently strand the gate on <Login/> (local_session
is classified as a non-writer reader and would otherwise be cached for 60s)."""
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
    # Drop any cached local_session/local_mode results + stale JWT from a prior
    # server process (JWT secret rotates on restart → 401 storms).
    try {
        jacLogout();
    } except Exception {}
    try {
        tok: any = None;
        tok = await local_session();
        if _usableToken(tok) {
            jacSetToken(str(tok).strip());
            return True;
        }
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
