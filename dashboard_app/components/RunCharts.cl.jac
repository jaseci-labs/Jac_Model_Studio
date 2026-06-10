"""Shared render of one run's metrics: HUD stat tiles + chart grid + LOG.TAIL.
Used by Monitor (live) and History (past snapshot)."""

sv import from ..services.runs { RunMetrics }
import from .charts.MetricChart { MetricChart }
import from .hud.Hud { BracketTile, LogView }

def last_y(series: list[dict]) -> str {
    if len(series) == 0 { return "n/a"; }
    return str(series[len(series) - 1]["y"]);
}

def loss_trend(series: list[dict]) -> list[str] {
    # [label, accent-class] from the last two points of a loss series.
    if len(series) < 2 { return ["", ""]; }
    a: float = float(str(series[len(series) - 2]["y"]));
    b: float = float(str(series[len(series) - 1]["y"]));
    if b < a { return ["▼ CONVERGING", "dg-acc-green"]; }
    if b > a { return ["▲ RISING", "dg-acc-amber"]; }
    return ["HOLDING", ""];
}

def pass_trend(series: list[dict]) -> list[str] {
    if len(series) < 2 { return ["", ""]; }
    a: float = float(str(series[len(series) - 2]["y"]));
    b: float = float(str(series[len(series) - 1]["y"]));
    if b >= a { return ["▲ NOMINAL", "dg-acc-green"]; }
    return ["▼ REGRESSING", "dg-acc-amber"];
}

def:pub RunCharts(metrics: RunMetrics, live: bool) -> JsxElement {
    trn_t: list[str] = loss_trend(metrics.train);
    val_t: list[str] = loss_trend(metrics.val);
    pas_t: list[str] = pass_trend(metrics.curve);
    return <div>
        <div className="dg-stats dg-mb">
            <BracketTile label="PASS.RATE" value={last_y(metrics.curve) + "%"} sub={pas_t[0]} subcls={pas_t[1]} />
            <BracketTile label="LOSS.TRN" value={last_y(metrics.train)} sub={trn_t[0]} subcls={trn_t[1]} />
            <BracketTile label="LOSS.VAL" value={last_y(metrics.val)} sub={val_t[0]} subcls={val_t[1]} />
            <BracketTile label="TOK.S" value={last_y(metrics.tps)} sub={"ITER " + str(metrics.last_iter)} subcls="" />
        </div>

        {metrics.has_idiom and <div className="dg-stats dg-mb">
            <BracketTile key="a" label="IDIOM.SIM" value={str(metrics.idiom_avg_sim)} sub={metrics.idiom_label} subcls="" />
            <BracketTile key="b" label="IDIOMATIC" value={str(metrics.idiom_idiomatic)} sub="DIVERGED FROM TRANSPILE" subcls="" />
            <BracketTile key="c" label="PY.SHAPED" value={str(metrics.idiom_python)} sub="REPRODUCED TRANSPILE" subcls="" />
            <BracketTile key="d" label="RUNS.TOTAL" value={str(metrics.idiom_runs) + " / " + str(metrics.idiom_total)} sub="BEHAVIORAL PASS" subcls="" />
        </div>}

        <div className="dg-grid">
            <MetricChart title="LOSS.TRAIN" data={metrics.train} color="#fff" live={live} />
            <MetricChart title="LOSS.VAL" data={metrics.val} color="#fff" live={live} />
            <MetricChart title="CURVE.PASS" data={metrics.curve} color="#fff" live={live} />
            <MetricChart title="LR" data={metrics.lr} color="#fff" live={False} />
            <MetricChart title="TOK.S" data={metrics.tps} color="#fff" live={False} />
            {len(metrics.idiom_sim) > 0 and <MetricChart title="IDIOM.SIM" data={metrics.idiom_sim} color="#fff" live={False} />}
        </div>

        <div className="dg-panel dg-mb-lg" style={{"marginTop": "1.4rem"}}>
            <span className="dg-panel-label">LOG.TAIL</span>
            <LogView text={metrics.log_tail if metrics.log_tail != "" else "(no log yet)"} maxh="220px" />
        </div>
    </div>;
}
