"""Monitor LIVE: streams currently running training sessions in real time (2.5s poll).

The feed chip reflects actual telemetry state: LIVE while iters advance, STALLED
when the trainer stops emitting (no iter progress for ~30s), PAUSED when the user
suspends polling. Finished runs drop off here and appear under History.
"""

sv import from ..services.jobs { Session, list_sessions }
sv import from ..services.runs { RunMetrics, get_run_metrics }
import from .RunCharts { RunCharts }

# 12 polls x 2.5s = 30s without iter progress counts as a stalled feed.
glob STALL_POLLS: int = 12;

def:pub MonitorPage() -> JsxElement {
    has sessions: list[Session] = [],
        sel_name: str = "",
        sel_mode: str = "sft",
        metrics: RunMetrics | None = None,
        paused: bool = False,
        seen_iter: int = -1,
        stale: int = 0,
        tick: int = 0;

    async can with [tick] entry {
        if not paused {
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
                    seen_iter = -1;
                    stale = 0;
                }
            }
            if sel_name != "" {
                # LOCAL for the fetched metrics: state assignment is async, so the
                # freshness compare below must read the local, not the stale state.
                m: RunMetrics = await get_run_metrics(sel_name, sel_mode);
                metrics = m;
                if m.last_iter != seen_iter {
                    seen_iter = m.last_iter;
                    stale = 0;
                } else {
                    stale = stale + 1;
                }
            }
        }
        # re-arm a single timer (only [tick] dep, so no extra chains)
        setTimeout(lambda { tick = tick + 1; }, 2500);
    }

    def pick(nm: str, md: str) -> None {
        sel_name = nm;
        sel_mode = md;
        seen_iter = -1;
        stale = 0;
    }

    def toggle_pause(e: MouseEvent) {
        paused = not paused;
    }

    running: list[Session] = [x for x in sessions if x.status == "running"];
    stalled: bool = stale >= STALL_POLLS;
    is_live: bool = (not paused) and (not stalled);

    feed: str = "⦿ LIVE";
    feedcls: str = "dg-status dg-glyph-run";
    if len(running) == 0 {
        feed = "○ NO FEED";
        feedcls = "dg-status dg-glyph-idle";
    }
    if stalled and len(running) > 0 {
        feed = "⦿ STALLED " + str(int(stale * 2.5)) + "s";
        feedcls = "dg-status dg-acc-amber";
    }
    if paused {
        feed = "○ PAUSED";
        feedcls = "dg-status dg-glyph-idle";
    }

    return <div className="dg-page">
        <div className="dg-row dg-mb">
            <span className={feedcls}>{feed}</span>
            <button onClick={toggle_pause} className="dg-btn">{"RESUME" if paused else "PAUSE"}</button>
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
            <div className="dg-faint">Start one on the TRAIN tab and it streams here live. Finished runs live under HISTORY.</div>
        </div>}

        {len(running) > 0 and metrics and <RunCharts metrics={metrics} live={is_live} />}
    </div>;
}
