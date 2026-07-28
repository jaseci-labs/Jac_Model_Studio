"""JmsWorkspaceSettings — lean workspace CRUD drawer for the JMS top nav.

Mirrors `WorkspaceSettings.cl.jac`'s slide-over shape (dim overlay + right-hand
glass panel, reload-on-mutation pattern) but drops the whole sections half —
a JMS workspace only ever carries `{id,label,accent}` (see jms_workspaces.sv.jac),
so there's nothing else to edit here: a workspace list with inline rename +
two-click delete, and an add-workspace control (label + accent picker over the
fixed `ws01..ws06` swatch set).

Feedback contract is the Experiments twin's: `err` renders in `--jms-danger`,
`flash` in `--jms-ok` (the `.jms-flash` treatment), both in a pinned footer so a
SAVE never looks like it did nothing; every async handler clears `busy` in a
`finally`; DELETE is two-click ("SURE?") and names what it will delete.

Every mutating call (`create/update/delete_jms_workspace`) already returns the
freshly-seeded layout dict, so there's no separate reload round-trip needed —
the response IS the new layout, handed straight up via `onChanged`.

Dialog semantics: `role="dialog" aria-modal="true"`, Escape closes (document
keydown, removed in the effect cleanup), focus moves onto the drawer on open and
returns to the ⚙ WORKSPACES trigger on close.
# ponytail: no focus trap — Tab can still leave the drawer. Escape + initial
focus + restore is the accessible floor without a shared hook module."""

import from react { useEffect }
sv import from ..jms_workspaces { create_jms_workspace, update_jms_workspace, delete_jms_workspace }

glob ACCENTS: list[str] = ["ws01", "ws02", "ws03", "ws04", "ws05", "ws06"];

def _wsById(layout: any, wid: str) -> dict | None {
    for ws in list(layout["workspaces"]) {
        wd = ws as dict;
        if str(wd["id"]) == wid { return wd; }
    }
    return None;
}

