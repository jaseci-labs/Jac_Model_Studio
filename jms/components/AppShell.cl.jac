"""App shell — workspace switcher + the active workspace's active section.

Workspace list comes from the graph (ui_layout → root --> Workspace, SQLite-persisted).
All section instances stay mounted and are shown/hidden (CSS) so per-section
state survives switches — critically, an in-flight chat SSE stream keeps writing
when you peek at another workspace. The last workspace is remembered in
localStorage; first-ever visit lands on the last discovered attempt (highest NN).
"""

import from react { useEffect, useRef }
sv import from ..models { system_ram }
sv import from ..workspace { ui_layout }
import from ..auth_session { handleUnauthorized }
import from .NavRail { NavRail }
import from .WorkspaceBar { WorkspaceBar }
import from .Offline { Offline }
import from .SectionMount { SectionMount }
import from .WorkspaceSettings { WorkspaceSettings }
import from .AssistantPanel { AssistantPanel }
import from .jms.ApiKeyModal { ApiKeyModal }
import from .shared.CommandPalette { CommandPalette }
import from .shared.Shortcuts { ShortcutSheet, isTypingTarget, toggleTheme }
import from .shared.Toast { ToastHost }
import from .shared.JobWatch { JobWatch }

"""Fresh per-workspace section pointers (first section in each workspace)."""
def _defaultSections(layout: any) -> dict {
    nd: dict = {};
    for ws in list(layout["workspaces"]) {
        wd = ws as dict;
        wid = str(wd["id"]);
        secs = list(wd["sections"]);
        first = secs[0] as dict if len(secs) > 0 else {"id": "chat"};
        nd[wid] = str(first["id"]);
    }
    return nd;
}

def _mergeSections(layout: any, prev: dict) -> dict {
    nd: dict = {};
    for ws in list(layout["workspaces"]) {
        wd = ws as dict;
        wid = str(wd["id"]);
        if wid in prev {
            nd[wid] = str(prev[wid]);
        } else {
            secs = list(wd["sections"]);
            first = secs[0] as dict if len(secs) > 0 else {"id": "chat"};
            nd[wid] = str(first["id"]);
        }
    }
    return nd;
}

def _isWorkspaceId(layout: any, w: str) -> bool {
    for wid in list(layout["workspace_ids"]) {
        if str(wid) == w { return True; }
    }
    return False;
}

"""Resolve a workspace id OR label (case-insensitive) to its id, so the assistant
can say "SFT/DPO" or "04" and land the same place. Empty string if no match."""
def _resolveWs(layout: any, x: str) -> str {
    if layout is None or not x { return ""; }
    want = x.strip().lower();
    for ws in list(layout["workspaces"]) {
        wd = ws as dict;
        if str(wd["id"]).lower() == want or str(wd["label"]).lower() == want {
            return str(wd["id"]);
        }
    }
    return "";
}

"""Section ids of one workspace, in rail order — the `[` / `]` cycle order."""
def _sectionIds(layout: any, ws: str) -> list {
    out: list = [];
    if layout is None { return out; }
    for w in list(layout["workspaces"]) {
        wd = w as dict;
        if str(wd["id"]) == ws {
            for sec in list(wd["sections"]) {
                sd = sec as dict;
                out.append(str(sd["id"]));
            }
        }
    }
    return out;
}

"""Command-palette menu for the Experiments surface. Order here IS display
order (the palette does not re-rank), so categories stay contiguous."""
def _expActions(layout: any, workspace: str) -> list {
    out: list = [];
    if layout is None { return out; }
    n: int = 0;
    for w in list(layout["workspaces"]) {
        wd = w as dict;
        wid = str(wd["id"]);
        n += 1;
        out.append({
            "id": "ws:" + wid,
            "group": "WORKSPACE",
            "label": wid + " " + str(wd["label"]),
            "hint": str(n) if n <= 6 else ""
        });
    }
    for w in list(layout["workspaces"]) {
        wd = w as dict;
        if str(wd["id"]) != workspace { continue; }
        for sec in list(wd["sections"]) {
            sd = sec as dict;
            out.append({
                "id": "sec:" + str(sd["id"]),
                "group": "SECTION",
                "label": str(sd["label"]),
                "hint": ""
            });
        }
    }
    out.append({"id": "nav:hub", "group": "GO TO", "label": "Hub — the landing screen", "hint": "g h"});
    out.append({"id": "nav:jms", "group": "GO TO", "label": "JMS — project pipeline", "hint": ""});
    out.append({"id": "ui:settings", "group": "SETTINGS", "label": "Workspaces settings drawer", "hint": ""});
    out.append({"id": "ui:keys", "group": "SETTINGS", "label": "Provider API keys", "hint": ""});
    out.append({"id": "ui:theme", "group": "SETTINGS", "label": "Toggle light / dark", "hint": "t"});
    out.append({"id": "ui:help", "group": "SETTINGS", "label": "Keyboard shortcuts", "hint": "?"});
    return out;
}

