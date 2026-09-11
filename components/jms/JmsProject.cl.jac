"""JmsProject — a single project's detail view (5-stage pipeline).

Left: a vertical stage rail (SOURCES / GENERATE / CURATE / TRAIN / EVAL · CHAT),
each pill carrying a status dot from the project's stage_state; clicking switches
the active stage. Right: all five stage panels are mounted at once and the
inactive ones are hidden (the `hidden` class) so per-stage local state survives a
tab switch. Because they all stay mounted, the three polling stages (GENERATE /
TRAIN / EVAL) take an `active` prop and only poll while they are the visible one.

Loads get_project on entry and passes a `refresh()` helper down to the stages so
a mutation re-pulls the whole project dict (row_stats + stage_state and all); a
failed load swaps the whole view for an error + RETRY instead of a stuck
"LOADING…". `pid` is the project id; `onBack` returns to the project list."""

sv import from ...jms_projects { get_project }
import from .stages.SourcesStage { SourcesStage }
import from .stages.GenerateStage { GenerateStage }
import from .stages.CurateStage { CurateStage }
import from .stages.TrainStage { TrainStage }
import from .stages.EvalStage { EvalStage }

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
        loading: bool = True,
        loadErr: str = "";

    async def refresh -> None {
        try {
            d = await get_project(pid);
            project = d;
            loadErr = "";
        } except Exception {
            # Without this the promise rejects unhandled, `loading` never clears and
            # the user stares at five "LOADING…" panels forever.
            loadErr = "could not load this project — is the server reachable?";
        }
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

    def _panel(sid: str) -> JsxElement {
        # All five panels stay mounted (per-stage local state survives a tab switch),
        # so the polling stages take `active` and only poll when they are the visible one.
        # ponytail: only GENERATE/TRAIN/EVAL take `active` — SOURCES and CURATE have no
        # interval, so wiring the prop through them would be dead weight.
        isActive = stage == sid;
        cls = "min-w-0 flex-1" + ("" if isActive else " hidden");
        if sid == "sources" {
            return <div key={sid} className={cls}>
                {if loading {
                    <span key="loading" className="jms-label">LOADING…</span>
                    skip;
                }}
                {if not loading {
                    <SourcesStage key="stage" project={project} onRefresh={refresh} />
                    skip;
                }}
            </div>;
        }
        if sid == "generate" {
            return <div key={sid} className={cls}>
                {if loading {
                    <span key="loading" className="jms-label">LOADING…</span>
                    skip;
                }}
                {if not loading {
                    <GenerateStage key="stage" project={project} onRefresh={refresh} active={isActive} />
                    skip;
                }}
            </div>;
        }
        if sid == "curate" {
            return <div key={sid} className={cls}>
                {if loading {
                    <span key="loading" className="jms-label">LOADING…</span>
                    skip;
                }}
                {if not loading {
                    <CurateStage key="stage" project={project} onRefresh={refresh} />
                    skip;
                }}
            </div>;
        }
        if sid == "train" {
            return <div key={sid} className={cls}>
                {if loading {
                    <span key="loading" className="jms-label">LOADING…</span>
                    skip;
                }}
                {if not loading {
                    <TrainStage key="stage" project={project} onRefresh={refresh} active={isActive} />
                    skip;
                }}
            </div>;
        }
        return <div key={sid} className={cls}>
            {if loading {
                <span key="loading" className="jms-label">LOADING…</span>
                skip;
            }}
            {if not loading {
                <EvalStage key="stage" project={project} onRefresh={refresh} active={isActive} />
                skip;
            }}
        </div>;
    }

    if loadErr {
        return <div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-3 overflow-hidden p-6">
            <span className="jms-label" style={{"color": "var(--jms-danger)"}}>{loadErr}</span>
            <button className="jms-btn" onClick={lambda e: MouseEvent { loading = True; refresh(); }}>RETRY</button>
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
        <div className="flex min-w-0 flex-1 overflow-y-auto pt-3">
            {# _panel takes a param -> compiles to a props-component; call with a
             # props dict, not positionally (same bug class fixed in JmsProjects.cl.jac).
             [_panel({"sid": str(st["id"])}) for st in STAGES]}
        </div>
    </div>;
}