def:pub JmsWorkspaceSettings(
    open: bool, layout: any, onClose: any, onChanged: any, workspace: str = ""
) -> JsxElement {
    has editId: str = "",
        editLabel: str = "",
        confirmId: str = "",
        newLabel: str = "",
        newAccent: str = "ws01",
        busy: bool = False,
        flash: str = "",
        err: str = "";

    def startEdit(wid: str, label: str) -> None {
        editId = wid;
        editLabel = label;
        confirmId = "";
        flash = "";
        err = "";
    }

    def cancelEdit -> None {
        editId = "";
        editLabel = "";
    }

    # Reset the two-click-delete arm and any stale banner whenever the drawer is
    # opened or closed, so a half-armed DELETE can never survive a reopen.
    async can with [open] entry {
        confirmId = "";
        editId = "";
        editLabel = "";
        flash = "";
        err = "";
    }

    async def saveRename(wid: str) -> None {
        if busy or not editLabel.strip() { return; }
        busy = True;
        flash = "";
        err = "";
        try {
            wd = _wsById(layout, wid);
            acc = str(wd["accent"]) if wd else "ws01";
            ly = await update_jms_workspace(wid, editLabel.strip(), acc);
            onChanged(ly);
            editId = "";
            editLabel = "";
            flash = "RENAMED ✓";
        } except Exception as e {
            err = "Rename failed: " + str(e);
        } finally {
            busy = False;
        }
    }

    async def removeWs(wid: str) -> None {
        if busy { return; }
        if confirmId != wid { confirmId = wid; return; }
        confirmId = "";
        busy = True;
        flash = "";
        err = "";
        try {
            before = len(list(layout["workspaces"]));
            ly = await delete_jms_workspace(wid);
            after = len(list(ly["workspaces"]));
            onChanged(ly);
            if after < before { flash = "WORKSPACE DELETED ✓"; }
            else { err = "Cannot delete the last workspace."; }
        } except Exception as e {
            err = "Delete failed: " + str(e);
        } finally {
            busy = False;
        }
    }

    async def addWs -> None {
        if busy or not newLabel.strip() { return; }
        busy = True;
        flash = "";
        err = "";
        try {
            ly = await create_jms_workspace(newLabel.strip(), newAccent);
            onChanged(ly);
            newLabel = "";
            flash = "WORKSPACE CREATED ✓";
        } except Exception as e {
            err = "Create failed: " + str(e);
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
        panel: any = doc.getElementById("jms-ws-settings");
        if panel { panel.focus(); }
        return lambda {
            doc.removeEventListener("keydown", onKey);
            if prev { prev.focus(); }
        };
    }, [open]);

    if not open or layout is None { return <></>; }

    wsList: list = list(layout["workspaces"]);

    return <div className="fixed inset-0 z-50 flex">
        <div
            className="flex-1 g-scrim reveal-fade"
            onClick={lambda e: MouseEvent { onClose(); }}
        />
        <aside
            id="jms-ws-settings"
            role="dialog"
            aria-modal="true"
            aria-label="JMS workspaces"
            tabIndex={-1}
            className="jms-card g-overlay reveal-scale !rounded-none flex h-full w-[24rem] shrink-0 flex-col border-l !border-r-0"
        >
            <div className="flex items-center justify-between border-b border-border px-4 py-3">
                <span className="micro-label">WORKSPACES</span>
                <button
                    onClick={lambda e: MouseEvent { onClose(); }}
                    className="text-muted-foreground hover:text-foreground"
                >✕</button>
            </div>

            <div className="flex-1 overflow-y-auto px-4 py-3 space-y-3">
                {for ws in wsList {
                    w = ws as dict;
                    wid = str(w["id"]);
                    label = str(w["label"]);
                    accent = str(w["accent"]);
                    editing = editId == wid;
                    arming = confirmId == wid;
                    isActive = workspace == wid and wid != "";
                    <div
                        key={wid}
                        aria-current={"true" if isActive else None}
                        className={"jms-card p-2 space-y-2" + (
                            " !border-accent bg-accent/10" if editing
                            else (" !border-danger" if arming else "")
                        )}
                    >
                        <div className="flex items-center gap-2">
                            <span className="h-2 w-2 shrink-0 rounded-full" style={{"background": "var(--" + accent + ")"}} />
                            {isActive and <span key="active" className="jms-label" style={{"color": "var(--accent)"}}>ACTIVE</span>}
                            <span className="jms-mono-dim">{wid}</span>
                            {if editing {
                                <span key="ed" className="micro-label text-accent">EDITING {label}</span>;
                                skip;
                            }}
                        </div>
                        {if editing {
                            <div className="flex gap-2">
                                <input
                                    className="jms-input"
                                    value={editLabel}
                                    aria-label={"Rename workspace " + wid}
                                    onChange={lambda e: any { editLabel = str(e.target.value); }}
                                />
                                <button
                                    className="jms-btn jms-btn-accent shrink-0"
                                    disabled={busy or not editLabel.strip() or editLabel.strip() == label}
                                    onClick={lambda e: MouseEvent { saveRename(wid); }}
                                >{"SAVING…" if busy else "SAVE"}</button>
                                <button
                                    className="jms-btn shrink-0"
                                    onClick={lambda e: MouseEvent { cancelEdit(); }}
                                >CANCEL</button>
                            </div>;
                            skip;
                        }}
                        {if not editing {
                            <div className="flex items-center justify-between gap-2">
                                <span className="jms-label">{label}</span>
                                <div className="flex gap-1">
                                    <button
                                        className="jms-btn"
                                        onClick={lambda e: MouseEvent { startEdit(wid, label); }}
                                    >RENAME</button>
                                    <button
                                        className={"jms-btn" + (" jms-btn-danger" if arming else "")}
                                        disabled={busy}
                                        aria-label={("Confirm delete workspace " if arming else "Delete workspace ") + label}
                                        onClick={lambda e: MouseEvent { removeWs(wid); }}
                                    >{"SURE?" if arming else "DELETE"}</button>
                                </div>
                            </div>;
                            skip;
                        }}
                        {if arming {
                            <p key="warn" className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>
                                Deletes “{label}” permanently. Click SURE? to confirm.
                            </p>;
                            skip;
                        }}
                    </div>
                }}

                <div className="dashed-rule" />

                <div className="jms-card p-2 space-y-2">
                    <span className="micro-label">ADD WORKSPACE</span>
                    <input
                        className="jms-input"
                        value={newLabel}
                        aria-label="New workspace label"
                        placeholder="label"
                        onChange={lambda e: any { newLabel = str(e.target.value); }}
                    />
                    <div className="flex gap-1.5">
                        {for a in ACCENTS {
                            <button
                                key={a}
                                onClick={lambda e: MouseEvent { newAccent = a; }}
                                className="h-6 w-6 shrink-0 rounded-full"
                                style={{
                                    "background": "var(--" + a + ")",
                                    "outline": ("2px solid var(--text)" if a == newAccent else "none"),
                                    "outlineOffset": "2px"
                                }}
                                title={a}
                                aria-label={"accent " + a}
                                aria-pressed={a == newAccent}
                            />
                        }}
                    </div>
                    <button
                        className="jms-btn jms-btn-accent"
                        disabled={busy or not newLabel.strip()}
                        onClick={addWs}
                    >{"CREATING…" if busy else "ADD"}</button>
                </div>
            </div>

            {if err {
                <div key="errbar" role="alert" className="border-t border-border px-4 py-2 text-xs" style={{"color": "var(--jms-danger)"}}>{err}</div>
            }}
            {if flash {
                <div key="okbar" role="status" className="jms-flash border-t border-border px-4 py-2">{flash}</div>
            }}
        </aside>
    </div>;
}
