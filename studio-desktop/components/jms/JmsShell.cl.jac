"""JmsShell — the JMS product surface.

Top bar: a JMS wordmark that doubles as a breadcrumb (PROJECTS / <NAME> once a
project is open — PROJECTS is clickable to go back), a ◈ HUB return, and the
theme switcher. Body routes on `projectId`: empty → the <JmsProjects/> card grid,
otherwise the <JmsProject/> detail view for that id. The breadcrumb name is
captured from JmsProjects' onOpen(pid, name) callback."""

import from .JmsThemeSwitcher { JmsThemeSwitcher }
import from .JmsProjects { JmsProjects }
import from .JmsProject { JmsProject }

def:pub JmsShell(onHub: any = None, theme: str = "", onTheme: any = None) -> JsxElement {
    has projectId: str = "",
        projectName: str = "";

    t: str = theme if theme else "electric-minimal";

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
                    <button
                        className="jms-label"
                        style={{"cursor": "pointer" if projectId else "default", "background": "transparent", "border": "none", "padding": "0"}}
                        onClick={lambda e: MouseEvent { if projectId { backToProjects(); } }}
                    >PROJECTS</button>
                    {projectId and <span className="jms-label" style={{"color": "var(--jms-fg)"}}>
                        {" / " + projectName}
                    </span>}
                </div>
            </div>
            <div className="flex items-center gap-4">
                <button
                    className="jms-btn"
                    title="back to hub"
                    onClick={lambda e: MouseEvent { if onHub is not None { onHub(); } }}
                >◈ HUB</button>
                <JmsThemeSwitcher theme={t} onTheme={onTheme} />
            </div>
        </div>

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
