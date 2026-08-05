"""Workspace management drawer — CRUD for workspaces and sections on the graph.

Dialog semantics: `role="dialog" aria-modal="true"`, Escape closes (document
keydown, removed in the effect cleanup), focus moves onto the drawer on open and
returns to the ⚙ WORKSPACES trigger on close. Tab / Shift-Tab are trapped inside
the drawer by hooks/useFocusTrap (the drawer is `aria-modal`, so the page behind
it is inert scenery — focus has no business going there).

Selection: the drawer opens with a workspace ALREADY selected (see `_activeWs`
and `_resolveWs`). It used to open with `selected == ""`, which hid the entire
editor — LABEL/ACCENT/MODEL/FILES/SAVE/↑/↓/DELETE and every section editor live
inside `{if wd {...}}` / the `secList` loop, so an empty selection rendered a
drawer that looked like it had no edit, reorder or delete features at all."""

import from react { useEffect, useRef }
sv import from ..workspace {
    ui_layout, section_types,
    create_workspace, update_workspace, delete_workspace, reorder_workspaces,
    add_section, update_section, delete_section, reorder_sections
}
sv import from ..models { list_models, ModelView }
import from .shared.Field { Field, TextInput }
import from ..hooks.useConfirmReset { useConfirmReset }
import from ..hooks.useFocusTrap { useFocusTrap }

def _wsById(layout: any, wid: str) -> dict | None {
    for ws in list(layout["workspaces"]) {
        wd = ws as dict;
        if str(wd["id"]) == wid { return wd; }
    }
    return None;
}

# The workspace the Experiments shell is currently showing. AppShell persists it
# to localStorage on every switch (AppShell.cl.jac:165) and cold-starts from
# `layout.default_workspace` (AppShell.cl.jac:139), so reading the same key
# reproduces AppShell's own resolution order.
# ponytail: mirrors AppShell's localStorage key instead of taking a new
# `activeWorkspace` prop (the caller is off-limits here). Ceiling: if AppShell
# ever changes workspace WITHOUT writing localStorage, the drawer opens on the
# last persisted one — still a valid workspace, never an empty selection.
def _activeWs -> str {
    w: any = window;
    if not w { return ""; }
    ls: any = w.localStorage;
    if not ls { return ""; }
    v: any = ls.getItem("jacml.workspace");
    return str(v) if v else "";
}

# `want` if it still exists, else the layout default, else the first workspace,
# else "" (only reachable with an empty workspace list).
def _resolveWs(layout: any, want: str) -> str {
    if not layout { return ""; }
    if want and _wsById(layout, want) { return want; }
    dv: any = layout["default_workspace"];
    dw = str(dv) if dv else "";
    if dw and _wsById(layout, dw) { return dw; }
    ids = list(layout["workspace_ids"]);
    return str(ids[0]) if len(ids) > 0 else "";
}

def _filesToStr(files: list) -> str {
    out: list[str] = [];
    for f in files { out.append(str(f)); }
    return ", ".join(out);
}

def _filesFromStr(raw: str) -> list[str] {
    out: list[str] = [];
    for part in raw.split(",") {
        t = part.strip();
        if t { out.append(t); }
    }
    return out;
}

