"use client";
import { Segmented } from "@/components/shared/field";
import { StatTile } from "@/components/shared/stat-tile";
import { MultiLineChart } from "@/components/shared/multi-line-chart";
import type { CompareResult } from "@/lib/api-train";

interface HistoryTabProps {
  compare: CompareResult | null;
  compareMode: "sft" | "dpo";
  onSetCompareMode: (mode: "sft" | "dpo") => void;
}

export function HistoryTab({
  compare,
  compareMode,
  onSetCompareMode,
}: HistoryTabProps) {
  const hasData = compare && compare.names.length > 0;

  return (
    <div className="flex flex-col gap-4 p-4 h-full min-h-0 overflow-y-auto">
      {/* Mode selector */}
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
    </div>
  );
}
