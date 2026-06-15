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
  const idiomPct =
    metrics.idiom_runs > 0
      ? Math.round((metrics.idiom_idiomatic / metrics.idiom_runs) * 100)
      : null;

  return (
    <>
      {/* Headline accuracy row */}
      <div className="grid grid-cols-4 gap-3">
        <StatTile
          label="ACCURACY · TEST-PASS%"
          value={lastAcc ? `${lastAcc.y}%` : "·"}
          sub="cross-compiled holdout"
        />
        <StatTile
          label="IDIOMATIC%"
          value={idiomPct != null ? `${idiomPct}%` : "·"}
          sub={metrics.has_idiom ? `sim ${metrics.idiom_avg_sim}` : "no idiom data"}
        />
        <StatTile label="LAST.ITER" value={metrics.last_iter} />
        <StatTile
          label="FINAL.LOSS"
          value={lastTrain ? lastTrain.y.toFixed(3) : "·"}
          sub={lastVal ? `val ${lastVal.y.toFixed(3)}` : undefined}
        />
      </div>

      {/* Secondary tiles */}
      <div className="grid grid-cols-4 gap-3">
        <StatTile label="LOSS.TRAIN" value={lastTrain ? lastTrain.y.toFixed(3) : "·"} />
        <StatTile label="LOSS.VAL" value={lastVal ? lastVal.y.toFixed(3) : "·"} />
        <StatTile label="TOK/S" value={lastTps ? lastTps.y.toFixed(0) : "·"} />
        <StatTile
          label="IDIOM.SPLIT"
          value={
            metrics.has_idiom
              ? `${metrics.idiom_idiomatic}/${metrics.idiom_python}`
              : "·"
          }
          sub={metrics.has_idiom ? "idiomatic/py-shaped" : undefined}
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
