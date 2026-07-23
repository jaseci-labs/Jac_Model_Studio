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
bar (‹ PROJECTS / <NAME>) + KEYS + HUB + ThemeSwitcher — a project has its own
internal stage rail, so the workspace bar isn't needed there. Body routes on
`projectId`: empty → the <JmsProjects/> card grid, otherwise the <JmsProject/>
detail view for that id. The breadcrumb name is captured from JmsProjects'
onOpen(pid, name) callback.

`openWsSettings` flips `wsSettingsOpen`, which mounts the `<JmsWorkspaceSettings>`
drawer (add/rename/delete JMS workspaces); its `onChanged` refreshes `jmsLayout`
so the WorkspaceBar tiles above stay in sync with the graph."""

sv import from ..jms_workspaces { jms_ui_layout }
import from .JmsProjects { JmsProjects }
import from .JmsProject { JmsProject }
import from .JmsWorkspaceSettings { JmsWorkspaceSettings }
import from .ApiKeyModal { ApiKeyModal }
import from ..ThemeSwitcher { ThemeSwitcher }
import from ..WorkspaceBar { WorkspaceBar }
import from ..AssistantPanel { AssistantPanel }

"""MAIN/default workspace shows every project (back-compat list_projects("")
— includes pre-workspace ungrouped projects); any other workspace filters
strictly to its own id. `ly` may be None while jms_ui_layout() is still
loading."""
def _effectiveGroup(ly: any, ws: str) -> str {
    if ly is None { return ""; }
    return "" if ws == str(ly["default_workspace"]) else ws;
}

def:pub JmsShell(onHub: any = None) -> JsxElement {
    has projectId: str = "",
        projectName: str = "",
        keyModalOpen: bool = False,
        jmsLayout: any = None,
        jmsWorkspace: str = "",
        wsSettingsOpen: bool = False;

    async can with entry {
        try {
            ly = await jms_ui_layout();
            jmsLayout = ly;
            jmsWorkspace = str(ly["default_workspace"]);
        } except Exception { }
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

    return <div
        className="jms-scope flex h-screen w-screen flex-col overflow-hidden"
    >
        {if projectId {
            <div className="jms-topbar reveal stagger-1">
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
                    >◈ HUB</button>
                </div>
            </div>;
            skip;
        }}
        {if not projectId and jmsLayout is not None {
            <WorkspaceBar
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
            <div className="jms-topbar reveal stagger-1">
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
                    >◈ HUB</button>
                </div>
            </div>;
            skip;
        }}

        {keyModalOpen and <ApiKeyModal open={True} onClose={lambda -> None { keyModalOpen = False; }} />}

        <JmsWorkspaceSettings
            open={wsSettingsOpen}
            layout={jmsLayout}
            onClose={lambda -> None { wsSettingsOpen = False; }}
            onChanged={lambda ly: any { jmsLayout = ly; }}
        />

        <AssistantPanel pageContext="" />

        <div className="flex min-h-0 flex-1 flex-col overflow-hidden reveal stagger-2">
            {if projectId {
                <JmsProject pid={projectId} onBack={backToProjects} />
                skip;
            }}
            {if not projectId {
                <JmsProjects onOpen={openProject} group={_effectiveGroup(jmsLayout, jmsWorkspace)} />
                skip;
            }}
        </div>
    </div>;
}
