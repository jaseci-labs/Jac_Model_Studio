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
    if component == "Train" { return <Train active={active} />; }
    if component == "CptTrain" { return <CptTrain active={active} />; }
    if component == "Evals" { return <Evals />; }
    if component == "Results" { return <Results />; }
    if component == "Generate" { return <Generate />; }
    if component == "Plan" { return <Plan />; }
    if component == "Cloud" { return <Cloud active={active} />; }
    return <div className="flex flex-1 items-center justify-center">
        <span className="micro-label text-neutral-600">UNKNOWN SECTION {component}</span>
    </div>;
}
