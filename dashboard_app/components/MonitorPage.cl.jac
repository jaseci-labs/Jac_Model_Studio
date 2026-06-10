"""Monitor — LIVE. Shows only currently-running training sessions and streams
their metrics in real time (2.5s poll). When a run finishes it drops off here and
appears under History.
"""

sv import from ..services.jobs { Session, list_sessions }
sv import from ..services.runs { RunMetrics, get_run_metrics }
import from .RunCharts { RunCharts }

def:pub MonitorPage() -> JsxElement {
    has sessions: list[Session] = [],
        sel_name: str = "",
        sel_mode: str = "sft",
        metrics: RunMetrics | None = None,
        tick: int = 0;

    async can with [tick] entry {
        s: list[Session] = await list_sessions();
        sessions = s;
        run: list[Session] = [x for x in s if x.status == "running"];
        found: bool = False;
        for x in run {
            if x.name == sel_name and x.mode == sel_mode { found = True; }
        }
        if not found {
            if len(run) > 0 {
                sel_name = run[0].name;
                sel_mode = run[0].mode;
            } else {
                sel_name = "";
                metrics = None;
            }
        }
        if sel_name != "" {
            metrics = await get_run_metrics(sel_name, sel_mode);
        }
        # always live — re-arm a single timer (only [tick] dep, so no extra chains)
        setTimeout(lambda { tick = tick + 1; }, 2500);
    }

    def pick(nm: str, md: str) -> None {
        sel_name = nm;
        sel_mode = md;
    }

    running: list[Session] = [x for x in sessions if x.status == "running"];

    return <div className="dg-page">
        <div className="dg-row dg-mb">
            <span className="dg-status dg-glyph-run">⦿ LIVE</span>
            {for x in running {
                <button key={x.name + x.mode}
                    onClick={lambda (e: MouseEvent) { pick(x.name, x.mode); }}
                    className={"dg-btn dg-btn-primary" if (x.name == sel_name and x.mode == sel_mode) else "dg-btn"}>
                    {x.label}
                </button>
            }}
            <span className="dg-spacer"></span>
            {metrics and <span className="dg-faint">{"ITER " + str(metrics.last_iter)}</span>}
        </div>

        {len(running) == 0 and <div className="dg-panel" style={{"textAlign": "center", "padding": "2.6rem 1rem"}}>
            <span className="dg-panel-label">MONITOR</span>
            <div className="dg-chart-empty" style={{"padding": "0 0 0.5rem"}}>NO ACTIVE RUN</div>
            <div className="dg-faint">Start one on the TRAIN tab — it streams here live. Finished runs live under HISTORY.</div>
        </div>}

        {len(running) > 0 and metrics and <RunCharts metrics={metrics} live={True} />}
    </div>;
}
