"""Dynamic section registry — maps component names to mounted section bodies.

New section types register here once; AppShell imports SectionMount instead of
hard-coding a component→import map in the shell. Must match
workspace.sv.jac SECTION_TYPES.
"""

import from .sections.Chat { Chat }
import from .sections.Data { Data }
import from .sections.Cloud { Cloud }

def:pub SectionMount(
    component: str, workspace: str, defaultModel: str, active: bool
) -> JsxElement {
    if component == "Chat" {
        return <Chat workspace={workspace} defaultModel={defaultModel} />;
    }
    if component == "Data" { return <Data />; }
    if component == "Cloud" { return <Cloud active={active} />; }
    return <div className="flex flex-1 items-center justify-center">
        <span className="micro-label text-muted-foreground/80">UNKNOWN SECTION {component}</span>
    </div>;
}
