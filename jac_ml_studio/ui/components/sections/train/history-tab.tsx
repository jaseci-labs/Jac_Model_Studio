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

const MODE_DESC: Record<string, string> = {
  sft: "supervised finetune · teaches the model to write Jac",
  dpo: "preference tuning · pushes outputs toward idiomatic Jac",
};

// keep in sync with STROKES in multi-line-chart.tsx
const COMPARE_COLORS = ["#7aa2f7", "#d8a657", "#9ec98f", "#b89ce8", "#6fc3b2", "#e08a8a"];

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

  // All finished runs across both modes, grouped for a clear picker
  const pastSessions = sessions.filter((s) => s.status !== "running");

  return (
    <div className="flex flex-col gap-4 p-4 h-full min-h-0 overflow-y-auto">
      {/* Top row: view toggle */}
      <div className="flex items-center gap-3 flex-wrap">
        <Segmented
          options={["runs", "compare"]}
          value={historyView}
          onChange={(v) => onSetHistoryView(v as "runs" | "compare")}
        />
        <span className="stat-line text-neutral-600">
          {historyView === "runs"
            ? "inspect one finished run in detail"
            : "overlay every run of one stage"}
        </span>
      </div>

      {historyView === "runs" ? (
        <>
          {/* Run picker: one card per finished run, mode + meaning visible */}
          {pastSessions.length === 0 ? (
            <div className="flex flex-1 items-center justify-center">
              <span className="micro-label">NO FINISHED RUNS</span>
            </div>
          ) : (
            <>
              <div className="grid grid-cols-2 gap-2 lg:grid-cols-3">
                {pastSessions.map((s) => {
                  const isActive =
                    historySel?.name === s.name && historySel?.mode === s.mode;
                  return (
                    <button
                      key={`${s.name}|${s.mode}`}
                      onClick={() => onPickHistorySession(s.name, s.mode)}
                      className={`relative flex flex-col items-start gap-1 rounded-md border px-3 py-2.5 text-left transition-colors ${
                        isActive
                          ? "border-neutral-500 bg-[#1a1a1a]"
                          : "border-neutral-800 bg-[#0d0d0d] hover:border-neutral-600"
                      }`}
                    >
                      {isActive && (
                        <span className="absolute left-0 top-2 bottom-2 w-[2px] bg-neutral-100" />
                      )}
                      <div className="flex items-baseline gap-2">
                        <span
                          className={`font-mono text-sm ${
                            isActive ? "text-neutral-100" : "text-neutral-300"
                          }`}
                        >
                          {s.name}
                        </span>
                        <span
                          className={`rounded-full border px-2 py-[1px] font-mono text-[9px] tracking-widest ${
                            s.mode === "dpo"
                              ? "border-[#b89ce8]/40 text-[#b89ce8]"
                              : "border-[#7aa2f7]/40 text-[#7aa2f7]"
                          }`}
                        >
                          {s.mode.toUpperCase()}
                        </span>
                      </div>
                      <span className="stat-line leading-snug text-neutral-600">
                        {MODE_DESC[s.mode] ?? s.mode}
                      </span>
                    </button>
                  );
                })}
              </div>

              {!historySel ? (
                <div className="flex flex-1 items-center justify-center">
                  <span className="micro-label">SELECT A RUN ABOVE</span>
                </div>
              ) : !historyMetrics?.found ? (
                <div className="flex flex-1 items-center justify-center">
                  <span className="micro-label">NO RUN DATA</span>
                </div>
              ) : (
                <RunDetail metrics={historyMetrics} live={false} />
              )}
            </>
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
              {/* Headline accuracy tiles per run, color-matched to chart lines */}
              <div className="flex flex-wrap gap-3">
                {compare.headline.map((h, i) => (
                  <div key={h.name} className="flex-1 min-w-[170px]">
                    <StatTile
                      label={`${h.name.toUpperCase()} · ACCURACY`}
                      value={`${h.final_pass}%`}
                      sub={
                        h.has_idiom
                          ? `loss ${h.last_loss} · idiomatic ${h.idiomatic} · sim ${h.idiom_sim}`
                          : `loss ${h.last_loss} · no idiom data`
                      }
                    />
                    <div
                      className="stat-line mt-1 px-3"
                      style={{ color: COMPARE_COLORS[i % COMPARE_COLORS.length] }}
                    >
                      ── this run in the charts
                    </div>
                  </div>
                ))}
              </div>

              {/* Comparison charts */}
              <div className="grid grid-cols-1 gap-4">
                <MultiLineChart
                  title="ACCURACY · TEST-PASS%"
                  rows={compare.curve}
                  names={compare.names}
                />
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
              </div>
            </>
          )}
        </>
      )}
    </div>
  );
}
