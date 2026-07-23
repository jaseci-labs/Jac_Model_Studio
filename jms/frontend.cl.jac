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
import from .auth_session { authEventName, refreshLocalSession, touchSession }
import from .components.AppShell { AppShell }
import from .components.Login { Login }
import from .components.jms.Landing { Landing }
import from .components.jms.JmsShell { JmsShell }

def:pub app -> JsxElement {
    has authTick: int = 0,
        checking: bool = True,
        surface: str = "";

    """Read the current surface from the URL hash (#jms / #experiments / else "")."""
    def _hashSurface() -> str {
        try {
            w: any = window;
            s: str = str(w.location.hash).replace("#", "");
            if s == "jms" or s == "experiments" { return s; }
        } except Exception { }
        return "";
    }

    """Navigate to a surface AND push a browser history entry so the OS/browser
    Back button returns to the previous surface (popstate handler below restores
    it). Hash-based so a refresh/deeplink lands on the same surface."""
    def goSurface(s: str) -> None {
        surface = s;
        try {
            w: any = window;
            w.history.pushState({"surface": s}, "", ("#" + s) if s else "#");
        } except Exception { }
    }

    """On mount: read local_mode() once. Local desktop mints an in-process
    session token (see module docstring); prod falls through to <Login/> when
    no session is present."""
    async can with entry {
        # apply persisted light/dark mode before first paint
        try {
            dc: any = document;
            wm: any = window;
            md: str = "dark";
            sv2: any = wm.localStorage.getItem("jacml.mode");
            if sv2 { md = str(sv2); }
            elif wm.matchMedia and wm.matchMedia("(prefers-color-scheme: light)").matches { md = "light"; }
            if md == "dark" { dc.documentElement.classList.add("dark"); }
            else { dc.documentElement.classList.remove("dark"); }
        } except Exception { }
        lm: bool = False;
        try {
            lm = await local_mode();
        } except Exception {
            lm = False;
        }
        if lm {
            try {
                await refreshLocalSession();
            } except Exception { }
        }
        checking = False;
    }

    useEffect(lambda {
        if not jacIsLoggedIn() {
            return lambda { };
        }
        touchSession();
        iv: any = None;
        iv = setInterval(lambda { touchSession(); }, 240000);
        handler = lambda(_e: any) { authTick = authTick + 1; };
        w: any = window;
        evtName = authEventName();
        w.addEventListener(evtName, handler);
        return lambda {
            if iv is not None {
                clearInterval(float(str(iv)));
            }
            w.removeEventListener(evtName, handler);
        };
    }, [authTick]);

    # Browser Back/Forward ↔ surface sync. On mount, adopt the URL hash (so a
    # refresh/deeplink lands on the right surface); listen for popstate (Back)
    # and restore the surface from the hash.
    useEffect(lambda {
        init = _hashSurface();
        if init { surface = init; }
        wp: any = window;
        onPop = lambda(_e: any) { surface = _hashSurface(); };
        wp.addEventListener("popstate", onPop);
        return lambda { wp.removeEventListener("popstate", onPop); };
    }, []);

    # Still resolving local_mode()/local_session() — hold a blank frame so we
    # never flash the login screen (which local users should never see).
    if checking {
        return <div className="h-screen bg-background" />;
    }
    # Valid session (local auto-login OR prod login) → surface router:
    # "" = hub landing, "jms" = new product shell, "experiments" = the existing
    # AppShell — its WorkspaceBar's "‹ EXPERIMENTS" button calls onHub directly,
    # so no separate overlay button is needed here anymore.
    if jacIsLoggedIn() {
        if surface == "jms" {
            return <JmsShell
                onHub={lambda { goSurface(""); }}
            />;
        }
        if surface == "experiments" {
            return <AppShell onHub={lambda { goSurface(""); }} />;
        }
        return <Landing
            onPick={lambda(s: str) { goSurface(s); }}
        />;
    }
    # Production gate for logged-out visitors (or expired session).
    return <Login onDone={lambda { authTick = authTick + 1; }} />;
}
