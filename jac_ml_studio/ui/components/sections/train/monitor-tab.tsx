"use client";
import { RunDetail } from "./run-detail";
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

  if (running.length === 0) {
    return (
      <div className="flex flex-col flex-1 items-center justify-center gap-1 h-full p-4">
        <span className="micro-label">NO LIVE RUNS</span>
        <span className="stat-line text-neutral-600">
          launch from the LAUNCH tab · finished runs live in HISTORY
        </span>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-4 p-4 h-full min-h-0 overflow-y-auto">
      {/* Top bar: session picker + feed chip */}
      <div className="flex items-center gap-2 flex-wrap justify-between">
        <div className="flex items-center gap-1 flex-wrap">
          {running.map((s) => {
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
        <RunDetail metrics={metrics} live={feed === "live"} />
      )}
    </div>
  );
}
