"use client";
import { StatTile } from "@/components/shared/stat-tile";
import { MonoChart } from "@/components/shared/mono-chart";
import { LogView } from "@/components/shared/log-view";
import type { RunMetrics } from "@/lib/api-train";

// per-metric chart colors so each panel is identifiable at a glance
const C = {
  loss: "#d8a657",
  lr: "#7aa2f7",
  tps: "#6fc3b2",
  acc: "#9ec98f",
};

export function RunDetail({ metrics, live }: { metrics: RunMetrics; live: boolean }) {
  const lastTrain = metrics.train?.length ? metrics.train[metrics.train.length - 1] : null;
  const lastVal = metrics.val?.length ? metrics.val[metrics.val.length - 1] : null;
  const lastTps = metrics.tps?.length ? metrics.tps[metrics.tps.length - 1] : null;
  const lastAcc = metrics.curve?.length ? metrics.curve[metrics.curve.length - 1] : null;
  const fi = metrics.func_idiom;
  const gi = metrics.graph_idiom;
  const idiomPct = (s: typeof fi) =>
    s.has && s.runs > 0 ? `${Math.round((s.idiomatic / s.runs) * 100)}%` : "·";

  return (
    <>
      {/* Headline accuracy row */}
      <div className="grid grid-cols-4 gap-3">
        <StatTile
          label="ACCURACY · TEST-PASS%"
          value={lastAcc ? `${lastAcc.y}%` : "·"}
          sub="cross-compiled holdout"
        />
        <StatTile label="LAST.ITER" value={metrics.last_iter} />
        <StatTile
          label="FINAL.LOSS"
          value={lastTrain ? lastTrain.y.toFixed(3) : "·"}
          sub={lastVal ? `val ${lastVal.y.toFixed(3)}` : undefined}
        />
        <StatTile label="TOK/S" value={lastTps ? lastTps.y.toFixed(0) : "·"} />
      </div>

      {/* Holdout idiom tiles: function + graph side by side */}
      <div className="grid grid-cols-2 gap-3">
        <StatTile
          label="FUNCTION HOLDOUT · IDIOMATIC"
          value={fi.has ? idiomPct(fi) : "·"}
          sub={
            fi.has
              ? `${fi.idiomatic}/${fi.runs} idiomatic · sim ${fi.avg_sim} · ${fi.total} tasks`
              : "no function-holdout eval"
          }
        />
        <StatTile
          label="GRAPH HOLDOUT · IDIOMATIC"
          value={gi.has ? idiomPct(gi) : "·"}
          sub={
            gi.has
              ? `${gi.idiomatic}/${gi.runs} idiomatic · sim ${gi.avg_sim} · ${gi.total} tasks`
              : "no graph-holdout eval"
          }
        />
      </div>

      {/* Chart grid */}
      <div className="grid grid-cols-2 gap-4">
        <MonoChart
          title="LOSS · train + val"
          data={metrics.train}
          secondary={metrics.val}
          live={live}
          accent={C.loss}
        />
        <MonoChart
          title="LEARNING.RATE"
          data={metrics.lr}
          live={false}
          yFmt={(v) => v.toExponential(0)}
          accent={C.lr}
        />
        <MonoChart title="TOKENS/SEC" data={metrics.tps} live={false} accent={C.tps} />
        <MonoChart
          title="ACCURACY · TEST-PASS%"
          data={metrics.curve}
          live={live}
          accent={C.acc}
        />
      </div>

      {/* Log tail */}
      <LogView text={metrics.log_tail ?? ""} maxH="12rem" />
    </>
  );
}
