"""ApiKeyModal — the JMS provider-key overlay (Anthropic + OpenAI API keys).

A centered card over a click-to-dismiss scrim. Shows the current credential
status from llm_status (configured / source user|env|none + a masked tail — never
the raw key), a password input to set a new key, and SET / CLEAR / CLOSE. The key
is stored server-side encrypted (jms_llm) and never round-trips back to the
client. Triggered by the ⚙ gear in the JmsShell topbar; `onClose` unmounts it.

A second, mirrored section manages the OpenAI key (assistant.sv.jac's
set_openai_key/clear_openai_key), sourcing its configured/masked status from
assistant_providers()'s "openai" provider entry (Task A5).

Handlers are named applyKey / clearKey / reload (and applyOpenAiKey /
clearOpenAiKey / reloadOpenAi for the OpenAI section) — never set<HasVar>
(that would shadow the auto-useState setter for a `has` field).

Dialog semantics: `role="dialog" aria-modal="true"`, Escape closes (document
keydown, removed in the effect cleanup), focus moves onto the card on open and
returns to whatever was focused before (the ⚙ KEYS button) on close. Tab /
Shift-Tab are trapped inside the card by hooks/useFocusTrap — that shared hook is
what the "no focus trap" note here used to be waiting on."""

import from react { useEffect, useRef }
sv import from ...jms_llm { llm_status, set_anthropic_key, clear_anthropic_key }
sv import from ...assistant { set_openai_key, clear_openai_key, assistant_providers }
import from ...hooks.useFocusTrap { useFocusTrap }

def:pub ApiKeyModal(open: bool = False, onClose: any = None) -> JsxElement {
    has status: any = None,
        keyInput: str = "",
        busy: bool = False,
        err: str = "",
        oaiProviders: any = None,
        oaiKeyInput: str = "",
        oaiBusy: bool = False,
        oaiErr: str = "";

    panelRef: any = useRef(None);

    async def reload -> None {
        try { status = await llm_status(); } except Exception { status = None; }
    }

    async def reloadOpenAi -> None {
        try { oaiProviders = await assistant_providers(); } except Exception { oaiProviders = None; }
    }

    async can with entry {
        await reload();
        await reloadOpenAi();
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

    async def applyOpenAiKey -> None {
        if not oaiKeyInput.strip() { oaiErr = "enter a key first"; return; }
        oaiBusy = True;
        oaiErr = "";
        res: any = None;
        try {
            res = await set_openai_key(oaiKeyInput.strip());
        } except Exception {
            oaiErr = "save failed";
            oaiBusy = False;
            return;
        }
        if res and not res["ok"] {
            oaiErr = str(res["error"]);
        } else {
            oaiKeyInput = "";
        }
        oaiBusy = False;
        await reloadOpenAi();
    }

    async def clearOpenAiKey -> None {
        oaiBusy = True;
        oaiErr = "";
        try { await clear_openai_key(); } except Exception { }
        oaiKeyInput = "";
        oaiBusy = False;
        await reloadOpenAi();
    }

    def _close -> None {
        if onClose is not None { onClose(); }
    }

    useEffect(lambda {
        if not open { return lambda { }; }
        doc: any = document;
        prev: any = doc.activeElement;
        onKey = lambda(e: any) {
            if str(e.key) == "Escape" { _close(); }
        };
        doc.addEventListener("keydown", onKey);
        panel: any = panelRef.current;
        if panel { panel.focus(); }
        return lambda {
            doc.removeEventListener("keydown", onKey);
            if prev { prev.focus(); }
        };
    }, [open]);

    # Tab / Shift-Tab cycle inside the card. MUST stay below the effect above —
    # effects run in declaration order and the trap assumes the card already
    # focused itself. See hooks/useFocusTrap.
    useFocusTrap(panelRef, open);

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

    oaiProvider: any = None;
    if oaiProviders {
        for p in oaiProviders["providers"] {
            if p["id"] == "openai" { oaiProvider = p; break; }
        }
    }
    oaiConfigured: bool = bool(oaiProvider and oaiProvider["configured"]);

    oaiStatusLine: str = "No key configured — OpenAI models are unavailable until you set one.";
    if oaiConfigured {
        oaiStatusLine = "Key configured · stored encrypted, never shown.";
    }

    return <div className="fixed inset-0 z-50 flex items-center justify-center">
        <div
            className="absolute inset-0 g-scrim reveal-fade"
            onClick={lambda e: MouseEvent { _close(); }}
        />
        <div
            id="jms-apikey-dialog"
            ref={panelRef}
            role="dialog"
            aria-modal="true"
            aria-label="Provider API keys"
            tabIndex={-1}
            className="jms-card g-overlay reveal-scale relative flex flex-col gap-4"
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
                aria-label="Anthropic API key"
                autoComplete="off"
                placeholder="sk-ant-…"
                onChange={lambda e: any { keyInput = str(e.target.value); err = ""; }}
            />

            {err and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{err}</span>}

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

            <div style={{"height": "1px", "background": "var(--jms-border)", "opacity": "0.6"}} />

            <div className="flex items-center justify-between">
                <span className="jms-label">OPENAI API KEY</span>
                <span className={"jms-chip"} style={{"color": ("var(--jms-ok)" if oaiConfigured else "var(--jms-fg-dim)")}}>
                    {"CONFIGURED" if oaiConfigured else "NOT SET"}
                </span>
            </div>

            <span className="jms-mono-dim">{oaiStatusLine}</span>

            <input
                className="jms-input"
                type="password"
                value={oaiKeyInput}
                aria-label="OpenAI API key"
                autoComplete="off"
                placeholder="sk-…"
                onChange={lambda e: any { oaiKeyInput = str(e.target.value); oaiErr = ""; }}
            />

            {oaiErr and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{oaiErr}</span>}

            <div className="flex items-center gap-2">
                <button
                    className="jms-btn jms-btn-accent"
                    disabled={oaiBusy}
                    onClick={lambda e: MouseEvent { applyOpenAiKey(); }}
                >{"SAVING…" if oaiBusy else "SET"}</button>
                <button
                    className="jms-btn jms-btn-danger"
                    disabled={oaiBusy or (not oaiConfigured)}
                    onClick={lambda e: MouseEvent { clearOpenAiKey(); }}
                >CLEAR</button>
            </div>

            <div className="flex items-center justify-between">
                <span className="jms-mono-dim" style={{"opacity": "0.7"}}>
                    Keys are sent once, encrypted at rest, and used only to power the app assistant + dataset plans on your behalf.
                </span>
                <button
                    className="jms-btn"
                    onClick={lambda e: MouseEvent { _close(); }}
                >CLOSE</button>
            </div>
        </div>
    </div>;
}
