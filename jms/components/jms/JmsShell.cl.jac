"""JmsShell — the JMS product surface.

Top bar: a JMS wordmark that doubles as a breadcrumb (PROJECTS / <NAME> once a
project is open — PROJECTS is clickable to go back) and a ◈ HUB return.
Light/dark mode is inherited from `:root`/`.dark` via the `<ThemeSwitcher/>`
in the top bar — no per-jms-theme lock. Body routes on `projectId`: empty →
the <JmsProjects/> card grid, otherwise the <JmsProject/> detail view for that
id. The breadcrumb name is captured from JmsProjects' onOpen(pid, name)
callback."""

import from .JmsProjects { JmsProjects }
import from .JmsProject { JmsProject }
import from .ApiKeyModal { ApiKeyModal }
import from ..ThemeSwitcher { ThemeSwitcher }

def:pub JmsShell(onHub: any = None) -> JsxElement {
    has projectId: str = "",
        projectName: str = "",
        keyModalOpen: bool = False;

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
    >
        <div className="jms-topbar reveal stagger-1">
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
        </div>

        {keyModalOpen and <ApiKeyModal open={True} onClose={lambda -> None { keyModalOpen = False; }} />}

        <div className="flex min-h-0 flex-1 flex-col overflow-hidden reveal stagger-2">
            {if projectId {
                <JmsProject pid={projectId} onBack={backToProjects} />
                skip;
            }}
            {if not projectId {
                <JmsProjects onOpen={openProject} />
                skip;
            }}
        </div>
    </div>;
}
