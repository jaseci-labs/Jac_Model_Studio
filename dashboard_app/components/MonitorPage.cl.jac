"""Monitor: live charts for a selected training run (SFT or DPO).

Polls get_run_metrics on a 2.5s self-rearming timer while auto-refresh is on, so a
running mlx_lm.lora job's train.log streams into the charts as it grows.
"""

sv import from ..services.runs { RunSummary, RunMetrics, CompareResult, list_runs, get_run_metrics, compare_runs }
import from .charts.MetricChart { MetricChart }
import from .charts.MultiLineChart { MultiLineChart }

glob CMP_COLORS: list[str] = ["#60a5fa", "#f472b6", "#34d399", "#a78bfa", "#22d3ee"];

def:pub StatCard(label: str, value: str, sub: str) -> JsxElement {
    return <div className="dg-glass dg-stat">
        <div className="dg-stat-label">{label}</div>
        <div className="dg-stat-value">{value}</div>
        {sub != "" and <div className="dg-stat-sub">{sub}</div>}
    </div>;
}

def:pub MonitorPage() -> JsxElement {
    has runs: list[RunSummary] = [],
        metrics: RunMetrics | None = None,
        cmp: CompareResult | None = None,
        compare: bool = False,
        name: str = "",
        mode: str = "sft",
        auto: bool = True,
        tick: int = 0;

    async can with entry {
        # use a LOCAL for the fetched list: assigning `runs` (state) doesn't update
        # it synchronously, so reading `runs` here would see the stale [] and skip.
        found: list[RunSummary] = await list_runs();
        runs = found;
        if len(found) > 0 and name == "" {
            name = found[0].name;
            metrics = await get_run_metrics(found[0].name, mode);
        }
    }

    async can with [name, mode, tick] entry {
        if name != "" {
            metrics = await get_run_metrics(name, mode);
            if auto {
                schedule_next();
            }
        }
    }

    async can with [compare, mode, tick] entry {
        if compare {
            cmp = await compare_runs(mode);
        }
    }

    def schedule_next -> None {
        setTimeout(lambda { tick = tick + 1; }, 2500);
    }

    def pick_mode(m: str) -> None {
        mode = m;
    }

    def on_select(e: ChangeEvent) {
        name = e.target.value;
    }

    def toggle_auto(e: MouseEvent) {
        auto = not auto;
        if auto {
            tick = tick + 1;
        }
    }

    def refresh(e: MouseEvent) {
        tick = tick + 1;
    }

    def toggle_compare(e: MouseEvent) {
        compare = not compare;
        tick = tick + 1;
    }

    # non-optional locals so the compare JSX (incl. nested for-slots) needn't
    # narrow the optional `cmp` — the checker won't track that into slot scope.
    chead: list[dict] = cmp.headline if cmp is not None else [];
    cnames: list[str] = cmp.names if cmp is not None else [];
    ctrain: list[dict] = cmp.train if cmp is not None else [];
    cval: list[dict] = cmp.val if cmp is not None else [];
    ccurve: list[dict] = cmp.curve if cmp is not None else [];

    return <div className="dg-page">
        <div className="dg-row dg-mb">
            <select value={name} onChange={on_select} className="dg-select">
                {if len(runs) == 0 {
                    <option key="none" value="">no runs found</option>
                }}
                {for r in runs {
                    <option key={r.name} value={r.name}>{r.name}</option>
                }}
            </select>
            <div className="dg-seg">
                <button onClick={lambda (e: MouseEvent) { pick_mode("sft"); }} className={"dg-seg-btn dg-active" if mode == "sft" else "dg-seg-btn"}>SFT</button>
                <button onClick={lambda (e: MouseEvent) { pick_mode("dpo"); }} className={"dg-seg-btn dg-active" if mode == "dpo" else "dg-seg-btn"}>DPO</button>
            </div>
            <button onClick={refresh} className="dg-btn">Refresh</button>
            <button onClick={toggle_auto} className="dg-btn">
                <span className={"dg-dot dg-dot-run" if auto else "dg-dot dg-dot-idle"}></span>
                {"Auto on" if auto else "Auto off"}
            </button>
            <button onClick={toggle_compare} className={"dg-btn dg-btn-primary" if compare else "dg-btn"}>
                {"Comparing all runs" if compare else "Compare runs"}
            </button>
            <span className="dg-spacer"></span>
            {not compare and metrics and <span className="dg-faint">{"iter " + str(metrics.last_iter)}</span>}
        </div>

        {compare and len(chead) > 0 and <div className="dg-stats dg-mb">
            {for (i, h) in enumerate(chead) {
                <div key={str(h["name"])} className="dg-glass dg-stat">
                    <div className="dg-stat-label">
                        <span className="dg-dot" style={{"background": CMP_COLORS[i % len(CMP_COLORS)], "display": "inline-block", "marginRight": "0.4rem"}}></span>
                        {str(h["name"]) + " · " + mode}
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

        {not compare and metrics is None and <div className="dg-muted" style={{"padding": "3rem 0"}}>Select a run.</div>}

        {not compare and metrics and metrics.has_idiom and <div className="dg-stats dg-mb">
            <StatCard label="idiom avg-sim" value={str(metrics.idiom_avg_sim)} sub={metrics.idiom_label} />
            <StatCard label="idiomatic" value={str(metrics.idiom_idiomatic)} sub="diverged from transpile" />
            <StatCard label="python-shaped" value={str(metrics.idiom_python)} sub="reproduced transpile" />
            <StatCard label="runs / total" value={str(metrics.idiom_runs) + " / " + str(metrics.idiom_total)} sub="behavioral pass" />
        </div>}

        {not compare and metrics and <div className="dg-grid">
            <MetricChart title="Train loss" data={metrics.train} color="#60a5fa" />
            <MetricChart title="Val loss" data={metrics.val} color="#f472b6" />
            <MetricChart title="Holdout test-pass % · learning curve" data={metrics.curve} color="#34d399" />
            <MetricChart title="Learning rate" data={metrics.lr} color="#a78bfa" />
            <MetricChart title="Tokens / sec" data={metrics.tps} color="#22d3ee" />
            {len(metrics.idiom_sim) > 0 and <MetricChart title="Idiom transpile-similarity" data={metrics.idiom_sim} color="#fbbf24" />}
        </div>}

        {not compare and metrics and <div className="dg-mb-lg" style={{"marginTop": "1.2rem"}}>
            <div className="dg-title">train.log · tail</div>
            <pre className="dg-log" style={{"maxHeight": "220px"}}>{metrics.log_tail if metrics.log_tail != "" else "(no log yet)"}</pre>
        </div>}
    </div>;
}
