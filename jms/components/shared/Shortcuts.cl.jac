"""Shortcuts.cl.jac — the keyboard layer's shared pieces.

Exports:
  * `isTypingTarget(e)` — the guard EVERY global key handler must call first.
    True when the event originated in an <input>/<textarea>/<select> or anything
    contentEditable, i.e. when the user is typing and the key is theirs, not ours.
  * `toggleTheme()` — flips light/dark. It CLICKS the existing <ThemeSwitcher/>
    button when one is on screen instead of flipping the class directly, because
    ThemeSwitcher keeps its own `has mode` for its ◐ DARK / ◑ LIGHT label; a
    direct class flip would leave that label lying. Falls back to the class +
    localStorage flip when no switcher is mounted.
  * `<ShortcutSheet open onClose/>` — the `?` overlay listing every binding.

Dialog semantics follow ApiKeyModal.cl.jac: role="dialog" aria-modal="true",
Escape closes via a document keydown that IS removed in the effect cleanup,
focus moves onto the card on open and is restored to the previous element on
close.
# ponytail: no focus trap (same ceiling as ApiKeyModal) — Tab can still walk out
to the page behind. Escape + initial focus + restore is the floor.
"""

import from react { useEffect }

"""One row per binding. `keys` is rendered as chips split on ' '."""
def:pub shortcutRows() -> list {
    return [
        {"keys": "⌘K", "alt": "Ctrl K", "what": "Command palette — jump anywhere"},
        {"keys": "?", "alt": "", "what": "This shortcut sheet"},
        {"keys": "g h", "alt": "", "what": "Go to the hub (home)"},
        {"keys": "1 … 6", "alt": "", "what": "Switch to the Nth workspace"},
        {"keys": "[", "alt": "", "what": "Previous section (JMS: previous workspace)"},
        {"keys": "]", "alt": "", "what": "Next section (JMS: next workspace)"},
        {"keys": "t", "alt": "", "what": "Toggle light / dark"},
        {"keys": "Esc", "alt": "", "what": "Close the palette, this sheet or a dialog"}
    ];
}

"""True when the key belongs to whatever the user is typing into."""
def:pub isTypingTarget(e: any) -> bool {
    t: any = e.target;
    if not t { return False; }
    tag: str = "";
    try { tag = str(t.tagName).upper(); } except Exception { tag = ""; }
    if tag == "INPUT" or tag == "TEXTAREA" or tag == "SELECT" { return True; }
    if t.isContentEditable { return True; }
    return False;
}

"""Flip light/dark, keeping <ThemeSwitcher/>'s own label honest (see docstring)."""
def:pub toggleTheme() -> None {
    doc: any = document;
    win: any = window;
    btn: any = None;
    try { btn = doc.querySelector("button[title='toggle light / dark']"); } except Exception { btn = None; }
    if btn {
        btn.click();
        return;
    }
    mode: str = "dark";
    try {
        saved: any = win.localStorage.getItem("jacml.mode");
        if saved { mode = str(saved); }
    } except Exception { }
    nextMode: str = "light" if mode == "dark" else "dark";
    if nextMode == "dark" { doc.documentElement.classList.add("dark"); }
    else { doc.documentElement.classList.remove("dark"); }
    try { win.localStorage.setItem("jacml.mode", nextMode); } except Exception { }
}

def:pub ShortcutSheet(open: bool = False, onClose: any = None) -> JsxElement {
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
        panel: any = doc.getElementById("jms-shortcuts-dialog");
        if panel { panel.focus(); }
        return lambda {
            doc.removeEventListener("keydown", onKey);
            if prev { prev.focus(); }
        };
    }, [open]);

    if not open { return <></>; }

    return <div className="fixed inset-0 z-[60] flex items-center justify-center">
        <div
            className="absolute inset-0 g-scrim reveal-fade"
            onClick={lambda e: MouseEvent { _close(); }}
        />
        <div
            id="jms-shortcuts-dialog"
            role="dialog"
            aria-modal="true"
            aria-label="Keyboard shortcuts"
            tabIndex={-1}
            className="exp-panel g-overlay reveal-scale relative flex flex-col gap-4"
            style={{"width": "min(520px, 92vw)", "padding": "22px", "zIndex": "1"}}
        >
            <div className="flex items-center justify-between">
                <span className="micro-label">KEYBOARD SHORTCUTS</span>
                <button
                    className="exp-btn exp-btn-ghost"
                    onClick={lambda e: MouseEvent { _close(); }}
                >CLOSE</button>
            </div>

            <div className="flex flex-col gap-1">
                {for row in shortcutRows() {
                    kx = str(row["keys"]);
                    ax = str(row["alt"]);
                    <div
                        key={kx}
                        className="flex items-center justify-between gap-4 py-1.5"
                        style={{"borderBottom": "1px solid var(--border-alt)"}}
                    >
                        <span
                            className="text-[12px]"
                            style={{"color": "var(--text)"}}
                        >{str(row["what"])}</span>
                        <span className="flex shrink-0 items-center gap-1.5">
                            <span className="exp-chip">{kx}</span>
                            {ax and <span className="exp-chip">{ax}</span>}
                        </span>
                    </div>
                }}
            </div>

            <span className="jms-mono-dim">
                Shortcuts are ignored while you are typing in a field. Press ? again or Esc to close.
            </span>
        </div>
    </div>;
}
