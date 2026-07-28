"""JmsShell — the JMS product surface.

Top-of-app level (no project open): a `<WorkspaceBar>` (the same generic
renderer Experiments uses) shows JMS workspace tiles fetched from
`jms_ui_layout()`, plus ThemeSwitcher + ⚙ KEYS + ⚙ WORKSPACES. Switching tiles
sets `jmsWorkspace`, which is passed down to `<JmsProjects>` as `group` so the
grid filters to that workspace. The MAIN/default workspace is a special case:
it passes `group=""` (list_projects' back-compat "all projects" behavior) so
projects created before workspaces existed (group_id == "") stay visible —
only non-default workspaces filter strictly to their own group_id (see
`_effectiveGroup` below).

Once a project is open, this collapses back to the original slim breadcrumb
bar (‹ PROJECTS / <NAME>) + KEYS + ‹ HOME + ThemeSwitcher — a project has its own
internal stage rail, so the workspace bar isn't needed there. Body routes on
`projectId`: empty → the <JmsProjects/> card grid, otherwise the <JmsProject/>
detail view for that id. The breadcrumb name is captured from JmsProjects'
onOpen(pid, name) callback.

`openWsSettings` flips `wsSettingsOpen`, which mounts the `<JmsWorkspaceSettings>`
drawer (add/rename/delete JMS workspaces); its `onChanged` refreshes `jmsLayout`
so the WorkspaceBar tiles above stay in sync with the graph.

Back-label convention (one across all three surfaces): **`‹ HOME` always means
"leave this surface, go to the hub"** — Experiments' WorkspaceBar, JMS's
WorkspaceBar and both hand-rolled JMS bars now all use it (the old `◈ HUB`
spelling is gone). `‹ PROJECTS` is a different action — up ONE level inside JMS,
back to the project grid — so it keeps its own label.

Why two bars are still hand-rolled rather than `<WorkspaceBar/>`:
  * project-open bar — WorkspaceBar's whole body is the workspace tile row, and
    an open project deliberately hides it (the project has its own stage rail).
    It also has no slot for the `/ <PROJECT NAME>` breadcrumb. Passing
    `onHub=backToProjects` would fake the button but drag the tile row back in.
  * loading bar — it exists precisely because `jmsLayout` is still None, and
    WorkspaceBar dereferences `layout["workspaces"]` unconditionally.
Both are visually identical to WorkspaceBar anyway: `.jms-topbar` and
`.exp-topbar` are one grouped rule in global.css."""

import from react { useEffect, useRef }
sv import from ..jms_workspaces { jms_ui_layout }
sv import from ..jms_projects { list_projects }
import from .JmsProjects { JmsProjects }
import from .JmsProject { JmsProject }
import from .JmsWorkspaceSettings { JmsWorkspaceSettings }
import from .ApiKeyModal { ApiKeyModal }
import from ..ThemeSwitcher { ThemeSwitcher }
import from ..WorkspaceBar { WorkspaceBar }
import from ..AssistantPanel { AssistantPanel }
import from ..shared.CommandPalette { CommandPalette }
import from ..shared.Shortcuts { ShortcutSheet, isTypingTarget, toggleTheme }
import from ..shared.Toast { ToastHost }
import from ..shared.JobWatch { JobWatch }

"""MAIN/default workspace shows every project (back-compat list_projects("")
— includes pre-workspace ungrouped projects); any other workspace filters
strictly to its own id. `ly` may be None while jms_ui_layout() is still
loading."""
def _effectiveGroup(ly: any, ws: str) -> str {
    if ly is None { return ""; }
    return "" if ws == str(ly["default_workspace"]) else ws;
}

"""Cross-surface navigation. frontend.cl.jac routes on the URL hash and listens
for hashchange, so writing the hash is the whole hop."""
def _goHash(h: str) -> None {
    try {
        w: any = window;
        w.location.hash = h;
    } except Exception { }
}

