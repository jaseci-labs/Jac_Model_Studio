"""CommandPalette.cl.jac — the ⌘K / Ctrl-K launcher.

Deliberately DUMB: it knows nothing about workspaces, sections, projects or
surfaces. The mounting shell hands it a flat `actions` list of
`{"id","group","label","hint"}` dicts, already in the order it wants them
displayed, and gets back `onRun(id)`. AppShell and JmsShell therefore publish
completely different menus through the same widget, and every navigation stays
in the shell that owns the state.

Matching: case-insensitive substring first, then a subsequence ("wsdpo" finds
"04 CPT-SFT/DPO") fallback, over `label + " " + group`.
# ponytail: NO relevance ranking. Results keep the caller's source order, which
is what keeps each category's rows contiguous under one header. Ranking and
grouping fight each other; grouping is the stated requirement.

Dialog semantics follow ApiKeyModal.cl.jac: role="dialog" aria-modal="true",
Escape (both via the container's onKeyDown and a document listener that IS
removed in the cleanup, so a scrim click that moved focus to <body> can still
Esc out), focus moved onto the search input on open and RESTORED to whatever was
focused before on close.
# ponytail: no focus trap — same ceiling as ApiKeyModal.

Mouse parity: hovering a row moves the selection, mousedown runs it.
"""

import from react { useEffect }

"""Substring hit, else subsequence hit, else False."""
def _matches(hay: str, needle: str) -> bool {
    h: str = hay.lower();
    n: str = needle.lower();
    if not n { return True; }
    if h.find(n) >= 0 { return True; }
    pos: int = 0;
    for ch in n {
        if ch == " " { continue; }
        found: int = -1;
        j: int = pos;
        while j < len(h) {
            if h[j] == ch { found = j; break; }
            j += 1;
        }
        if found < 0 { return False; }
        pos = found + 1;
    }
    return True;
}

def _filter(actions: list, q: str) -> list {
    needle: str = q.strip();
    out: list = [];
    for a in actions {
        if _matches(str(a["label"]) + " " + str(a["group"]), needle) { out.append(a); }
    }
    return out;
}

"""Attach a flat index + a group header (empty when it repeats the row above),
so the JSX pass needs neither an index counter nor nested loops."""
def _rows(items: list) -> list {
    out: list = [];
    i: int = 0;
    lastGroup: str = "";
    for a in items {
        g: str = str(a["group"]);
        out.append({
            "idx": i,
            "head": g if g != lastGroup else "",
            "aid": str(a["id"]),
            "label": str(a["label"]),
            "hint": str(a["hint"]) if "hint" in a else ""
        });
        lastGroup = g;
        i += 1;
    }
    return out;
}

def:pub CommandPalette(
    open: bool = False, actions: list = [],
    onRun: any = None, onClose: any = None
) -> JsxElement {
    has query: str = "",
        cursor: int = 0;

    def _close -> None {
        if onClose is not None { onClose(); }
    }

    useEffect(lambda {
        if not open { return lambda { }; }
        query = "";
        cursor = 0;
        doc: any = document;
        prev: any = doc.activeElement;
        onKey = lambda(e: any) {
            if str(e.key) == "Escape" { _close(); }
        };
        doc.addEventListener("keydown", onKey);
        el: any = doc.getElementById("jms-cmdk-input");
        if el { el.focus(); }
        return lambda {
            doc.removeEventListener("keydown", onKey);
            if prev { prev.focus(); }
        };
    }, [open]);

    if not open { return <></>; }

    filtered: list = _filter(actions, query);
    rows: list = _rows(filtered);
    total: int = len(filtered);
    sel: int = cursor;
    if sel >= total or sel < 0 { sel = 0; }

    def runAt(i: int) -> None {
        if i < 0 or i >= len(filtered) { return; }
        picked: any = filtered[i];
        _close();
        if onRun is not None { onRun(str(picked["id"])); }
    }

    def handleKey(e: any) -> None {
        k: str = str(e.key);
        if k == "ArrowDown" {
            e.preventDefault();
            cursor = ((sel + 1) % total) if total > 0 else 0;
        } elif k == "ArrowUp" {
            e.preventDefault();
            cursor = ((sel - 1 + total) % total) if total > 0 else 0;
        } elif k == "Enter" {
            e.preventDefault();
            runAt(sel);
        } elif k == "Escape" {
            e.preventDefault();
            _close();
        }
    }

    return <div className="fixed inset-0 z-[60] flex items-start justify-center" style={{"paddingTop": "12vh"}}>
        <div
            className="absolute inset-0 g-scrim reveal-fade"
            onClick={lambda e: MouseEvent { _close(); }}
        />
        <div
            id="jms-cmdk-dialog"
            role="dialog"
            aria-modal="true"
            aria-label="Command palette"
            className="exp-panel g-overlay reveal-scale relative flex flex-col gap-3"
            style={{"width": "min(620px, 94vw)", "padding": "16px", "zIndex": "1"}}
            onKeyDown={handleKey}
        >
            <input
                id="jms-cmdk-input"
                className="exp-input"
                type="text"
                value={query}
                role="combobox"
                aria-expanded={True}
                aria-controls="jms-cmdk-list"
                aria-activedescendant={"jms-cmdk-row-" + str(sel)}
                aria-label="Search commands"
                autoComplete="off"
                placeholder="Jump to a workspace, section, project or setting…"
                onChange={lambda e: any { query = str(e.target.value); cursor = 0; }}
            />

            <div
                id="jms-cmdk-list"
                role="listbox"
                aria-label="Commands"
                className="flex flex-col gap-0.5 overflow-y-auto"
                style={{"maxHeight": "50vh"}}
            >
                {for r in rows {
                    ridx = int(str(r["idx"]));
                    head = str(r["head"]);
                    hint = str(r["hint"]);
                    active = ridx == sel;
                    <div key={"row-" + str(ridx)} className="flex flex-col">
                        {head and <span className="micro-label px-2 pt-3 pb-1">{head}</span>}
                        <div
                            id={"jms-cmdk-row-" + str(ridx)}
                            role="option"
                            aria-selected={active}
                            className="flex cursor-pointer items-center justify-between gap-3 rounded-lg px-3 py-2"
                            style={{"background": ("var(--accent-tint)" if active else "transparent")}}
                            onMouseEnter={lambda e: MouseEvent { cursor = ridx; }}
                            onMouseDown={lambda e: MouseEvent { e.preventDefault(); runAt(ridx); }}
                        >
                            <span
                                className="min-w-0 truncate text-[12px]"
                                style={{"color": ("var(--accent)" if active else "var(--text)")}}
                            >{str(r["label"])}</span>
                            {hint and <span className="exp-chip shrink-0">{hint}</span>}
                        </div>
                    </div>
                }}
                {total == 0 and <span className="jms-mono-dim px-3 py-4">No matches for “{query}”.</span>}
            </div>

            <div className="flex items-center justify-between pt-1" style={{"borderTop": "1px solid var(--border-alt)"}}>
                <span className="jms-mono-dim pt-2">↑ ↓ move · ↵ run · esc close</span>
                <span className="jms-mono-dim pt-2">{str(total) + " result" + ("" if total == 1 else "s")}</span>
            </div>
        </div>
    </div>;
}
