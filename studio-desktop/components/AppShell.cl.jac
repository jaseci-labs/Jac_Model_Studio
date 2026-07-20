"""App shell — workspace switcher + the active workspace's active section.

Workspace list comes from the graph (ui_layout → root --> Workspace, SQLite-persisted).
All section instances stay mounted and are shown/hidden (CSS) so per-section
state survives switches — critically, an in-flight chat SSE stream keeps writing
when you peek at another workspace. The last workspace is remembered in
localStorage; first-ever visit lands on the last discovered attempt (highest NN).
"""

sv import from ..models { system_ram }
sv import from ..workspace { ui_layout }
import from ..auth_session { handleUnauthorized }
import from .NavRail { NavRail }
import from .Offline { Offline }
import from .SectionMount { SectionMount }
import from .WorkspaceSettings { WorkspaceSettings }

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

def:pub AppShell -> JsxElement {
    has layout: any = None,
        workspace: str = "03",
        sections: dict = {},
        online: int = -1,
        settingsOpen: bool = False;

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
        doc.documentElement.classList.add("dark");
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
        setInterval(lambda -> None { probe(); }, 3000);
    }

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
        return "flex min-w-0 flex-1" if vis else "hidden";
    }

    if online == 0 {
        return <Offline />;
    }
    if online == -1 or layout is None {
        return <div className="h-screen bg-[#0a0a0a]" />;
    }

    return <div className="flex h-screen overflow-hidden" data-ws={workspace}>
        <NavRail
            layout={layout}
            workspace={workspace}
            section={str(sections[workspace])}
            onWorkspace={goWorkspace}
            onSection={go}
            onSettings={lambda -> None { settingsOpen = True; }}
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

        <WorkspaceSettings
            open={settingsOpen}
            layout={layout}
            onClose={lambda -> None { settingsOpen = False; }}
            onChanged={handleLayoutChange}
        />
    </div>;
}
