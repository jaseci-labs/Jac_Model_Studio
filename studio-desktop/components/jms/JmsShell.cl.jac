"""JmsShell — the JMS product surface.

Top bar: a JMS wordmark that doubles as a breadcrumb (PROJECTS / <NAME> once a
project is open — PROJECTS is clickable to go back) and a ◈ HUB return. Theme
is locked to electric-minimal (the other 4 variants stay defined in jms.css,
unused — cheap to revive later, not worth deleting now). Body routes on
`projectId`: empty → the <JmsProjects/> card grid, otherwise the <JmsProject/>
detail view for that id. The breadcrumb name is captured from JmsProjects'
onOpen(pid, name) callback."""

import from .JmsProjects { JmsProjects }
import from .JmsProject { JmsProject }
import from .ApiKeyModal { ApiKeyModal }

def:pub JmsShell(onHub: any = None, theme: str = "", onTheme: any = None) -> JsxElement {
    has projectId: str = "",
        projectName: str = "",
        keyModalOpen: bool = False;

    t: str = "electric-minimal";

    def openProject(pid: str, name: str) -> None {
        projectId = pid;
        projectName = name;
    }

    def backToProjects -> None {
        projectId = "";
        projectName = "";
    }

    return <div
        className="jms-scope flex h-screen w-screen flex-col overflow-hidden"
        data-jms-theme={t}
    >
        <div className="jms-topbar">
            <div className="flex items-center gap-4">
                <span className="jms-label">JMS</span>
                <div className="flex items-center gap-2">
                    {projectId and <button
                        className="jms-btn"
                        onClick={lambda e: MouseEvent { backToProjects(); }}
                    >‹ PROJECTS</button>}
                    {not projectId and <span className="jms-label">PROJECTS</span>}
                    {projectId and <span className="jms-label" style={{"color": "var(--jms-fg)"}}>
                        {" / " + projectName}
                    </span>}
                </div>
            </div>
            <div className="flex items-center gap-4">
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
        </div>

        {keyModalOpen and <ApiKeyModal open={True} onClose={lambda -> None { keyModalOpen = False; }} />}

        {if projectId {
            <JmsProject pid={projectId} onBack={backToProjects} />
            skip;
        }}
        {if not projectId {
            <JmsProjects onOpen={openProject} />
            skip;
        }}
    </div>;
}
