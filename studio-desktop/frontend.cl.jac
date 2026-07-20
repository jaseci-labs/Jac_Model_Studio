"""studio - client entry. Auth gate + app shell.

`app` is the one `def:pub` client surface (the served UI). Behavior depends on
how the server was started:

- **Local desktop** (start.sh sets JAC_LOCAL_USER=1 → `local_mode()` True): the
  gate calls `local_session()` over the native bridge, which registers + logs in
  the implicit local user IN-PROCESS and returns a JWT. The desktop webview host
  can't reach `/user/register` + `/user/login` over HTTP (the loopback broker
  only proxies those in CEF mode), so the in-process `local_session()` endpoint
  does the /user/* dance server-side and hands back a token. The client
  `jacSetToken()`s it, after which every authenticated `def:priv` call succeeds
  and <AppShell/> mounts — no login screen. `touchSession()` re-mints on a timer
  so a short JWT TTL cannot strand the user mid-session.
- **Production** (start_prod.sh leaves the env unset → `local_mode()` False):
  logged-out visitors get the <Login/> gate, exactly as before. `session_alive`
  pings detect expiry; `jac-auth-expired` bounces back to <Login/>.

Every var holding an `await` result is pre-declared (compiled-JS let-scoping
would otherwise leave post-await checks with a ReferenceError)."""

import from "@jac/runtime" { jacIsLoggedIn }
import from react { useEffect }
sv import from .auth { local_mode }
import from .auth_session { AUTH_EVENT, refreshLocalSession, touchSession }
import from .components.AppShell { AppShell }
import from .components.Login { Login }

def:pub app -> JsxElement {
    has authTick: int = 0,
        checking: bool = True,
        loggedIn: bool = False;

    """On mount: read local_mode() once. Local desktop mints an in-process
    session token (see module docstring); prod falls through to <Login/> when
    no session is present. Retries briefly — the native host can 401 pub
    endpoints for a beat while the in-process server finishes booting."""
    async can with entry {
        lm: bool = False;
        ok: bool = False;
        attempt: int = 0;
        while attempt < 10 {
            attempt = attempt + 1;
            try {
                lm = await local_mode();
            } except Exception {
                lm = False;
            }
            if lm {
                try {
                    ok = await refreshLocalSession();
                } except Exception {
                    ok = False;
                }
                if ok {
                    break;
                }
            } elif jacIsLoggedIn() {
                ok = True;
                break;
            }
        }
        loggedIn = ok or jacIsLoggedIn();
        checking = False;
    }

    useEffect(lambda {
        if not (loggedIn or jacIsLoggedIn()) {
            return lambda { };
        }
        touchSession();
        iv: any = None;
        iv = setInterval(lambda { touchSession(); }, 240000);
        handler = lambda(_e: any) {
            loggedIn = jacIsLoggedIn();
            authTick = authTick + 1;
        };
        w: any = window;
        w.addEventListener(AUTH_EVENT, handler);
        return lambda {
            if iv is not None {
                clearInterval(float(str(iv)));
            }
            w.removeEventListener(AUTH_EVENT, handler);
        };
    }, [authTick, loggedIn]);

    # Still resolving local_mode()/local_session() — hold a blank frame so we
    # never flash the login screen (which local users should never see).
    if checking {
        return <div className="h-screen bg-[#0a0a0a]" />;
    }
    # Valid session (local auto-login OR prod login) → app shell.
    if loggedIn or jacIsLoggedIn() {
        return <AppShell />;
    }
    # Production gate for logged-out visitors (or expired session).
    return <Login
        onDone={lambda {
            loggedIn = True;
            authTick = authTick + 1;
        }}
    />;
}
