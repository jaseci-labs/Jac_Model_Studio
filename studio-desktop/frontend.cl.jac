"""studio - client entry. Auth gate + app shell.

`app` is the one `def:pub` client surface (the served UI). Behavior depends on
how the server was started:

- **Local desktop** (start.sh sets JAC_LOCAL_USER=1 → `local_mode()` True): the
  gate silently registers + logs in a single fixed local user on first launch,
  so there is no login screen. The graph still hangs off that user's `root`, so
  persistence/isolation are unchanged — it's just one implicit user.
- **Production** (start_prod.sh leaves the env unset → `local_mode()` False):
  logged-out visitors get the <Login/> gate, exactly as before.

After a session is established (auto or manual) `authTick` bumps so this
component re-renders and `jacIsLoggedIn()` returns true, mounting <AppShell/>.
Every var holding an `await` result is pre-declared (compiled-JS let-scoping
would otherwise leave post-await checks with a ReferenceError)."""

import from "@jac/runtime" { jacIsLoggedIn, jacLogin, jacSignup }
sv import from .auth { local_mode }
import from .components.AppShell { AppShell }
import from .components.Login { Login }

# Fixed credentials for the implicit local desktop user. Only ever used against
# a JAC_LOCAL_USER server on the user's own machine; the graph is local.
glob LOCAL_EMAIL: str = "local@studio.local";
glob LOCAL_PASSWORD: str = "local-desktop-session";

def:pub app -> JsxElement {
    has authTick: int = 0,
        checking: bool = True;

    """On mount: if not already logged in and the server is in local mode,
    auto-provision the local session. Signup is idempotent — it fails harmlessly
    once the user exists, and login succeeds either way."""
    async can with entry {
        if jacIsLoggedIn() {
            checking = False;
            return;
        }
        lm: bool = False;
        try {
            lm = await local_mode();
        } except Exception {
            lm = False;
        }
        if lm {
            try {
                await jacSignup(LOCAL_EMAIL, LOCAL_PASSWORD);
            } except Exception { }
            try {
                await jacLogin(LOCAL_EMAIL, LOCAL_PASSWORD);
            } except Exception { }
        }
        # Flipping `checking` re-renders; jacIsLoggedIn() is now true on success,
        # so <AppShell/> mounts. On failure the login gate shows as a fallback.
        checking = False;
    }

    if jacIsLoggedIn() {
        return <AppShell />;
    }
    # Local auto-login still in flight — hold a blank frame instead of flashing
    # the login screen (which local users should never see).
    if checking {
        return <div className="h-screen bg-[#0a0a0a]" />;
    }
    return <Login onDone={lambda -> None { authTick = authTick + 1; }} />;
}
