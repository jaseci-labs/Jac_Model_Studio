"""Login / signup gate. Shown by frontend.cl.jac's `app` when `jacIsLoggedIn()` is
false. On a successful login (or signup→login) it calls `onDone`, which bumps the
shell's auth tick so it re-renders into <AppShell/>.

Auth helpers come from @jac/runtime: jacLogin (async -> bool), jacSignup
(async -> dict {"success": bool, ...}). Signup does NOT establish a session, so it
is always followed by a jacLogin with the same credentials — see jac-cl-auth.

On local desktop (`local_mode()` True) the webview cannot reach `/user/login`
over HTTP, so the form routes through `refreshLocalSession()` (native bridge →
in-process register/login) instead of `jacLogin`. Every var that holds an
`await` result is pre-declared (let-scoping in compiled JS would otherwise leave
the post-await if-checks with a ReferenceError).

The two inputs carry their own `aria-label`; they also declare `autoComplete` so
password managers fill them (`username` + `current-password`/`new-password` by
mode). The error line is `var(--danger)` (palette) rather than a Tailwind colour
utility."""

import from "@jac/runtime" { jacLogin, jacSignup }
sv import from ..auth { local_mode }
import from ..auth_session { refreshLocalSession }
import from .shared.Field { Field }

def _heading(mode: str) -> str {
    if mode == "signup" { return "create account"; }
    return "sign in";
}

def _submitLabel(busy: bool, mode: str) -> str {
    if busy { return "..."; }
    return _heading(mode);
}

def:pub Login(onDone: Callable[([], None)]) -> JsxElement {
    has mode: str = "login",
        email: str = "",
        password: str = "",
        busy: bool = False,
        error: str = "";

    async def submit() -> None {
        if busy { return; }
        busy = True;
        error = "";

        # Local desktop: mint via the native bridge. Ignore the form fields —
        # the server uses fixed local credentials (see auth.LOCAL_*).
        lm: bool = False;
        try {
            lm = await local_mode();
        } except Exception {
            lm = False;
        }
        if lm {
            okLocal: bool = False;
            try {
                okLocal = await refreshLocalSession();
            } except Exception {
                okLocal = False;
            }
            if okLocal {
                busy = False;
                onDone();
                return;
            }
            error = "local session failed — is the desktop backend running?";
            busy = False;
            return;
        }

        em = email.strip();
        if not em or not password {
            error = "email and password are required";
            busy = False;
            return;
        }

        if mode == "signup" {
            res: dict | None = None;
            loginOk: bool = False;
            try {
                res = await jacSignup(em, password);
                if not bool(res["success"]) {
                    error = "signup failed — email may already be in use";
                    busy = False;
                    return;
                }
                loginOk = await jacLogin(em, password);
                if not loginOk {
                    error = "account created, but login failed — retry";
                    busy = False;
                    return;
                }
            } except Exception {
                error = "connection error — is the backend running?";
                busy = False;
                return;
            }
            busy = False;
            onDone();
            return;
        }

        ok: bool = False;
        try {
            ok = await jacLogin(em, password);
            if not ok {
                error = "invalid email or password";
                busy = False;
                return;
            }
        } except Exception {
            error = "connection error — is the backend running?";
            busy = False;
            return;
        }
        busy = False;
        onDone();
    }

    def onMode(m: str) -> None {
        mode = m;
        error = "";
    }

    inputCls: str = "exp-input";

    return <div className="flex h-screen items-center justify-center bg-background">
        <div className="w-full max-w-sm exp-panel p-7">
            <div className="micro-label mb-2">JAC.STUDIO</div>
            <h1 className="exp-display mb-5 text-3xl lowercase">{_heading(mode)}</h1>

            <div className="mb-5 flex gap-1.5">
                <button
                    onClick={lambda (e: MouseEvent) { onMode("login"); }}
                    className={"exp-chip " + ("exp-chip-active" if mode == "login" else "")}
                >SIGN IN</button>
                <button
                    onClick={lambda (e: MouseEvent) { onMode("signup"); }}
                    className={"exp-chip " + ("exp-chip-active" if mode == "signup" else "")}
                >CREATE</button>
            </div>

            <div className="flex flex-col gap-3">
                <Field label="EMAIL">
                    <input
                        type="text"
                        value={email}
                        onChange={lambda (e: ChangeEvent) { email = e.target.value; }}
                        placeholder="you@example.com"
                        className={inputCls}
                        aria-label="Email"
                        autoComplete="username"
                    />
                </Field>
                <Field label="PASSWORD">
                    <input
                        type="password"
                        value={password}
                        onChange={lambda (e: ChangeEvent) { password = e.target.value; }}
                        placeholder="password"
                        className={inputCls}
                        aria-label="Password"
                        autoComplete={"new-password" if mode == "signup" else "current-password"}
                        onKeyDown={lambda (e: KeyboardEvent) {
                            if e.key == "Enter" { submit(); }
                        }}
                    />
                </Field>
            </div>

            {error and <p className="mt-3 font-mono text-xs" role="alert" style={{"color": "var(--danger)"}}>{error}</p>}

            <button
                onClick={lambda (e: MouseEvent) { submit(); }}
                disabled={busy}
                className="exp-btn exp-btn-accent mt-6 w-full !py-2.5 !text-[11px]"
            >
                {_submitLabel(busy, mode)}
            </button>
        </div>
    </div>;
}
