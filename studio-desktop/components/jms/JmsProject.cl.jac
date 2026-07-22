"""JmsProject — a single project's detail view (5-stage pipeline).

Left: a vertical stage rail (SOURCES / GENERATE / CURATE / TRAIN / EVAL · CHAT),
each pill carrying a status dot from the project's stage_state; clicking switches
the active stage. Right: all five stage panels are mounted at once and the
inactive ones are hidden (the `hidden` class) so per-stage local state survives a
tab switch — only SOURCES is real today; the other four render a quiet
"lands in a later phase" placeholder.

Loads get_project on entry and passes a `refresh()` helper down to SourcesStage
so a source mutation re-pulls the whole project dict (row_stats + stage_state and
all). `pid` is the project id; `onBack` returns to the project list."""

sv import from ...jms_projects { get_project }
import from .stages.SourcesStage { SourcesStage }
import from .stages.GenerateStage { GenerateStage }
import from .stages.CurateStage { CurateStage }

glob STAGES: list[dict] = [
    {"id": "sources", "label": "SOURCES"},
    {"id": "generate", "label": "GENERATE"},
    {"id": "curate", "label": "CURATE"},
    {"id": "train", "label": "TRAIN"},
    {"id": "eval", "label": "EVAL · CHAT"}
];

def:pub JmsProject(pid: str = "", onBack: any = None) -> JsxElement {
    has project: any = None,
        stage: str = "sources",
        loading: bool = True;

    async def refresh -> None {
        d = await get_project(pid);
        project = d;
        loading = False;
    }

    async can with entry {
        await refresh();
    }

    def _stageState(sid: str) -> str {
        if project and "stage_state" in project {
            ss: any = project["stage_state"];
            if sid in ss { return str(ss[sid]); }
        }
        return "empty";
    }

    def _panel(sid: str, label: str) -> JsxElement {
        cls = "min-w-0 flex-1" + ("" if stage == sid else " hidden");
        if sid == "sources" {
            return <div key={sid} className={cls}>
                {if loading {
                    <span className="jms-label">LOADING…</span>
                    skip;
                }}
                {if not loading {
                    <SourcesStage project={project} onRefresh={refresh} />
                    skip;
                }}
            </div>;
        }
        if sid == "generate" {
            return <div key={sid} className={cls}>
                {if loading {
                    <span className="jms-label">LOADING…</span>
                    skip;
                }}
                {if not loading {
                    <GenerateStage project={project} onRefresh={refresh} />
                    skip;
                }}
            </div>;
        }
        if sid == "curate" {
            return <div key={sid} className={cls}>
                {if loading {
                    <span className="jms-label">LOADING…</span>
                    skip;
                }}
                {if not loading {
                    <CurateStage project={project} onRefresh={refresh} />
                    skip;
                }}
            </div>;
        }
        return <div key={sid} className={cls}>
            <div className="jms-section flex items-center justify-center" style={{"minHeight": "220px"}}>
                <span className="jms-label">{label} · lands in a later phase</span>
            </div>
        </div>;
    }

    return <div className="flex min-h-0 flex-1 gap-6 overflow-hidden p-6">
        <div className="jms-rail">
            {for st in STAGES {
                <button
                    key={str(st["id"])}
                    className={"jms-pill" + (" jms-pill-active" if stage == str(st["id"]) else "")}
                    onClick={lambda e: MouseEvent { stage = str(st["id"]); }}
                >
                    <span className={"jms-pill-dot" + (" jms-pill-dot-done" if _stageState(str(st["id"])) == "done" else "")} />
                    <span>{str(st["label"])}</span>
                </button>
            }}
        </div>
        <div className="flex min-w-0 flex-1 overflow-y-auto">
            {[_panel(str(st["id"]), str(st["label"])) for st in STAGES]}
        </div>
    </div>;
}
