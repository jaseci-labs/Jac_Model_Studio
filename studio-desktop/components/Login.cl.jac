"""Login / signup gate. Shown by frontend.cl.jac's `app` when `jacIsLoggedIn()` is
false. On a successful login (or signup→login) it calls `onDone`, which bumps the
shell's auth tick so it re-renders into <AppShell/>.

Auth helpers come from @jac/runtime: jacLogin (async -> bool), jacSignup
(async -> dict {"success": bool, ...}). Signup does NOT establish a session, so it
is always followed by a jacLogin with the same credentials — see jac-cl-auth. Every
var that holds an `await` result is pre-declared (let-scoping in compiled JS would
otherwise leave the post-await if-checks with a ReferenceError)."""

import from "@jac/runtime" { jacLogin, jacSignup }
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
        em = email.strip();
        if not em or not password {
            error = "email and password are required";
            return;
        }
        busy = True;
        error = "";

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
        onDone();
    }

    def onMode(m: str) -> None {
        mode = m;
        error = "";
    }

    inputCls: str = "w-full rounded-md border border-neutral-700 bg-[#121212] px-2 py-1 text-sm text-neutral-100 outline-none placeholder:text-neutral-600 focus:border-neutral-500";

    return <div className="flex h-screen items-center justify-center bg-[#0a0a0a]">
        <div className="w-full max-w-sm rounded-lg border border-neutral-800 bg-[#0d0d0d] p-6">
            <div className="micro-label mb-1">JAC.STUDIO</div>
            <h1 className="mb-4 text-lg text-neutral-100">{_heading(mode)}</h1>

            <div className="mb-4 flex gap-1">
                <button
                    onClick={lambda (e: MouseEvent) { onMode("login"); }}
                    className={"rounded-md border px-3 py-1 text-xs transition-colors " + (
                        "border-neutral-500 bg-[#1a1a1a] text-neutral-100" if mode == "login"
                        else "border-neutral-700 text-neutral-500 hover:text-neutral-300"
                    )}
                >SIGN IN</button>
                <button
                    onClick={lambda (e: MouseEvent) { onMode("signup"); }}
                    className={"rounded-md border px-3 py-1 text-xs transition-colors " + (
                        "border-neutral-500 bg-[#1a1a1a] text-neutral-100" if mode == "signup"
                        else "border-neutral-700 text-neutral-500 hover:text-neutral-300"
                    )}
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
                    />
                </Field>
                <Field label="PASSWORD">
                    <input
                        type="password"
                        value={password}
                        onChange={lambda (e: ChangeEvent) { password = e.target.value; }}
                        placeholder="password"
                        className={inputCls}
                        onKeyDown={lambda (e: KeyboardEvent) {
                            if e.key == "Enter" { submit(); }
                        }}
                    />
                </Field>
            </div>

            {error and <p className="mt-3 font-mono text-xs text-red-400">{error}</p>}

            <button
                onClick={lambda (e: MouseEvent) { submit(); }}
                disabled={busy}
                className={"mt-5 w-full rounded-md px-3 py-2 text-sm transition-colors " + (
                    "bg-neutral-700 text-neutral-300" if busy
                    else "bg-neutral-100 text-neutral-900 hover:bg-white"
                )}
            >
                {_submitLabel(busy, mode)}
            </button>
        </div>
    </div>;
}
