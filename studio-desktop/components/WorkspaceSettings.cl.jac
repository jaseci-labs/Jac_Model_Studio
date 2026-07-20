"""Workspace management drawer — CRUD for workspaces and sections on the graph."""

sv import from ..workspace {
    ui_layout, section_types,
    create_workspace, update_workspace, delete_workspace, reorder_workspaces,
    add_section, update_section, delete_section, reorder_sections
}
sv import from ..models { list_models, ModelView }
import from .shared.Field { Field, TextInput }

def _wsById(layout: any, wid: str) -> dict | None {
    for ws in list(layout["workspaces"]) {
        wd = ws as dict;
        if str(wd["id"]) == wid { return wd; }
    }
    return None;
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
    onChanged: Callable[[any], None]
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
        status: str = "",
        busy: bool = False;

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

    async def reloadLayout -> None {
        ly = await ui_layout();
        onChanged(ly);
        if selected and not _wsById(ly, selected) {
            ids = list(ly["workspace_ids"]);
            selected = str(ids[0]) if len(ids) > 0 else "";
        }
        syncForm(ly);
    }

    def syncForm(ly: any) -> None {
        wd = _wsById(ly, selected);
        if not wd { return; }
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

    async can with entry {
        if not open { return; }
        try {
            models = await list_models();
            secTypes = await section_types();
            if len(secTypes) > 0 {
                newSecComponent = str((secTypes[0] as dict)["component"]);
            }
        } except Exception { }
        if layout {
            ids = list(layout["workspace_ids"]);
            if not selected and len(ids) > 0 { selected = str(ids[0]); }
            syncForm(layout);
        }
    }

    async can with [open] entry {
        if not open { return; }
        await reloadLayout();
    }

    async can with [selected] entry {
        if layout { syncForm(layout); }
    }

    async def saveWorkspace -> None {
        if not selected or busy { return; }
        busy = True;
        status = "";
        try {
            await update_workspace(
                selected, label, accent, defaultModel, _filesFromStr(filesStr)
            );
            await reloadLayout();
            status = "Saved workspace.";
        } except Exception as e {
            status = "Save failed: " + str(e);
        }
        busy = False;
    }

    async def addWorkspace -> None {
        if busy or not newWsLabel.strip() { return; }
        busy = True;
        status = "";
        try {
            w = await create_workspace(newWsLabel.strip(), "", defaultModel, []);
            selected = str(w.id);
            newWsLabel = "";
            await reloadLayout();
            status = "Workspace created.";
        } except Exception as e {
            status = "Create failed: " + str(e);
        }
        busy = False;
    }

    async def removeWorkspace -> None {
        if not selected or busy { return; }
        busy = True;
        status = "";
        try {
            ok = await delete_workspace(selected);
            if ok {
                selected = "";
                await reloadLayout();
                status = "Workspace deleted.";
            } else {
                status = "Cannot delete the last workspace.";
            }
        } except Exception as e {
            status = "Delete failed: " + str(e);
        }
        busy = False;
    }

    async def moveWorkspace(up: bool) -> None {
        if not layout or busy { return; }
        ids: list[str] = [];
        for x in list(layout["workspace_ids"]) { ids.append(str(x)); }
        idx = -1;
        for i in range(len(ids)) {
            if ids[i] == selected { idx = i; break; }
        }
        if idx < 0 { return; }
        j = idx - 1 if up else idx + 1;
        if j < 0 or j >= len(ids) { return; }
        tmp = ids[idx];
        ids[idx] = ids[j];
        ids[j] = tmp;
        busy = True;
        try {
            await reorder_workspaces(ids);
            await reloadLayout();
        } except Exception { }
        busy = False;
    }

    async def saveSection(sid: str) -> None {
        if not selected or busy { return; }
        busy = True;
        try {
            await update_section(
                selected, sid, secLabel(sid, ""), secComponent(sid, "Chat")
            );
            await reloadLayout();
            status = "Section updated.";
        } except Exception as e {
            status = "Section save failed: " + str(e);
        }
        busy = False;
    }

    async def removeSection(sid: str) -> None {
        if not selected or busy { return; }
        busy = True;
        try {
            ok = await delete_section(selected, sid);
            status = "Section deleted." if ok else "Cannot delete the last section.";
            await reloadLayout();
        } except Exception as e {
            status = "Delete failed: " + str(e);
        }
        busy = False;
    }

    async def moveSection(sid: str, up: bool) -> None {
        wd = _wsById(layout, selected);
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
        if j < 0 or j >= len(ids) { return; }
        tmp = ids[idx];
        ids[idx] = ids[j];
        ids[j] = tmp;
        busy = True;
        try {
            await reorder_sections(selected, ids);
            await reloadLayout();
        } except Exception { }
        busy = False;
    }

    async def createSection -> None {
        if not selected or busy or not newSecSid.strip() { return; }
        busy = True;
        try {
            lbl = newSecLabel.strip() if newSecLabel.strip() else newSecSid.upper();
            await add_section(selected, newSecSid.strip(), lbl, newSecComponent);
            newSecSid = "";
            newSecLabel = "";
            await reloadLayout();
            status = "Section added.";
        } except Exception as e {
            status = "Add section failed: " + str(e);
        }
        busy = False;
    }

    if not open { return <></>; }

    wd = _wsById(layout, selected);
    secList: list = list(wd["sections"]) if wd else [];

    return <div className="fixed inset-0 z-50 flex">
        <div
            className="flex-1 bg-black/60"
            onClick={lambda (e: MouseEvent) { onClose(); }}
        />
        <aside className="flex h-full w-[28rem] shrink-0 flex-col border-l border-neutral-800 bg-[#0d0d0d]">
            <div className="flex items-center justify-between border-b border-neutral-800 px-4 py-3">
                <span className="micro-label">WORKSPACES</span>
                <button
                    onClick={lambda (e: MouseEvent) { onClose(); }}
                    className="text-neutral-500 hover:text-neutral-200"
                >✕</button>
            </div>

            <div className="flex-1 overflow-y-auto px-4 py-3 space-y-4">
                <div className="space-y-1">
                    {for ws in list(layout["workspaces"]) {
                        w = ws as dict;
                        wid = str(w["id"]);
                        <button
                            key={wid}
                            onClick={lambda (e: MouseEvent) { selected = wid; }}
                            className={"flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left font-mono text-[10px] tracking-wider " + (
                                "bg-[#161616] text-neutral-100" if wid == selected
                                else "text-neutral-500 hover:bg-[#121212]"
                            )}
                        >
                            <span className="h-2 w-2 rounded-full" style={{"background": "var(--" + str(w["accent"]) + ")"}} />
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
                            disabled={busy}
                            className="shrink-0 rounded-md border border-neutral-600 px-3 text-xs text-neutral-200 hover:bg-[#161616]"
                        >ADD</button>
                    </div>
                </Field>

                {if wd {
                    <div className="space-y-3">
                        <Field label="LABEL">
                            <TextInput value={label} onSet={lambda (v: str) { label = v; }} placeholder="Workspace label" mono={False} />
                        </Field>
                        <Field label="ACCENT CSS VAR">
                            <TextInput value={accent} onSet={lambda (v: str) { accent = v; }} placeholder="ws01" mono={True} />
                        </Field>
                        <Field label="DEFAULT MODEL">
                            <select
                                value={defaultModel}
                                onChange={lambda (e: ChangeEvent) { defaultModel = e.target.value; }}
                                className="w-full rounded-md border border-neutral-700 bg-[#121212] px-2 py-1 text-sm text-neutral-100"
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
                            <button onClick={saveWorkspace} disabled={busy} className="rounded-md border border-neutral-600 px-3 py-1 text-xs text-neutral-200 hover:bg-[#161616]">SAVE</button>
                            <button onClick={lambda -> None { moveWorkspace(True); }} disabled={busy} className="rounded-md border border-neutral-700 px-2 py-1 text-xs text-neutral-400">↑</button>
                            <button onClick={lambda -> None { moveWorkspace(False); }} disabled={busy} className="rounded-md border border-neutral-700 px-2 py-1 text-xs text-neutral-400">↓</button>
                            <button onClick={removeWorkspace} disabled={busy} className="rounded-md border border-neutral-700 px-3 py-1 text-xs text-neutral-500 hover:text-neutral-200">DELETE</button>
                        </div>
                    </div>
                }}

                <div className="dashed-rule" />

                <span className="micro-label">SECTIONS</span>
                {for sec in secList {
                    sd = sec as dict;
                    sid = str(sd["id"]);
                    sl = secLabel(sid, str(sd["label"]));
                    sc = secComponent(sid, str(sd["component"]));
                    <div key={sid} className="rounded-md border border-neutral-800 bg-[#0a0a0a] p-2 space-y-2">
                        <div className="font-mono text-[10px] text-neutral-500">{sid}</div>
                        <TextInput value={sl} onSet={lambda (v: str) { setSecLabel(sid, v); }} placeholder="LABEL" mono={False} />
                        <select
                            value={sc}
                            onChange={lambda (e: ChangeEvent) { setSecComponent(sid, e.target.value); }}
                            className="w-full rounded-md border border-neutral-700 bg-[#121212] px-2 py-1 text-xs text-neutral-100"
                        >
                            {for st in secTypes {
                                d = st as dict;
                                <option key={str(d["component"])} value={str(d["component"])}>{str(d["label"])}</option>
                            }}
                        </select>
                        <div className="flex gap-1">
                            <button
                                onClick={lambda -> None { saveSection(sid); }}
                                disabled={busy}
                                className="rounded border border-neutral-700 px-2 py-0.5 text-[10px] text-neutral-300"
                            >SAVE</button>
                            <button onClick={lambda -> None { moveSection(sid, True); }} disabled={busy} className="px-1 text-[10px] text-neutral-500">↑</button>
                            <button onClick={lambda -> None { moveSection(sid, False); }} disabled={busy} className="px-1 text-[10px] text-neutral-500">↓</button>
                            <button
                                onClick={lambda -> None { removeSection(sid); }}
                                disabled={busy}
                                className="px-1 text-[10px] text-neutral-600 hover:text-neutral-300"
                            >✕</button>
                        </div>
                    </div>
                }}

                <Field label="ADD SECTION">
                    <div className="space-y-2">
                        <TextInput value={newSecSid} onSet={lambda (v: str) { newSecSid = v; }} placeholder="section id" mono={True} />
                        <TextInput value={newSecLabel} onSet={lambda (v: str) { newSecLabel = v; }} placeholder="LABEL (optional)" mono={False} />
                        <select
                            value={newSecComponent}
                            onChange={lambda (e: ChangeEvent) { newSecComponent = e.target.value; }}
                            className="w-full rounded-md border border-neutral-700 bg-[#121212] px-2 py-1 text-sm text-neutral-100"
                        >
                            {for st in secTypes {
                                d = st as dict;
                                <option key={str(d["component"])} value={str(d["component"])}>{str(d["label"])}</option>
                            }}
                        </select>
                        <button onClick={createSection} disabled={busy} className="rounded-md border border-neutral-600 px-3 py-1 text-xs text-neutral-200">ADD SECTION</button>
                    </div>
                </Field>

                {if status {
                    <p className="text-xs text-neutral-500">{status}</p>
                }}
            </div>
        </aside>
    </div>;
}
