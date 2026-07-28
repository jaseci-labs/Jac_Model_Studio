"""Dynamic section registry — maps component names to mounted section bodies.

New section types register here once; AppShell imports SectionMount instead of
hard-coding a component→import map in the shell.
"""

import from .sections.Chat { Chat }
import from .sections.Train { Train }
import from .sections.Data { Data }
import from .sections.Evals { Evals }
import from .sections.RlData { RlData }
import from .sections.Results { Results }
import from .sections.Generate { Generate }
import from .sections.CptData { CptData }
import from .sections.CptTrain { CptTrain }
import from .sections.CptSftData { CptSftData }
import from .sections.CptSftPlan { CptSftPlan }
import from .sections.Plan { Plan }
import from .sections.Cloud { Cloud }

def:pub SectionMount(
    component: str, workspace: str, defaultModel: str, active: bool
) -> JsxElement {
    if component == "Chat" {
        return <Chat workspace={workspace} defaultModel={defaultModel} />;
    }
    if component == "Data" { return <Data />; }
    if component == "RlData" { return <RlData />; }
    if component == "CptData" { return <CptData />; }
    if component == "CptSftData" { return <CptSftData />; }
    if component == "CptSftPlan" { return <CptSftPlan />; }
    if component == "Train" { return <Train active={active} />; }
    if component == "CptTrain" { return <CptTrain active={active} />; }
    if component == "Evals" { return <Evals />; }
    if component == "Results" { return <Results />; }
    if component == "Generate" { return <Generate />; }
    # Plan is workspace-scoped: it holds ONE workspace's hand-transcribed doc and
    # must know where it is mounted, or it shows CPT content on 01/02.
    if component == "Plan" { return <Plan workspace={workspace} />; }
    if component == "Cloud" { return <Cloud active={active} />; }
    return <div className="flex flex-1 items-center justify-center">
        <span className="micro-label text-muted-foreground/80">UNKNOWN SECTION {component}</span>
    </div>;
}
