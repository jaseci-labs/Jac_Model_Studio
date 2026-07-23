"""JmsWorkspaceSettings — lean workspace CRUD drawer for the JMS top nav.

Mirrors `WorkspaceSettings.cl.jac`'s slide-over shape (dim overlay + right-hand
glass panel, reload-on-mutation pattern) but drops the whole sections half —
a JMS workspace only ever carries `{id,label,accent}` (see jms_workspaces.sv.jac),
so there's nothing else to edit here: a workspace list with inline rename +
two-click delete, and an add-workspace control (label + accent picker over the
fixed `ws01..ws06` swatch set).

Every mutating call (`create/update/delete_jms_workspace`) already returns the
freshly-seeded layout dict, so there's no separate reload round-trip needed —
the response IS the new layout, handed straight up via `onChanged`."""

sv import from ..jms_workspaces { create_jms_workspace, update_jms_workspace, delete_jms_workspace }

glob ACCENTS: list[str] = ["ws01", "ws02", "ws03", "ws04", "ws05", "ws06"];

def _wsById(layout: any, wid: str) -> dict | None {
    for ws in list(layout["workspaces"]) {
        wd = ws as dict;
        if str(wd["id"]) == wid { return wd; }
    }
    return None;
}

def:pub JmsWorkspaceSettings(open: bool, layout: any, onClose: any, onChanged: any) -> JsxElement {
    has editId: str = "",
        editLabel: str = "",
        confirmId: str = "",
        newLabel: str = "",
        newAccent: str = "ws01",
        busy: bool = False,
        status: str = "";

    def startEdit(wid: str, label: str) -> None {
        editId = wid;
        editLabel = label;
        confirmId = "";
        status = "";
    }

    def cancelEdit -> None {
        editId = "";
        editLabel = "";
    }

    async def saveRename(wid: str) -> None {
        if busy or not editLabel.strip() { return; }
        busy = True;
        status = "";
        try {
            wd = _wsById(layout, wid);
            acc = str(wd["accent"]) if wd else "ws01";
            ly = await update_jms_workspace(wid, editLabel.strip(), acc);
            onChanged(ly);
            editId = "";
            editLabel = "";
            status = "Renamed.";
        } except Exception as e {
            status = "Rename failed: " + str(e);
        }
        busy = False;
    }

    async def removeWs(wid: str) -> None {
        if confirmId != wid { confirmId = wid; return; }
        if busy { return; }
        confirmId = "";
        busy = True;
        status = "";
        try {
            before = len(list(layout["workspaces"]));
            ly = await delete_jms_workspace(wid);
            after = len(list(ly["workspaces"]));
            onChanged(ly);
            status = "Deleted." if after < before else "Cannot delete the last workspace.";
        } except Exception as e {
            status = "Delete failed: " + str(e);
        }
        busy = False;
    }

    async def addWs -> None {
        if busy or not newLabel.strip() { return; }
        busy = True;
        status = "";
        try {
            ly = await create_jms_workspace(newLabel.strip(), newAccent);
            onChanged(ly);
            newLabel = "";
            status = "Workspace created.";
        } except Exception as e {
            status = "Create failed: " + str(e);
        }
        busy = False;
    }

    if not open or layout is None { return <></>; }

    wsList: list = list(layout["workspaces"]);

    return <div className="fixed inset-0 z-50 flex">
        <div
            className="flex-1 bg-black/60"
            onClick={lambda e: MouseEvent { onClose(); }}
        />
        <aside className="jms-card !rounded-none flex h-full w-[24rem] shrink-0 flex-col border-l !border-r-0">
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
                    <div key={wid} className="jms-card p-2 space-y-2">
                        <div className="flex items-center gap-2">
                            <span className="h-2 w-2 shrink-0 rounded-full" style={{"background": "var(--" + accent + ")"}} />
                            <span className="jms-mono-dim">{wid}</span>
                        </div>
                        {if editId == wid {
                            <div className="flex gap-2">
                                <input
                                    className="jms-input"
                                    value={editLabel}
                                    onChange={lambda e: any { editLabel = str(e.target.value); }}
                                />
                                <button
                                    className="jms-btn jms-btn-accent shrink-0"
                                    disabled={busy}
                                    onClick={lambda e: MouseEvent { saveRename(wid); }}
                                >SAVE</button>
                                <button
                                    className="jms-btn shrink-0"
                                    onClick={lambda e: MouseEvent { cancelEdit(); }}
                                >CANCEL</button>
                            </div>;
                            skip;
                        }}
                        {if editId != wid {
                            <div className="flex items-center justify-between gap-2">
                                <span className="jms-label">{label}</span>
                                <div className="flex gap-1">
                                    <button
                                        className="jms-btn"
                                        onClick={lambda e: MouseEvent { startEdit(wid, label); }}
                                    >RENAME</button>
                                    <button
                                        className={"jms-btn" + (" jms-btn-danger" if confirmId == wid else "")}
                                        disabled={busy}
                                        onClick={lambda e: MouseEvent { removeWs(wid); }}
                                    >{"SURE?" if confirmId == wid else "DELETE"}</button>
                                </div>
                            </div>;
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
                            />
                        }}
                    </div>
                    <button
                        className="jms-btn jms-btn-accent"
                        disabled={busy}
                        onClick={addWs}
                    >{"CREATING…" if busy else "ADD"}</button>
                </div>

                {if status {
                    <p className="text-xs text-muted-foreground">{status}</p>
                }}
            </div>
        </aside>
    </div>;
}