"""Cross-surface navigation. frontend.cl.jac routes on the URL hash and listens
for hashchange, so writing the hash is the whole hop."""
def _goHash(h: str) -> None {
    try {
        w: any = window;
        w.location.hash = h;
    } except Exception { }
}

"""Flatten workspace × section mounts for a single JSX iteration pass."""
def _allSlots(layout: any) -> list[dict] {
    out: list[dict] = [];
    for ws in list(layout["workspaces"]) {
        wd = ws as dict;
        wsId = str(wd["id"]);
        dm = str(wd["default_model"]);
        for sec in list(wd["sections"]) {
            sd = sec as dict;
            out.append({
                "wsId": wsId,
                "secId": str(sd["id"]),
                "component": str(sd["component"]),
                "defaultModel": dm
            });
        }
    }
    return out;
}

def:pub AppShell(onHub: any = None) -> JsxElement {
    has layout: any = None,
        workspace: str = "03",
        sections: dict = {},
        online: int = -1,
        settingsOpen: bool = False,
        paletteOpen: bool = False,
        sheetOpen: bool = False,
        keyModalOpen: bool = False;

    async def probe -> None {
        try {
            await system_ram();
            online = 1;
        } except Exception {
            restored: bool = False;
            restored = await handleUnauthorized();
            if restored {
                try {
                    await system_ram();
                    online = 1;
                    return;
                } except Exception { }
            }
            online = 0;
        }
    }

    def handleLayoutChange(ly: any) -> None {
        sections = _mergeSections(ly, sections);
        layout = ly;
        if not _isWorkspaceId(ly, workspace) {
            workspace = str(ly["default_workspace"]);
        }
    }

    async can with entry {
        doc: any = document;
        win: any = window;
        mode: str = "dark";
        try {
            saved: any = win.localStorage.getItem("jacml.mode");
            if saved { mode = str(saved); }
            elif win.matchMedia and win.matchMedia("(prefers-color-scheme: light)").matches { mode = "light"; }
        } except Exception { }
        if mode == "dark" { doc.documentElement.classList.add("dark"); }
        else { doc.documentElement.classList.remove("dark"); }
        doc.body.classList.add("antialiased");
        try {
            ly = await ui_layout();
            layout = ly;
            workspace = str(ly["default_workspace"]);
            sections = _defaultSections(ly);
            w: any = window;
            saved: any = w.localStorage.getItem("jacml.workspace");
            if saved and _isWorkspaceId(ly, str(saved)) {
                workspace = str(saved);
            }
        } except Exception { }
        await probe();
    }

    # Liveness poller. Deliberately NOT inside `can with entry`: that block's
    # compiled cleanup can't see an id assigned later, so every hub↔experiments
    # round-trip (which unmounts AppShell) used to leak another permanent 3s
    # timer — and a zombie probe() failing calls handleUnauthorized() →
    # signalExpired() → jacLogout(), i.e. an unmounted shell could log the user
    # out. Effect-local id + cleanup, same shape as Cloud/Train.
    useEffect(lambda {
        iv: any = setInterval(lambda { probe(); }, 3000);
        return lambda { clearInterval(float(str(iv))); };
    }, []);

    def goWorkspace(wsId: str) -> None {
        workspace = wsId;
        try {
            win: any = window;
            win.localStorage.setItem("jacml.workspace", wsId);
        } except Exception { }
    }

    def go(s: str) -> None {
        if layout is None { return; }
        nd: dict = {};
        for ws in list(layout["workspaces"]) {
            wd = ws as dict;
            wid = str(wd["id"]);
            nd[wid] = str(sections[wid]) if wid in sections else "chat";
        }
        nd[workspace] = s;
        sections = nd;
    }

    def slot(ws: str, s: str) -> str {
        vis = ws == workspace and s == str(sections[ws]);
        return "flex min-w-0 flex-1 reveal" if vis else "hidden";
    }

    """Cycle the active workspace's sections (the `[` / `]` bindings)."""
    def moveSection(delta: int) -> None {
        if layout is None { return; }
        ids: list = _sectionIds(layout, workspace);
        if len(ids) == 0 { return; }
        curId: str = str(sections[workspace]) if workspace in sections else "";
        at: int = 0;
        i: int = 0;
        for sid in ids {
            if str(sid) == curId { at = i; }
            i += 1;
        }
        go(str(ids[(at + delta + len(ids)) % len(ids)]));
    }

    """The `1`–`6` bindings: Nth workspace in layout order."""
    def wsByIndex(n: int) -> None {
        if layout is None { return; }
        ids: list = list(layout["workspace_ids"]);
        if n >= 0 and n < len(ids) { goWorkspace(str(ids[n])); }
    }

    def goHub -> None {
        if onHub is not None { onHub(); }
    }

    """Single dispatch point for every palette entry built by _expActions."""
    def runAction(aid: str) -> None {
        if aid.startswith("ws:") { goWorkspace(aid[3:]); return; }
        if aid.startswith("sec:") { go(aid[4:]); return; }
        if aid == "nav:hub" { goHub(); return; }
        if aid == "nav:jms" { _goHash("jms"); return; }
        if aid == "ui:settings" { settingsOpen = True; return; }
        if aid == "ui:keys" { keyModalOpen = True; return; }
        if aid == "ui:theme" { toggleTheme(); return; }
        if aid == "ui:help" { sheetOpen = True; return; }
    }

    # `g h` chord state lives in a ref, never a `has`: the keydown listener is a
    # closure and a `has` read inside it goes stale. The listener is added and
    # REMOVED in the same effect; deps carry every value the handler reads, so
    # the registered closure is always the current one.
    gRef: any = useRef(0.0);
    useEffect(lambda {
        doc: any = document;
        onKey = lambda(e: any) {
            k: str = str(e.key);
            meta: bool = bool(e.metaKey) or bool(e.ctrlKey);
            if meta and (k == "k" or k == "K") {
                e.preventDefault();
                paletteOpen = not paletteOpen;
                return;
            }
            if meta or bool(e.altKey) { return; }
            # never steal a key the user is typing into a field
            if isTypingTarget(e) { return; }
            if paletteOpen { return; }
            if k == "?" { sheetOpen = not sheetOpen; return; }
            if sheetOpen { return; }
            if k == "g" { gRef.current = Date.now(); return; }
            if k == "h" {
                if (Date.now() - float(str(gRef.current))) < 900.0 {
                    gRef.current = 0.0;
                    goHub();
                }
                return;
            }
            if k == "t" { toggleTheme(); return; }
            if k == "[" { moveSection(-1); return; }
            if k == "]" { moveSection(1); return; }
            if k in ["1", "2", "3", "4", "5", "6"] { wsByIndex(int(k) - 1); return; }
        };
        doc.addEventListener("keydown", onKey);
        return lambda { doc.removeEventListener("keydown", onKey); };
    }, [layout, workspace, sections, paletteOpen, sheetOpen]);

    if online == 0 {
        return <Offline />;
    }
    if online == -1 or layout is None {
        return <div className="h-screen bg-background" />;
    }

    # Nav bridge for the assistant widget: re-published every render so the
    # closures always capture the LATEST layout/workspace/sections (no React
    # stale-closure). The widget calls window.__jmsNav.goWorkspace/go to drive
    # experiments navigation; label→id resolution happens here where layout lives.
    try {
        wbridge: any = window;
        wbridge.__jmsNav = {
            "goWorkspace": lambda(x: str) -> None {
                rid = _resolveWs(layout, x);
                if rid { goWorkspace(rid); }
            },
            "go": go
        };
    } except Exception { }

    return <div className="flex h-screen flex-col overflow-hidden" data-ws={workspace}>
        <WorkspaceBar
            layout={layout}
            workspace={workspace}
            onWorkspace={goWorkspace}
            onSettings={lambda -> None { settingsOpen = True; }}
            onHub={onHub}
        />

        <div className="flex min-h-0 flex-1 overflow-hidden">
            <NavRail
                layout={layout}
                workspace={workspace}
                section={str(sections[workspace])}
                onSection={go}
            />

            {for slotInfo in _allSlots(layout) {
                wsId = str(slotInfo["wsId"]);
                sid = str(slotInfo["secId"]);
                comp = str(slotInfo["component"]);
                dm = str(slotInfo["defaultModel"]);
                active = wsId == workspace and sid == str(sections[wsId]);
                <div key={wsId + "|" + sid} className={slot(wsId, sid)}>
                    <SectionMount
                        component={comp}
                        workspace={wsId}
                        defaultModel={dm}
                        active={active}
                    />
                </div>
            }}
        </div>

        <WorkspaceSettings
            open={settingsOpen}
            layout={layout}
            activeWorkspace={workspace}
            onClose={lambda -> None { settingsOpen = False; }}
            onChanged={handleLayoutChange}
        />

        {keyModalOpen and <ApiKeyModal open={True} onClose={lambda { keyModalOpen = False; }} />}

        <CommandPalette
            open={paletteOpen}
            actions={_expActions(layout, workspace)}
            onRun={runAction}
            onClose={lambda { paletteOpen = False; }}
        />

        <ShortcutSheet open={sheetOpen} onClose={lambda { sheetOpen = False; }} />

        <ToastHost />
        <JobWatch />

        <AssistantPanel pageContext={"Experiments surface · workspace " + workspace + (" · section " + str(sections[workspace]) if workspace in sections else "")} />
    </div>;
}