"""Command-palette menu for the JMS surface. Order here IS display order (the
palette does not re-rank), so categories stay contiguous."""
def _jmsActions(ly: any, projects: list, projectOpen: bool) -> list {
    out: list = [];
    wsList: list = list(ly["workspaces"]) if ly is not None else [];
    n: int = 0;
    for w in wsList {
        wd = w as dict;
        n += 1;
        out.append({
            "id": "jws:" + str(wd["id"]),
            "group": "WORKSPACE",
            "label": str(wd["label"]),
            "hint": str(n) if n <= 6 else ""
        });
    }
    for p in projects {
        pd = p as dict;
        out.append({
            "id": "proj:" + str(pd["pid"]) + "|" + str(pd["name"]),
            "group": "PROJECT",
            "label": str(pd["name"]),
            "hint": ""
        });
    }
    if projectOpen {
        out.append({"id": "nav:projects", "group": "GO TO", "label": "Back to the project list", "hint": ""});
    }
    out.append({"id": "nav:hub", "group": "GO TO", "label": "Hub — the landing screen", "hint": "g h"});
    out.append({"id": "nav:experiments", "group": "GO TO", "label": "Experiments — workspaces", "hint": ""});
    out.append({"id": "ui:settings", "group": "SETTINGS", "label": "Workspaces settings drawer", "hint": ""});
    out.append({"id": "ui:keys", "group": "SETTINGS", "label": "Provider API keys", "hint": ""});
    out.append({"id": "ui:theme", "group": "SETTINGS", "label": "Toggle light / dark", "hint": "t"});
    out.append({"id": "ui:help", "group": "SETTINGS", "label": "Keyboard shortcuts", "hint": "?"});
    return out;
}

