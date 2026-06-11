"use client";
import { StatTile } from "@/components/shared/stat-tile";
import { MonoChart } from "@/components/shared/mono-chart";
import { LogView } from "@/components/shared/log-view";
import type { RunMetrics } from "@/lib/api-train";

export function RunDetail({ metrics, live }: { metrics: RunMetrics; live: boolean }) {
  const lastTrain = metrics.train?.length ? metrics.train[metrics.train.length - 1] : null;
  const lastVal = metrics.val?.length ? metrics.val[metrics.val.length - 1] : null;
  const lastTps = metrics.tps?.length ? metrics.tps[metrics.tps.length - 1] : null;

  return (
    <>
      {/* Stat tiles row */}
      <div className="grid grid-cols-4 gap-3">
        <StatTile label="LAST.ITER" value={metrics.last_iter} />
        <StatTile label="LOSS.TRAIN" value={lastTrain ? lastTrain.y.toFixed(3) : "·"} />
        <StatTile label="LOSS.VAL" value={lastVal ? lastVal.y.toFixed(3) : "·"} />
        <StatTile label="TOK/S" value={lastTps ? lastTps.y.toFixed(0) : "·"} />
      </div>

      {/* Idiom tile if present */}
      {metrics.has_idiom && (
        <div className="grid grid-cols-1 gap-3">
          <StatTile
            label={metrics.idiom_label}
            value={`${metrics.idiom_idiomatic}/${metrics.idiom_runs} idiomatic`}
            sub={`sim ${metrics.idiom_avg_sim}`}
          />
        </div>
      )}

      {/* Chart grid */}
      <div className="grid grid-cols-2 gap-4">
        <MonoChart title="LOSS" data={metrics.train} secondary={metrics.val} live={live} />
        <MonoChart
          title="LEARNING.RATE"
          data={metrics.lr}
          live={false}
          yFmt={(v) => v.toExponential(0)}
        />
        <MonoChart title="TOKENS/SEC" data={metrics.tps} live={false} />
        <MonoChart title="CURVE.TEST-PASS%" data={metrics.curve} live={live} />
      </div>

      {/* Log tail */}
      <LogView text={metrics.log_tail ?? ""} maxH="12rem" />
    </>
  );
}
