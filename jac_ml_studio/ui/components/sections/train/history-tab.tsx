"use client";
import { Segmented } from "@/components/shared/field";
import { MultiLineChart } from "@/components/shared/multi-line-chart";
import { RunDetail } from "./run-detail";
import type { CompareResult, RunMetrics, Session } from "@/lib/api-train";

type Headline = CompareResult["headline"][number];

// Comparison table: metric rows, one run per column. Leader per row is brightened.
function CompareTable({ headline }: { headline: Headline[] }) {
  const pct = (n: number) => `${n}%`;
  const idioPct = (h: Headline, key: "func_idiom" | "graph_idiom") => {
    const s = h[key];
    return s.has && s.runs > 0 ? Math.round((s.idiomatic / s.runs) * 100) : null;
  };
  const rows: {
    label: string;
    get: (h: Headline) => string;
    num: (h: Headline) => number | null;
    best: "max" | "min";
  }[] = [
    { label: "ACCURACY · TEST-PASS%", get: (h) => pct(h.final_pass), num: (h) => h.final_pass, best: "max" },
    { label: "FINAL LOSS", get: (h) => String(h.last_loss), num: (h) => h.last_loss, best: "min" },
    { label: "ITERATIONS", get: (h) => String(h.last_iter), num: (h) => h.last_iter, best: "max" },
    {
      label: "FUNCTION HOLDOUT · IDIOMATIC%",
      get: (h) => { const v = idioPct(h, "func_idiom"); return v == null ? "·" : pct(v); },
      num: (h) => idioPct(h, "func_idiom"),
      best: "max",
    },
    {
      label: "FUNCTION HOLDOUT · SIM",
      get: (h) => (h.func_idiom.has ? String(h.func_idiom.avg_sim) : "·"),
      num: () => null,
      best: "min",
    },
    {
      label: "GRAPH HOLDOUT · IDIOMATIC%",
      get: (h) => { const v = idioPct(h, "graph_idiom"); return v == null ? "·" : pct(v); },
      num: (h) => idioPct(h, "graph_idiom"),
      best: "max",
    },
    {
      label: "GRAPH HOLDOUT · SIM",
      get: (h) => (h.graph_idiom.has ? String(h.graph_idiom.avg_sim) : "·"),
      num: () => null,
      best: "min",
    },
  ];

  const COLORS = ["#7aa2f7", "#d8a657", "#9ec98f", "#b89ce8", "#6fc3b2", "#e08a8a"];

  return (
    <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-5 overflow-x-auto">
      <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">COMPARISON</span>
      <table className="w-full border-collapse font-mono text-xs">
        <thead>
          <tr>
            <th className="micro-label py-2 pr-4 text-left font-normal">METRIC</th>
            {headline.map((h, i) => (
              <th
                key={h.name}
                className="py-2 px-4 text-right font-normal"
                style={{ color: COLORS[i % COLORS.length] }}
              >
                {h.name.toUpperCase()}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            const nums = headline.map(r.num);
            const valid = nums.filter((n): n is number => n != null);
            const leader =
              valid.length > 1
                ? r.best === "max"
                  ? Math.max(...valid)
                  : Math.min(...valid)
                : null;
            return (
              <tr key={r.label} className="border-t border-neutral-800/60">
                <td className="py-1.5 pr-4 text-neutral-500">{r.label}</td>
                {headline.map((h, i) => {
                  const n = nums[i];
                  const isLeader = leader != null && n === leader;
                  return (
                    <td
                      key={h.name}
                      className={`py-1.5 px-4 text-right ${
                        isLeader ? "text-neutral-100 font-semibold" : "text-neutral-400"
                      }`}
                    >
                      {r.get(h)}
                    </td>
                  );
                })}
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

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

  // All finished runs across both modes
  const pastSessions = sessions.filter((s) => s.status !== "running");
  // Unique model names (qwen, gemma) for the model picker
  const models = [...new Set(pastSessions.map((s) => s.name))];
  // Which (model, mode) combos actually have data
  const has = (name: string, mode: string) =>
    pastSessions.some((s) => s.name === name && s.mode === mode);
  const selModel = historySel?.name ?? null;
  const selMode = historySel?.mode ?? "sft";

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
          {/* Run picker: pick a model, then a stage */}
          {pastSessions.length === 0 ? (
            <div className="flex flex-1 items-center justify-center">
              <span className="micro-label">NO FINISHED RUNS</span>
            </div>
          ) : (
            <>
              <div className="flex flex-wrap items-end gap-x-8 gap-y-3">
                {/* Model */}
                <div className="flex flex-col gap-1.5">
                  <span className="micro-label">MODEL</span>
                  <div className="flex gap-2">
                    {models.map((name) => {
                      const active = selModel === name;
                      return (
                        <button
                          key={name}
                          onClick={() => onPickHistorySession(name, selMode)}
                          className={`rounded-md border px-4 py-1.5 font-mono text-xs transition-colors ${
                            active
                              ? "border-neutral-500 bg-[#1a1a1a] text-neutral-100"
                              : "border-neutral-800 text-neutral-400 hover:border-neutral-600 hover:text-neutral-200"
                          }`}
                        >
                          {name}
                        </button>
                      );
                    })}
                  </div>
                </div>

                {/* Stage */}
                <div className="flex flex-col gap-1.5">
                  <span className="micro-label">STAGE</span>
                  <div className="flex gap-2">
                    {(["sft", "dpo"] as const).map((mode) => {
                      const active = selMode === mode;
                      const enabled = selModel ? has(selModel, mode) : true;
                      return (
                        <button
                          key={mode}
                          disabled={!enabled}
                          onClick={() =>
                            onPickHistorySession(selModel ?? models[0], mode)
                          }
                          className={`rounded-md border px-4 py-1.5 font-mono text-xs uppercase tracking-widest transition-colors disabled:opacity-30 ${
                            active
                              ? mode === "dpo"
                                ? "border-[#b89ce8]/50 bg-[#1a1a1a] text-[#b89ce8]"
                                : "border-[#7aa2f7]/50 bg-[#1a1a1a] text-[#7aa2f7]"
                              : "border-neutral-800 text-neutral-400 hover:border-neutral-600 hover:text-neutral-200"
                          }`}
                        >
                          {mode}
                        </button>
                      );
                    })}
                  </div>
                </div>

                {selMode && (
                  <span className="stat-line pb-1.5 text-neutral-600">
                    {MODE_DESC[selMode]}
                  </span>
                )}
              </div>

              {!historySel ? (
                <div className="flex flex-1 items-center justify-center">
                  <span className="micro-label">SELECT A MODEL ABOVE</span>
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
              {/* Comparison table: metrics down the side, runs across the top */}
              <CompareTable headline={compare.headline} />

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
