"use client";
import { StatTile } from "@/components/shared/stat-tile";
import { MonoChart } from "@/components/shared/mono-chart";
import { LogView } from "@/components/shared/log-view";
import type { Session, RunMetrics } from "@/lib/api-train";

type FeedState = "live" | "stalled" | "nofeed";

interface MonitorTabProps {
  sessions: Session[];
  selected: { name: string; mode: string } | null;
  onPickSession: (name: string, mode: string) => void;
  metrics: RunMetrics | null;
  feed: FeedState;
  stalledFor: number;
}

function FeedChip({ feed, stalledFor }: { feed: FeedState; stalledFor: number }) {
  if (feed === "live") {
    return (
      <span className="font-mono text-[10px] tracking-widest text-neutral-100">
        ⦿ LIVE
      </span>
    );
  }
  if (feed === "stalled") {
    return (
      <span className="font-mono text-[10px] tracking-widest text-neutral-400">
        ⦿ STALLED {stalledFor}s
      </span>
    );
  }
  return (
    <span className="font-mono text-[10px] tracking-widest text-neutral-600">
      ○ NO FEED
    </span>
  );
}

export function MonitorTab({
  sessions,
  selected,
  onPickSession,
  metrics,
  feed,
  stalledFor,
}: MonitorTabProps) {
  const running = sessions.filter((s) => s.status === "running");
  const displaySessions = running.length > 0 ? running : sessions;

  const lastTrain = metrics?.train?.length
    ? metrics.train[metrics.train.length - 1]
    : null;
  const lastVal = metrics?.val?.length
    ? metrics.val[metrics.val.length - 1]
    : null;
  const lastTps = metrics?.tps?.length
    ? metrics.tps[metrics.tps.length - 1]
    : null;

  const isLive = feed === "live";

  return (
    <div className="flex flex-col gap-4 p-4 h-full min-h-0 overflow-y-auto">
      {/* Top bar: session picker + feed chip */}
      <div className="flex items-center gap-2 flex-wrap justify-between">
        <div className="flex items-center gap-1 flex-wrap">
          {displaySessions.map((s) => {
            const isActive =
              selected?.name === s.name && selected?.mode === s.mode;
            return (
              <button
                key={`${s.name}|${s.mode}`}
                onClick={() => onPickSession(s.name, s.mode)}
                className={`font-mono text-[10px] tracking-widest rounded-md border px-3 py-1 transition-colors ${
                  isActive
                    ? "border-neutral-500 bg-[#1a1a1a] text-neutral-100"
                    : "border-neutral-700 text-neutral-500 hover:text-neutral-300"
                }`}
              >
                {s.label ?? `${s.name}·${s.mode}`}
              </button>
            );
          })}
        </div>
        <FeedChip feed={feed} stalledFor={stalledFor} />
      </div>

      {/* No data */}
      {!metrics?.found ? (
        <div className="flex flex-1 items-center justify-center">
          <span className="micro-label">NO RUN DATA</span>
        </div>
      ) : (
        <>
          {/* Stat tiles row */}
          <div className="grid grid-cols-4 gap-3">
            <StatTile
              label="LAST.ITER"
              value={metrics.last_iter}
            />
            <StatTile
              label="LOSS.TRAIN"
              value={lastTrain ? lastTrain.y.toFixed(3) : "·"}
            />
            <StatTile
              label="LOSS.VAL"
              value={lastVal ? lastVal.y.toFixed(3) : "·"}
            />
            <StatTile
              label="TOK/S"
              value={lastTps ? lastTps.y.toFixed(0) : "·"}
            />
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
            <MonoChart
              title="LOSS"
              data={metrics.train}
              secondary={metrics.val}
              live={isLive}
            />
            <MonoChart
              title="LEARNING.RATE"
              data={metrics.lr}
              live={false}
              yFmt={(v) => v.toExponential(0)}
            />
            <MonoChart
              title="TOKENS/SEC"
              data={metrics.tps}
              live={false}
            />
            <MonoChart
              title="CURVE.TEST-PASS%"
              data={metrics.curve}
              live={isLive}
            />
          </div>

          {/* Log tail */}
          <LogView text={metrics.log_tail ?? ""} maxH="12rem" />
        </>
      )}
    </div>
  );
}
