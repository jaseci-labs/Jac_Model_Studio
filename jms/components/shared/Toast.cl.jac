"""Toast.cl.jac — the app-wide notification surface + its publish API.

Two exports:
  * `pushToast(kind, title, body)` — callable from ANY component, at any depth,
    with no prop wiring. `kind` is "info" | "success" | "error".
  * `<ToastHost/>` — mount ONCE per shell (AppShell / JmsShell); renders the
    stack bottom-right.

Transport is a window CustomEvent with a single-slot handoff
(`window.__jmsToastMsg`) rather than a `detail` payload, because the one proven
`new(...)` form in this codebase is the 2-arg `new(CustomEvent, NAME)` in
auth_session.cl.jac. `dispatchEvent` is SYNCHRONOUS, so the host's listener has
always drained the slot before `pushToast` returns — no lost message.

Why the live list lives in a `useRef`, not a `has`:
the window listener is registered ONCE (deps `[]`, matching removeEventListener
in the cleanup). A listener that appended to a `has` list would read that list's
FIRST-RENDER value forever — the repo's #1 bug class. Instead the listener
mutates `listRef.current` (a real value, never stale) and then WRITES a `has`
field (`ver`) purely to force a re-render. `ver` is only ever assigned a fresh
`Date.now()`, never read-then-incremented, so there is no stale read anywhere.

Auto-dismiss is a single `setTimeout` armed for the NEAREST expiry (re-armed by
the `[ver]` effect after every change) — not a permanent interval. With an empty
stack no timer exists at all.

# ponytail: two toasts published inside ONE synchronous tick both land (the slot
is drained synchronously), but a burst is capped at MAX_TOASTS=4 — the oldest
are dropped rather than scrolled. Toasts here are user-action and
job-completion driven, never bursty.
"""

import from react { useEffect, useRef }

glob TOAST_EVENT: str = "jms:toast";
glob MAX_TOASTS: int = 4;

"""Accent for a toast kind — tokens only, never a literal colour."""
def _kindColor(k: str) -> str {
    if k == "success" { return "var(--ok)"; }
    if k == "error" { return "var(--danger)"; }
    return "var(--accent)";
}

"""Publish a toast. Safe to call before <ToastHost/> mounts (the message is
simply dropped — nothing is listening yet)."""
def:pub pushToast(kind: str, title: str, body: str) -> None {
    try {
        w: any = window;
        w.__jmsToastMsg = {
            "tid": str(Date.now()) + "-" + str(Math.round(Math.random() * 1000000.0)),
            "kind": kind,
            "title": title,
            "body": body
        };
        w.dispatchEvent(new(CustomEvent, TOAST_EVENT));  # jac:ignore[E1053]
    } except Exception { }
}

def:pub ToastHost() -> JsxElement {
    has ver: float = 0.0;

    listRef: any = useRef([]);

    """Force a repaint of the ref-held stack. Never reads `ver`."""
    def bump -> None {
        ver = Date.now() + Math.random();
    }

    def prune -> None {
        now: float = Date.now();
        cur: list = list(listRef.current);
        keep: list = [];
        for t in cur {
            if float(str(t["expires"])) > now { keep.append(t); }
        }
        listRef.current = keep;
        bump();
    }

    def dismiss(tid: str) -> None {
        cur: list = list(listRef.current);
        keep: list = [];
        for t in cur {
            if str(t["tid"]) != tid { keep.append(t); }
        }
        listRef.current = keep;
        bump();
    }

    # Inbox. Registered once; the matching removeEventListener is in the cleanup.
    useEffect(lambda {
        w: any = window;
        onEvt = lambda(_e: any) {
            m: any = w.__jmsToastMsg;
            if not m { return; }
            w.__jmsToastMsg = None;
            kind: str = str(m["kind"]);
            ttl: float = 9000.0 if kind == "error" else 4500.0;
            cur: list = list(listRef.current);
            cur.append({
                "tid": str(m["tid"]),
                "kind": kind,
                "title": str(m["title"]),
                "body": str(m["body"]),
                "expires": Date.now() + ttl
            });
            if len(cur) > MAX_TOASTS { cur = cur[len(cur) - MAX_TOASTS:]; }
            listRef.current = cur;
            bump();
        };
        w.addEventListener(TOAST_EVENT, onEvt);
        return lambda { w.removeEventListener(TOAST_EVENT, onEvt); };
    }, []);

    # Auto-dismiss, re-armed on every change. Timeout id is effect-LOCAL.
    useEffect(lambda {
        cur: list = list(listRef.current);
        if len(cur) == 0 { return lambda { }; }
        soonest: float = 0.0;
        for t in cur {
            e: float = float(str(t["expires"]));
            if soonest == 0.0 or e < soonest { soonest = e; }
        }
        delay: float = soonest - Date.now();
        if delay < 120.0 { delay = 120.0; }
        tid: any = setTimeout(lambda { prune(); }, delay);
        return lambda { clearTimeout(float(str(tid))); };
    }, [ver]);

    toasts: list = list(listRef.current);
    if len(toasts) == 0 { return <></>; }

    return <div
        className="pointer-events-none fixed bottom-4 right-4 z-[70] flex flex-col gap-2"
        style={{"width": "min(360px, 90vw)"}}
        role="status"
        aria-live="polite"
    >
        {for t in toasts {
            tid = str(t["tid"]);
            kind = str(t["kind"]);
            col = _kindColor(kind);
            body = str(t["body"]);
            <div
                key={tid}
                className="exp-panel g-overlay reveal-scale pointer-events-auto flex items-start gap-3"
                style={{"padding": "12px 14px", "borderColor": col}}
            >
                <span
                    className="mt-[5px] h-1.5 w-1.5 shrink-0 rounded-full"
                    style={{"background": col}}
                />
                <div className="flex min-w-0 flex-1 flex-col gap-1">
                    <span
                        className="font-mono text-[11px] tracking-[0.12em] break-words"
                        style={{"color": col}}
                    >{str(t["title"])}</span>
                    {body and <span className="jms-mono-dim break-words">{body}</span>}
                </div>
                <button
                    className="exp-btn exp-btn-ghost shrink-0"
                    aria-label="dismiss notification"
                    title="dismiss"
                    onClick={lambda e: MouseEvent { dismiss(tid); }}
                >✕</button>
            </div>
        }}
    </div>;
}
