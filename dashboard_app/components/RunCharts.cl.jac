"""Shared render of one run's metrics: idiom stat cards + chart grid + log tail.
Used by Monitor (live) and History (past snapshot)."""

sv import from ..services.runs { RunMetrics }
import from .charts.MetricChart { MetricChart }

def:pub StatCard(label: str, value: str, sub: str) -> JsxElement {
    return <div className="dg-glass dg-stat">
        <div className="dg-stat-label">{label}</div>
        <div className="dg-stat-value">{value}</div>
        {sub != "" and <div className="dg-stat-sub">{sub}</div>}
    </div>;
}

def:pub RunCharts(metrics: RunMetrics) -> JsxElement {
    return <div>
        {metrics.has_idiom and <div className="dg-stats dg-mb">
            <StatCard key="a" label="idiom avg-sim" value={str(metrics.idiom_avg_sim)} sub={metrics.idiom_label} />
            <StatCard key="b" label="idiomatic" value={str(metrics.idiom_idiomatic)} sub="diverged from transpile" />
            <StatCard key="c" label="python-shaped" value={str(metrics.idiom_python)} sub="reproduced transpile" />
            <StatCard key="d" label="runs / total" value={str(metrics.idiom_runs) + " / " + str(metrics.idiom_total)} sub="behavioral pass" />
        </div>}

        <div className="dg-grid">
            <MetricChart title="Train loss" data={metrics.train} color="#60a5fa" />
            <MetricChart title="Val loss" data={metrics.val} color="#f472b6" />
            <MetricChart title="Holdout test-pass % · learning curve" data={metrics.curve} color="#34d399" />
            <MetricChart title="Learning rate" data={metrics.lr} color="#a78bfa" />
            <MetricChart title="Tokens / sec" data={metrics.tps} color="#22d3ee" />
            {len(metrics.idiom_sim) > 0 and <MetricChart title="Idiom transpile-similarity" data={metrics.idiom_sim} color="#fbbf24" />}
        </div>

        <div className="dg-mb-lg" style={{"marginTop": "1.2rem"}}>
            <div className="dg-title">train.log · tail</div>
            <pre className="dg-log" style={{"maxHeight": "220px"}}>{metrics.log_tail if metrics.log_tail != "" else "(no log yet)"}</pre>
        </div>
    </div>;
}