def:pub JmsShell(onHub: any = None) -> JsxElement {
    has projectId: str = "",
        projectName: str = "",
        keyModalOpen: bool = False,
        jmsLayout: any = None,
        jmsWorkspace: str = "",
        wsSettingsOpen: bool = False,
        paletteOpen: bool = False,
        sheetOpen: bool = False,
        projects: list = [];

    async def loadProjects -> None {
        try {
            r = await list_projects("");
            acc: list = [];
            for p in r { acc.append({"pid": str(p.pid), "name": str(p.name)}); }
            projects = acc;
        } except Exception { }
    }

    async can with entry {
        try {
            ly = await jms_ui_layout();
            jmsLayout = ly;
            jmsWorkspace = str(ly["default_workspace"]);
        } except Exception { }
        await loadProjects();
    }

    def openProject(pid: str, name: str) -> None {
        projectId = pid;
        projectName = name;
    }

    def backToProjects -> None {
        projectId = "";
        projectName = "";
    }

    def switchWs(wid: str) -> None {
        jmsWorkspace = wid;
    }

    def openWsSettings -> None {
        wsSettingsOpen = True;
    }

    """Opening the palette re-reads the project list so a project created since
    mount is findable. Fire-and-forget: the palette renders from `projects` and
    re-renders when the fetch lands."""
    def openPalette -> None {
        paletteOpen = True;
        loadProjects();
    }

    """The `1`–`6` bindings: Nth JMS workspace in layout order. Inert inside an
    open project — the workspace row isn't on screen there, so switching it would
    be an invisible state change."""
    def wsByIndex(n: int) -> None {
        if jmsLayout is None or projectId { return; }
        ids: list = list(jmsLayout["workspace_ids"]);
        if n >= 0 and n < len(ids) { switchWs(str(ids[n])); }
    }

    """`[` / `]` cycle the workspace tiles.
    # ponytail: JMS's second axis (a project's SOURCES→…→EVAL stage rail) lives
    inside JmsProject, which owns that state and which this agent does not own —
    so inside an open project these keys are a deliberate no-op."""
    def moveWs(delta: int) -> None {
        if jmsLayout is None or projectId { return; }
        ids: list = list(jmsLayout["workspace_ids"]);
        if len(ids) == 0 { return; }
        at: int = 0;
        i: int = 0;
        for wid in ids {
            if str(wid) == jmsWorkspace { at = i; }
            i += 1;
        }
        switchWs(str(ids[(at + delta + len(ids)) % len(ids)]));
    }

    def goHub -> None {
        if onHub is not None { onHub(); }
    }

    """Single dispatch point for every palette entry built by _jmsActions."""
    def runAction(aid: str) -> None {
        if aid.startswith("jws:") { switchWs(aid[4:]); return; }
        if aid.startswith("proj:") {
            # id is "proj:<pid>|<name>" — pid never contains '|', a name might,
            # so everything after the FIRST separator is re-joined as the name.
            parts: list = aid[5:].split("|");
            pid: str = str(parts[0]);
            openProject(pid, "|".join(parts[1:]) if len(parts) > 1 else pid);
            return;
        }
        if aid == "nav:projects" { backToProjects(); return; }
        if aid == "nav:hub" { goHub(); return; }
        if aid == "nav:experiments" { _goHash("experiments"); return; }
        if aid == "ui:settings" { openWsSettings(); return; }
        if aid == "ui:keys" { keyModalOpen = True; return; }
        if aid == "ui:theme" { toggleTheme(); return; }
        if aid == "ui:help" { sheetOpen = True; return; }
    }

    # `g h` chord state lives in a ref, never a `has`: the keydown listener is a
    # closure and a `has` read inside it goes stale. The listener is added and
    # REMOVED in the same effect; deps carry every value the handler reads.
    gRef: any = useRef(0.0);
    useEffect(lambda {
        doc: any = document;
        onKey = lambda(e: any) {
            k: str = str(e.key);
            meta: bool = bool(e.metaKey) or bool(e.ctrlKey);
            if meta and (k == "k" or k == "K") {
                e.preventDefault();
                if paletteOpen { paletteOpen = False; } else { openPalette(); }
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
            if k == "[" { moveWs(-1); return; }
            if k == "]" { moveWs(1); return; }
            if k in ["1", "2", "3", "4", "5", "6"] { wsByIndex(int(k) - 1); return; }
        };
        doc.addEventListener("keydown", onKey);
        return lambda { doc.removeEventListener("keydown", onKey); };
    }, [jmsLayout, jmsWorkspace, projectId, paletteOpen, sheetOpen]);

    return <div
        className="jms-scope flex h-screen w-screen flex-col overflow-hidden"
    >
        {if projectId {
            <div key="topbar-project" className="jms-topbar reveal stagger-1">
                <div className="flex items-center gap-4">
                    <span className="jms-label">JMS</span>
                    <div className="flex items-center gap-2">
                        <button
                            className="jms-btn"
                            onClick={lambda e: MouseEvent { backToProjects(); }}
                        >‹ PROJECTS</button>
                        <span className="jms-label" style={{"color": "var(--jms-fg)"}}>
                            {" / " + projectName}
                        </span>
                    </div>
                </div>
                <div className="flex items-center gap-4">
                    <ThemeSwitcher />
                    <button
                        className="jms-btn"
                        title="provider keys"
                        onClick={lambda e: MouseEvent { keyModalOpen = True; }}
                    >⚙ KEYS</button>
                    <button
                        className="jms-btn"
                        title="back to hub"
                        onClick={lambda e: MouseEvent { if onHub is not None { onHub(); } }}
                    >‹ HOME</button>
                </div>
            </div>;
            skip;
        }}
        {if not projectId and jmsLayout is not None {
            <WorkspaceBar
                key="wsbar"
                layout={jmsLayout}
                workspace={jmsWorkspace}
                onWorkspace={switchWs}
                onSettings={openWsSettings}
                onHub={onHub}
                onKeys={lambda -> None { keyModalOpen = True; }}
                backLabel="‹ HOME"
            />;
            skip;
        }}
        {if not projectId and jmsLayout is None {
            <div key="topbar-plain" className="jms-topbar reveal stagger-1">
                <div className="flex items-center gap-4">
                    <span className="jms-label">JMS</span>
                    <span className="jms-label">PROJECTS</span>
                </div>
                <div className="flex items-center gap-4">
                    <ThemeSwitcher />
                    <button
                        className="jms-btn"
                        title="back to hub"
                        onClick={lambda e: MouseEvent { if onHub is not None { onHub(); } }}
                    >‹ HOME</button>
                </div>
            </div>;
            skip;
        }}

        {keyModalOpen and <ApiKeyModal open={True} onClose={lambda -> None { keyModalOpen = False; }} />}

        <JmsWorkspaceSettings
            open={wsSettingsOpen}
            layout={jmsLayout}
            workspace={jmsWorkspace}
            onClose={lambda -> None { wsSettingsOpen = False; }}
            onChanged={lambda ly: any { jmsLayout = ly; }}
        />

        <CommandPalette
            open={paletteOpen}
            actions={_jmsActions(jmsLayout, projects, bool(projectId))}
            onRun={runAction}
            onClose={lambda { paletteOpen = False; }}
        />

        <ShortcutSheet open={sheetOpen} onClose={lambda { sheetOpen = False; }} />

        <ToastHost />
        <JobWatch />

        <AssistantPanel pageContext={("JMS surface · project '" + projectName + "' (pipeline: sources/generate/curate/train/eval)") if projectId else ("JMS surface · project list · workspace " + jmsWorkspace)} />

        <div className="flex min-h-0 flex-1 flex-col overflow-hidden reveal stagger-2">
            {if projectId {
                <JmsProject key="proj" pid={projectId} onBack={backToProjects} />
                skip;
            }}
            {if not projectId {
                <JmsProjects key="projlist" onOpen={openProject} group={_effectiveGroup(jmsLayout, jmsWorkspace)} />
                skip;
            }}
        </div>
    </div>;
}
