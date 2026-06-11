"use client";
import { Segmented } from "@/components/shared/field";
import { StatTile } from "@/components/shared/stat-tile";
import { MultiLineChart } from "@/components/shared/multi-line-chart";
import { RunDetail } from "./run-detail";
import type { CompareResult, RunMetrics, Session } from "@/lib/api-train";

interface HistoryTabProps {
  compare: CompareResult | null;
  compareMode: "sft" | "dpo";
  onSetCompareMode: (mode: "sft" | "dpo") => void;
  historyView: "runs" | "compare";
  onSetHistoryView: (v: "runs" | "compare") => void;
  historySel: { name: string; mode: string } | null;
  onPickHistorySession: (name: string, mode: string) => void;
  historyMetrics: RunMetrics | null;
  sessions: Session[];
}

export function HistoryTab({
  compare,
  compareMode,
  onSetCompareMode,
  historyView,
  onSetHistoryView,
  historySel,
  onPickHistorySession,
  historyMetrics,
  sessions,
}: HistoryTabProps) {
  const hasData = compare && compare.names.length > 0;

  // Non-running sessions for the current mode
  const pastSessions = sessions.filter(
    (s) => s.mode === compareMode && s.status !== "running"
  );

  return (
    <div className="flex flex-col gap-4 p-4 h-full min-h-0 overflow-y-auto">
      {/* Top row: view toggle + (in runs view) mode filter */}
      <div className="flex items-center gap-3 flex-wrap">
        <Segmented
          options={["runs", "compare"]}
          value={historyView}
          onChange={(v) => onSetHistoryView(v as "runs" | "compare")}
        />
        {historyView === "runs" && (
          <Segmented
            options={["sft", "dpo"]}
            value={compareMode}
            onChange={(v) => onSetCompareMode(v as "sft" | "dpo")}
          />
        )}
      </div>

      {historyView === "runs" ? (
        <>
          {/* Session picker */}
          {pastSessions.length > 0 && (
            <div className="flex items-center gap-1 flex-wrap">
              {pastSessions.map((s) => {
                const isActive =
                  historySel?.name === s.name && historySel?.mode === s.mode;
                return (
                  <button
                    key={`${s.name}|${s.mode}`}
                    onClick={() => onPickHistorySession(s.name, s.mode)}
                    className={`font-mono text-[10px] tracking-widest rounded-md border px-3 py-1 transition-colors ${
                      isActive
                        ? "border-neutral-500 bg-[#1a1a1a] text-neutral-100"
                        : "border-neutral-700 text-neutral-500 hover:text-neutral-300"
                    }`}
                  >
                    {`${s.name} · ${s.mode.toUpperCase()}`}
                  </button>
                );
              })}
            </div>
          )}

          {!historyMetrics?.found ? (
            <div className="flex flex-1 items-center justify-center">
              <span className="micro-label">NO RUN DATA</span>
            </div>
          ) : (
            <RunDetail metrics={historyMetrics} live={false} />
          )}
        </>
      ) : (
        /* COMPARE view: existing content unchanged */
        <>
          {/* Mode selector for compare view */}
          <div className="flex items-center gap-3">
            <Segmented
              options={["sft", "dpo"]}
              value={compareMode}
              onChange={(v) => onSetCompareMode(v as "sft" | "dpo")}
            />
          </div>

          {!hasData ? (
            <div className="flex flex-1 items-center justify-center">
              <span className="micro-label">NO PAST RUNS</span>
            </div>
          ) : (
            <>
              {/* Headline stat tiles per run */}
              <div className="flex flex-wrap gap-3">
                {compare.headline.map((h) => (
                  <div key={h.name} className="flex-1 min-w-[160px]">
                    <StatTile
                      label={h.name.toUpperCase()}
                      value={`${h.final_pass}%`}
                      sub={
                        h.has_idiom
                          ? `loss ${h.last_loss} · ${h.idiom_label} ${h.idiom_sim}`
                          : `loss ${h.last_loss} · no idiom data`
                      }
                    />
                  </div>
                ))}
              </div>

              {/* Comparison charts */}
              <div className="grid grid-cols-1 gap-4">
                <MultiLineChart
                  title="LOSS.TRAIN"
                  rows={compare.train}
                  names={compare.names}
                />
                <MultiLineChart
                  title="LOSS.VAL"
                  rows={compare.val}
                  names={compare.names}
                />
                <MultiLineChart
                  title="CURVE.PASS%"
                  rows={compare.curve}
                  names={compare.names}
                />
              </div>
            </>
          )}
        </>
      )}
    </div>
  );
}
