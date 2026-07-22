"""ApiKeyModal — the JMS provider-key overlay (Anthropic API key).

A centered card over a click-to-dismiss scrim. Shows the current credential
status from llm_status (configured / source user|env|none + a masked tail — never
the raw key), a password input to set a new key, and SET / CLEAR / CLOSE. The key
is stored server-side encrypted (jms_llm) and never round-trips back to the
client. Triggered by the ⚙ gear in the JmsShell topbar; `onClose` unmounts it.

Handlers are named applyKey / clearKey / reload — never set<HasVar> (that would
shadow the auto-useState setter for a `has` field)."""

sv import from ...jms_llm { llm_status, set_anthropic_key, clear_anthropic_key }

def:pub ApiKeyModal(open: bool = False, onClose: any = None) -> JsxElement {
    has status: any = None,
        keyInput: str = "",
        busy: bool = False,
        err: str = "";

    async def reload -> None {
        try { status = await llm_status(); } except Exception { status = None; }
    }

    async can with entry {
        await reload();
    }

    async def applyKey -> None {
        if not keyInput.strip() { err = "enter a key first"; return; }
        busy = True;
        err = "";
        res: any = None;
        try {
            res = await set_anthropic_key(keyInput.strip());
        } except Exception {
            err = "save failed";
            busy = False;
            return;
        }
        if res and not res["ok"] {
            err = str(res["error"]);
        } else {
            keyInput = "";
        }
        busy = False;
        await reload();
    }

    async def clearKey -> None {
        busy = True;
        err = "";
        try { await clear_anthropic_key(); } except Exception { }
        keyInput = "";
        busy = False;
        await reload();
    }

    def _close -> None {
        if onClose is not None { onClose(); }
    }

    if not open { return <></>; }

    configured: bool = bool(status and status["configured"]);
    source: str = str(status["source"]) if status else "none";
    masked: str = str(status["masked"]) if status else "";

    statusLine: str = "No key configured — Claude models are unavailable until you set one.";
    if configured and source == "user" {
        statusLine = "User key set " + (masked if masked else "") + " · stored encrypted, never shown.";
    }
    if configured and source == "env" {
        statusLine = "Using the ANTHROPIC_API_KEY environment key (shared).";
    }

    return <div
        className="fixed inset-0 z-50 flex items-center justify-center"
        style={{"background": "rgba(0,0,0,0.55)"}}
    >
        <div
            className="absolute inset-0"
            onClick={lambda e: MouseEvent { _close(); }}
        />
        <div
            className="jms-card relative flex flex-col gap-4"
            style={{"width": "min(460px, 92vw)", "padding": "22px", "zIndex": "1"}}
        >
            <div className="flex items-center justify-between">
                <span className="jms-label">ANTHROPIC API KEY</span>
                <span className={"jms-chip"} style={{"color": ("var(--jms-ok)" if configured else "var(--jms-fg-dim)")}}>
                    {"CONFIGURED" if configured else "NOT SET"}
                </span>
            </div>

            <span className="jms-mono-dim">{statusLine}</span>

            <input
                className="jms-input"
                type="password"
                value={keyInput}
                placeholder="sk-ant-…"
                onChange={lambda e: any { keyInput = str(e.target.value); err = ""; }}
            />

            {err and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{err}</span>}

            <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                    <button
                        className="jms-btn jms-btn-accent"
                        disabled={busy}
                        onClick={lambda e: MouseEvent { applyKey(); }}
                    >{"SAVING…" if busy else "SET"}</button>
                    <button
                        className="jms-btn jms-btn-danger"
                        disabled={busy or (source != "user")}
                        onClick={lambda e: MouseEvent { clearKey(); }}
                    >CLEAR</button>
                </div>
                <button
                    className="jms-btn"
                    onClick={lambda e: MouseEvent { _close(); }}
                >CLOSE</button>
            </div>

            <span className="jms-mono-dim" style={{"opacity": "0.7"}}>
                The key is sent once, encrypted at rest, and used only to draft dataset plans on your behalf.
            </span>
        </div>
    </div>;
}
