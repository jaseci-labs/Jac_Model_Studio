"""History — PAST training sessions. Browse any finished run's metrics (snapshot),
and compare runs (gemma vs qwen) overlaid. Live runs live on the Monitor tab."""

sv import from ..services.jobs { Session, list_sessions }
sv import from ..services.runs { RunMetrics, CompareResult, get_run_metrics, compare_runs }
import from .RunCharts { RunCharts }
import from .charts.MultiLineChart { MultiLineChart }
import from .TrainPage { StatusBadge }

glob CMP_COLORS: list[str] = ["#60a5fa", "#f472b6", "#34d399", "#a78bfa", "#22d3ee"];

def:pub HistoryPage() -> JsxElement {
    has sessions: list[Session] = [],
        sel: str = "",
        sel_name: str = "",
        sel_mode: str = "sft",
        metrics: RunMetrics | None = None,
        compare: bool = False,
        cmode: str = "sft",
        cmp: CompareResult | None = None,
        tick: int = 0;

    async can with entry {
        s: list[Session] = await list_sessions();
        past: list[Session] = [x for x in s if x.status != "running"];
        sessions = past;
        if len(past) > 0 and sel == "" {
            sel = past[0].name + "|" + past[0].mode;
            sel_name = past[0].name;
            sel_mode = past[0].mode;
            metrics = await get_run_metrics(past[0].name, past[0].mode);
        }
    }

    async can with [sel_name, sel_mode, tick] entry {
        if sel_name != "" {
            metrics = await get_run_metrics(sel_name, sel_mode);
        }
    }

    async can with [compare, cmode] entry {
        if compare {
            cmp = await compare_runs(cmode);
        }
    }

    def on_select(e: ChangeEvent) {
        v: str = e.target.value;
        sel = v;
        parts: list = v.split("|");
        sel_name = str(parts[0]);
        sel_mode = str(parts[1]) if len(parts) > 1 else "sft";
    }

    def set_cmode(m: str) -> None {
        cmode = m;
    }

    def toggle_compare(e: MouseEvent) {
        compare = not compare;
    }

    chead: list[dict] = cmp.headline if cmp is not None else [];
    cnames: list[str] = cmp.names if cmp is not None else [];
    ctrain: list[dict] = cmp.train if cmp is not None else [];
    cval: list[dict] = cmp.val if cmp is not None else [];
    ccurve: list[dict] = cmp.curve if cmp is not None else [];
    cur_status: str = "";
    for x in sessions {
        if x.name == sel_name and x.mode == sel_mode { cur_status = x.status; }
    }

    return <div className="dg-page">
        <div className="dg-row dg-mb">
            <select value={sel} onChange={on_select} className="dg-select" disabled={compare}>
                {if len(sessions) == 0 {
                    <option key="none" value="">no past runs</option>
                }}
                {for x in sessions {
                    <option key={x.name + x.mode} value={x.name + "|" + x.mode}>{x.label}</option>
                }}
            </select>
            {not compare and cur_status != "" and <StatusBadge status={cur_status} />}
            <button onClick={toggle_compare} className={"dg-btn dg-btn-primary" if compare else "dg-btn"}>
                {"Comparing all runs" if compare else "Compare runs"}
            </button>
            {compare and <div className="dg-seg">
                <button onClick={lambda (e: MouseEvent) { set_cmode("sft"); }} className={"dg-seg-btn dg-active" if cmode == "sft" else "dg-seg-btn"}>SFT</button>
                <button onClick={lambda (e: MouseEvent) { set_cmode("dpo"); }} className={"dg-seg-btn dg-active" if cmode == "dpo" else "dg-seg-btn"}>DPO</button>
            </div>}
        </div>

        {compare and len(chead) > 0 and <div className="dg-stats dg-mb">
            {for (i, h) in enumerate(chead) {
                <div key={str(h["name"])} className="dg-glass dg-stat">
                    <div className="dg-stat-label">
                        <span className="dg-dot" style={{"background": CMP_COLORS[i % len(CMP_COLORS)], "display": "inline-block", "marginRight": "0.4rem"}}></span>
                        {str(h["name"]) + " · " + cmode}
                    </div>
                    <div className="dg-stat-value">{str(h["final_pass"]) + "%"}</div>
                    <div className="dg-stat-sub">{"idiom " + str(h["idiom_sim"]) + " · loss " + str(h["last_loss"])}</div>
                </div>
            }}
        </div>}

        {compare and len(chead) > 0 and <div className="dg-grid">
            <MultiLineChart title="Train loss" data={ctrain} names={cnames} colors={CMP_COLORS} />
            <MultiLineChart title="Val loss" data={cval} names={cnames} colors={CMP_COLORS} />
            <MultiLineChart title="Holdout test-pass % · learning curve" data={ccurve} names={cnames} colors={CMP_COLORS} />
        </div>}

        {not compare and metrics is None and <div className="dg-muted" style={{"padding": "3rem 0"}}>No past runs yet.</div>}
        {not compare and metrics and <RunCharts metrics={metrics} />}
    </div>;
}