def:pub WorkspaceSettings(
    open: bool, layout: any, onClose: Callable[[], None],
    onChanged: Callable[[any], None], activeWorkspace: str = ""
) -> JsxElement {
    has selected: str = "",
        label: str = "",
        accent: str = "",
        defaultModel: str = "",
        filesStr: str = "",
        newWsLabel: str = "",
        newSecSid: str = "",
        newSecLabel: str = "",
        newSecComponent: str = "Chat",
        secEdits: dict = {},
        models: list[ModelView] = [],
        secTypes: list[dict] = [],
        confirmWs: bool = False,
        confirmSec: str = "",
        flash: str = "",
        err: str = "",
        busy: bool = False;

    panelRef: any = useRef(None);

    def secLabel(sid: str, fallback: str) -> str {
        if sid in secEdits {
            d = secEdits[sid] as dict;
            return str(d["label"]);
        }
        return fallback;
    }

    def secComponent(sid: str, fallback: str) -> str {
        if sid in secEdits {
            d = secEdits[sid] as dict;
            return str(d["component"]);
        }
        return fallback;
    }

    def setSecLabel(sid: str, v: str) -> None {
        cur = secEdits[sid] as dict if sid in secEdits else {"label": "", "component": "Chat"};
        secEdits = {**secEdits, sid: {**cur, "label": v}};
    }

    def setSecComponent(sid: str, v: str) -> None {
        cur = secEdits[sid] as dict if sid in secEdits else {"label": "", "component": "Chat"};
        secEdits = {**secEdits, sid: {**cur, "component": v}};
    }

    # Load the editor fields from `wid` in `ly`. Takes the id EXPLICITLY — it is
    # called right after `selected = ...`, and re-reading the `has` var there
    # would read the pre-set render value.
    def syncForm(ly: any, wid: str) -> None {
        wd = _wsById(ly, wid) if ly else None;
        if not wd {
            label = "";
            accent = "";
            defaultModel = "";
            filesStr = "";
            secEdits = {};
            return;
        }
        label = str(wd["label"]);
        accent = str(wd["accent"]);
        defaultModel = str(wd["default_model"]);
        filesStr = _filesToStr(list(wd["files"]));
        nd: dict = {};
        for sec in list(wd["sections"]) {
            sd = sec as dict;
            sid = str(sd["id"]);
            nd[sid] = {"label": str(sd["label"]), "component": str(sd["component"])};
        }
        secEdits = nd;
    }

    # Refetch, publish upward, re-resolve the selection, resync the form.
    # RETURNS the resolved id so callers never have to read `selected` back.
    async def reloadLayout(prefer: str) -> str {
        ly: any = None;
        try {
            ly = await ui_layout();
        } except Exception as e {
            err = "Could not reload workspaces: " + str(e);
            return "";
        }
        onChanged(ly);
        nxt = _resolveWs(ly, prefer);
        selected = nxt;
        syncForm(ly, nxt);
        return nxt;
    }

    async can with [open] entry {
        # Everything (models, section types, AND the default selection) is loaded
        # here, not in a mount effect: the drawer is mounted by AppShell with
        # open=False, so a `with entry` body guarded by `if not open` never runs.
        confirmWs = False;
        confirmSec = "";
        if not open { return; }
        flash = "";
        err = "";
        try {
            ms = await list_models();
            models = ms;
            st = await section_types();
            secTypes = st;
            if len(st) > 0 {
                newSecComponent = str((st[0] as dict)["component"]);
            }
        } except Exception as e {
            err = "Could not load models / section types: " + str(e);
        }
        # AppShell now passes the live active workspace; _activeWs() stays as the
        # fallback for any caller that doesn't (the prop is a trailing optional).
        await reloadLayout(activeWorkspace if activeWorkspace else _activeWs());
    }

    async can with [selected] entry {
        confirmWs = False;
        confirmSec = "";
        if layout { syncForm(layout, selected); }
    }

    async def saveWorkspace -> None {
        if not selected or busy { return; }
        busy = True;
        flash = "";
        err = "";
        try {
            await update_workspace(
                selected, label, accent, defaultModel, _filesFromStr(filesStr)
            );
            await reloadLayout(selected);
            flash = "SAVED ✓";
        } except Exception as e {
            err = "Save failed: " + str(e);
        } finally {
            busy = False;
        }
    }

    async def addWorkspace -> None {
        if busy or not newWsLabel.strip() { return; }
        busy = True;
        flash = "";
        err = "";
        try {
            w = await create_workspace(newWsLabel.strip(), "", defaultModel, []);
            newWsLabel = "";
            await reloadLayout(str(w.id));
            flash = "WORKSPACE CREATED ✓";
        } except Exception as e {
            err = "Create failed: " + str(e);
        } finally {
            busy = False;
        }
    }

    async def removeWorkspace -> None {
        if not selected or busy { return; }
        if not confirmWs { confirmWs = True; return; }
        confirmWs = False;
        busy = True;
        flash = "";
        err = "";
        try {
            ok = await delete_workspace(selected);
            if ok {
                await reloadLayout("");
                flash = "WORKSPACE DELETED ✓";
            } else {
                err = "Cannot delete the last workspace.";
            }
        } except Exception as e {
            err = "Delete failed: " + str(e);
        } finally {
            busy = False;
        }
    }

    async def moveWorkspace(up: bool) -> None {
        if not layout or busy or not selected { return; }
        ids: list[str] = [];
        for x in list(layout["workspace_ids"]) { ids.append(str(x)); }
        idx = -1;
        for i in range(len(ids)) {
            if ids[i] == selected { idx = i; break; }
        }
        if idx < 0 { return; }
        j = idx - 1 if up else idx + 1;
        if j < 0 or j >= len(ids) {
            err = "Already at the " + ("top." if up else "bottom.");
            return;
        }
        tmp = ids[idx];
        ids[idx] = ids[j];
        ids[j] = tmp;
        busy = True;
        flash = "";
        err = "";
        try {
            await reorder_workspaces(ids);
            await reloadLayout(selected);
            flash = "REORDERED ✓";
        } except Exception as e {
            err = "Reorder failed: " + str(e);
        } finally {
            busy = False;
        }
    }

    async def saveSection(sid: str) -> None {
        if not selected or busy { return; }
        busy = True;
        flash = "";
        err = "";
        try {
            await update_section(
                selected, sid, secLabel(sid, ""), secComponent(sid, "Chat")
            );
            await reloadLayout(selected);
            flash = "SECTION " + sid.upper() + " SAVED ✓";
        } except Exception as e {
            err = "Section save failed: " + str(e);
        } finally {
            busy = False;
        }
    }

    async def removeSection(sid: str) -> None {
        if not selected or busy { return; }
        if confirmSec != sid { confirmSec = sid; return; }
        confirmSec = "";
        busy = True;
        flash = "";
        err = "";
        try {
            ok = await delete_section(selected, sid);
            await reloadLayout(selected);
            if ok { flash = "SECTION " + sid.upper() + " DELETED ✓"; }
            else { err = "Cannot delete the last section."; }
        } except Exception as e {
            err = "Section delete failed: " + str(e);
        } finally {
            busy = False;
        }
    }

    async def moveSection(sid: str, up: bool) -> None {
        wd = _wsById(layout, selected) if layout else None;
        if not wd or busy { return; }
        ids: list[str] = [];
        for sec in list(wd["sections"]) {
            ids.append(str((sec as dict)["id"]));
        }
        idx = -1;
        for i in range(len(ids)) {
            if ids[i] == sid { idx = i; break; }
        }
        if idx < 0 { return; }
        j = idx - 1 if up else idx + 1;
        if j < 0 or j >= len(ids) {
            err = "Section is already at the " + ("top." if up else "bottom.");
            return;
        }
        tmp = ids[idx];
        ids[idx] = ids[j];
        ids[j] = tmp;
        busy = True;
        flash = "";
        err = "";
        try {
            await reorder_sections(selected, ids);
            await reloadLayout(selected);
            flash = "SECTIONS REORDERED ✓";
        } except Exception as e {
            err = "Section reorder failed: " + str(e);
        } finally {
            busy = False;
        }
    }

    async def createSection -> None {
        if not selected or busy or not newSecSid.strip() { return; }
        busy = True;
        flash = "";
        err = "";
        try {
            lbl = newSecLabel.strip() if newSecLabel.strip() else newSecSid.upper();
            await add_section(selected, newSecSid.strip(), lbl, newSecComponent);
            newSecSid = "";
            newSecLabel = "";
            await reloadLayout(selected);
            flash = "SECTION ADDED ✓";
        } except Exception as e {
            err = "Add section failed: " + str(e);
        } finally {
            busy = False;
        }
    }

    useEffect(lambda {
        if not open { return lambda { }; }
        doc: any = document;
        prev: any = doc.activeElement;
        onKey = lambda(e: any) {
            if str(e.key) == "Escape" { onClose(); }
        };
        doc.addEventListener("keydown", onKey);
        panel: any = panelRef.current;
        if panel { panel.focus(); }
        return lambda {
            doc.removeEventListener("keydown", onKey);
            if prev { prev.focus(); }
        };
    }, [open]);

    # Tab / Shift-Tab now cycle inside the drawer instead of walking out into the
    # page behind it. MUST stay below the effect above: the trap's stand-down /
    # reclaim logic assumes the drawer has already focused itself, and effects
    # run in declaration order. See hooks/useFocusTrap.
    useFocusTrap(panelRef, open);

    # An armed DELETE / ✕ ("SURE?") disarms itself on Escape, on a pointer-down
    # outside the button, or after 4s — see hooks/useConfirmReset. Without it the
    # armed button stayed armed forever and a later stray click deleted a
    # workspace (and every section under it) or a section. Both calls sit ABOVE
    # the early return below: they wrap useEffect and must run every render.
    # `confirmWs` is a bool, so it is passed as the selected id / "" — the hook
    # keys its timer on the string, and "" means nothing is armed.
    useConfirmReset(selected if confirmWs else "", lambda -> None { confirmWs = False; });
    useConfirmReset(confirmSec, lambda -> None { confirmSec = ""; });

    if not open or layout is None { return <></>; }

    wd = _wsById(layout, selected);
    secList: list = list(wd["sections"]) if wd else [];
    wsName = (str(wd["id"]) + " · " + str(wd["label"])) if wd else "";
    dirty = wd is not None and (
        label != str(wd["label"])
        or accent != str(wd["accent"])
        or defaultModel != str(wd["default_model"])
        or filesStr != _filesToStr(list(wd["files"]))
    );

    # Starts BELOW the top bar (--topbar-h, global.css) rather than at inset-0:
    # the panel used to paint over its own ⚙ WORKSPACES trigger, so a second
    # click on the toggle hit the panel header instead and the drawer could only
    # be closed by ✕ / Esc / the scrim. Offsetting the whole overlay — scrim
    # included — is what keeps the trigger both visible and hit-testable; the
    # trade-off is that the bar stays interactive while the drawer is open.
    return <div className="fixed inset-x-0 bottom-0 top-[var(--topbar-h)] z-50 flex">
        <div
            className="flex-1 g-scrim reveal-fade"
            onClick={lambda (e: MouseEvent) { onClose(); }}
        />
        <aside
            id="exp-ws-settings"
            ref={panelRef}
            role="dialog"
            aria-modal="true"
            aria-label="Workspaces and sections"
            tabIndex={-1}
            className="g-overlay reveal-scale flex h-full w-[28rem] shrink-0 flex-col border-l border-border"
        >
            <div className="flex items-center justify-between border-b border-border px-4 py-3">
                <span className="micro-label">WORKSPACES</span>
                <button
                    onClick={lambda (e: MouseEvent) { onClose(); }}
                    className="text-muted-foreground hover:text-foreground"
                >✕</button>
            </div>

            <div className="flex-1 overflow-y-auto px-4 py-3 space-y-4">
                <div className="space-y-1">
                    {for ws in list(layout["workspaces"]) {
                        w = ws as dict;
                        wid = str(w["id"]);
                        on = wid == selected;
                        <button
                            key={wid}
                            aria-pressed={on}
                            onClick={lambda (e: MouseEvent) { selected = wid; }}
                            className={"exp-hoverable flex w-full items-center gap-2 rounded-lg border px-2 py-1.5 text-left font-mono text-[10px] tracking-wider " + (
                                "border-accent bg-accent/20 text-foreground font-semibold shadow-[var(--accent-ring)]" if on
                                else "border-transparent text-muted-foreground hover:bg-popover"
                            )}
                        >
                            <span className="w-2 shrink-0 text-accent">{"▸" if on else ""}</span>
                            <span className="h-2 w-2 shrink-0 rounded-full" style={{"background": "var(--" + str(w["accent"]) + ")"}} />
                            {wid} {str(w["label"])}
                        </button>
                    }}
                </div>

                <div className="dashed-rule" />

                <Field label="NEW WORKSPACE">
                    <div className="flex gap-2">
                        <TextInput value={newWsLabel} onSet={lambda (v: str) { newWsLabel = v; }} placeholder="Label" mono={False} />
                        <button
                            onClick={addWorkspace}
                            disabled={busy or not newWsLabel.strip()}
                            className="exp-btn shrink-0"
                        >ADD</button>
                    </div>
                </Field>

                {if not wd {
                    <p key="wsnone" className="text-xs text-muted-foreground">
                        No workspace selected — pick one above to edit, reorder or delete it.
                    </p>
                }}

                {if wd {
                    <div key="wsedit" className="space-y-3">
                        <div className="flex items-baseline gap-2">
                            <span className="micro-label">EDITING</span>
                            <span className="font-mono text-[11px] tracking-wider text-accent">{wsName}</span>
                        </div>
                        <Field label="LABEL">
                            <TextInput value={label} onSet={lambda (v: str) { label = v; }} placeholder="Workspace label" mono={False} />
                        </Field>
                        <Field label="ACCENT CSS VAR">
                            <TextInput value={accent} onSet={lambda (v: str) { accent = v; }} placeholder="ws01" mono={True} />
                        </Field>
                        <Field label="DEFAULT MODEL">
                            <select
                                value={defaultModel}
                                aria-label="Default model"
                                onChange={lambda (e: ChangeEvent) { defaultModel = e.target.value; }}
                                className="exp-input"
                            >
                                {for m in models {
                                    <option key={m.id} value={m.id}>{m.label}</option>
                                }}
                            </select>
                        </Field>
                        <Field label="FILES (comma-separated)">
                            <TextInput value={filesStr} onSet={lambda (v: str) { filesStr = v; }} placeholder="01-sft-dpo" mono={True} />
                        </Field>
                        <div className="flex gap-2">
                            <button
                                onClick={saveWorkspace}
                                disabled={busy or not dirty}
                                title={"No unsaved changes" if not dirty else "Save this workspace"}
                                className="exp-btn"
                            >{"SAVING…" if busy else ("SAVE" if dirty else "SAVED")}</button>
                            <button onClick={lambda { moveWorkspace(True); }} disabled={busy} aria-label="Move workspace up" className="exp-btn">↑</button>
                            <button onClick={lambda { moveWorkspace(False); }} disabled={busy} aria-label="Move workspace down" className="exp-btn">↓</button>
                            <button
                                onClick={removeWorkspace}
                                disabled={busy}
                                data-confirm-armed={"1" if confirmWs else None}
                                aria-label={("Confirm delete workspace " if confirmWs else "Delete workspace ") + wsName}
                                className={"exp-btn exp-btn-danger" + (" exp-btn-active" if confirmWs else "")}
                            >{"SURE?" if confirmWs else "DELETE"}</button>
                        </div>
                        {if confirmWs {
                            <p key="wsconfirm" className="text-xs text-danger">
                                Deletes workspace {wsName} AND all {str(len(secList))} of its sections. Click SURE? to confirm.
                            </p>
                        }}
                    </div>
                }}

                <div className="dashed-rule" />

                <div className="flex items-baseline gap-2">
                    <span className="micro-label">SECTIONS</span>
                    {if wd {
                        <span key="sechdr" className="font-mono text-[10px] tracking-wider text-muted-foreground">OF {wsName}</span>
                    }}
                </div>
                {for sec in secList {
                    sd = sec as dict;
                    sid = str(sd["id"]);
                    sl = secLabel(sid, str(sd["label"]));
                    sc = secComponent(sid, str(sd["component"]));
                    sDirty = sl != str(sd["label"]) or sc != str(sd["component"]);
                    <div key={sid} className="exp-panel !bg-background p-2 space-y-2">
                        <div className="font-mono text-[10px] text-muted-foreground">{sid}</div>
                        <TextInput value={sl} onSet={lambda (v: str) { setSecLabel(sid, v); }} placeholder="LABEL" mono={False} />
                        <select
                            value={sc}
                            aria-label={"Component for section " + sid}
                            onChange={lambda (e: ChangeEvent) { setSecComponent(sid, e.target.value); }}
                            className="exp-input"
                        >
                            {for st in secTypes {
                                d = st as dict;
                                <option key={str(d["component"])} value={str(d["component"])}>{str(d["label"])}</option>
                            }}
                        </select>
                        <div className="flex gap-1">
                            <button
                                onClick={lambda { saveSection(sid); }}
                                disabled={busy or not sDirty}
                                className="exp-btn"
                            >{"SAVE" if sDirty else "SAVED"}</button>
                            <button onClick={lambda { moveSection(sid, True); }} disabled={busy} aria-label={"Move section " + sid + " up"} className="exp-btn exp-btn-ghost">↑</button>
                            <button onClick={lambda { moveSection(sid, False); }} disabled={busy} aria-label={"Move section " + sid + " down"} className="exp-btn exp-btn-ghost">↓</button>
                            <button
                                onClick={lambda { removeSection(sid); }}
                                disabled={busy}
                                data-confirm-armed={"1" if confirmSec == sid else None}
                                aria-label={("Confirm delete section " if confirmSec == sid else "Delete section ") + sid}
                                className={"exp-btn exp-btn-danger" + (" exp-btn-active" if confirmSec == sid else "")}
                            >{"SURE?" if confirmSec == sid else "✕"}</button>
                        </div>
                        {if confirmSec == sid {
                            <p key="secconfirm" className="text-xs text-danger">
                                Deletes section {sid} from {wsName}. Click SURE? to confirm.
                            </p>
                        }}
                    </div>
                }}

                {if wd {
                    <Field key="addsec" label="ADD SECTION">
                        <div className="space-y-2">
                            <TextInput value={newSecSid} onSet={lambda (v: str) { newSecSid = v; }} placeholder="section id" mono={True} />
                            <TextInput value={newSecLabel} onSet={lambda (v: str) { newSecLabel = v; }} placeholder="LABEL (optional)" mono={False} />
                            <select
                                value={newSecComponent}
                                aria-label="Component for the new section"
                                onChange={lambda (e: ChangeEvent) { newSecComponent = e.target.value; }}
                                className="exp-input"
                            >
                                {for st in secTypes {
                                    d = st as dict;
                                    <option key={str(d["component"])} value={str(d["component"])}>{str(d["label"])}</option>
                                }}
                            </select>
                            <button
                                onClick={createSection}
                                disabled={busy or not newSecSid.strip()}
                                className="exp-btn"
                            >ADD SECTION</button>
                        </div>
                    </Field>
                }}
            </div>

            {if err {
                <div key="errbar" role="alert" className="border-t border-border px-4 py-2 text-xs text-danger">{err}</div>
            }}
            {if flash {
                <div key="okbar" role="status" className="border-t border-border px-4 py-2 font-mono text-[10px] tracking-[0.12em] text-ok">{flash}</div>
            }}
        </aside>
    </div>;
}
