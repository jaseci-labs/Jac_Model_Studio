import { StatusGlyph } from "@/components/shared/status-glyph";
import type { BuilderStatus } from "@/lib/api-data";

const GROUPS: { label: string; stages: string[] }[] = [
  { label: "SEED", stages: ["seed_conversion"] },
  { label: "IDIOM BATCHES", stages: ["idiomatic_batch", "idiomatic_batch2", "idiomatic_batch3"] },
  { label: "SCALE", stages: ["scale_conversion"] },
  { label: "DPO", stages: ["dpo_conversion"] },
  { label: "MANIFEST+SPLITS", stages: ["build_manifest", "build_splits", "build_dpo_splits"] },
  { label: "HOLDOUTS", stages: ["holdout", "graph_holdout"] },
  { label: "AUDIT", stages: ["dataset_stats", "verify_dataset"] },
];

export function PipelineRail({
  builders,
  selectedStage,
  onRun,
  onSelect,
}: {
  builders: BuilderStatus[];
  selectedStage: string | null;
  onRun: (stage: string) => void;
  onSelect: (stage: string) => void;
}) {
  const statusMap = new Map<string, BuilderStatus>(
    builders.map((b) => [b.stage, b])
  );

  return (
    <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
      <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">PIPELINE</span>
      <div className="flex flex-col gap-0.5">
        {GROUPS.map((group) => (
          <div key={group.label} className="mt-2 first:mt-0">
            {/* Group header */}
            <div className="mb-1 flex items-center gap-2">
              <span className="micro-label shrink-0 text-neutral-600">{group.label}</span>
              <div className="dashed-rule flex-1" />
            </div>
            {/* Stages */}
            {group.stages.map((stage) => {
              const b = statusMap.get(stage);
              const status = b?.status ?? "idle";
              const isRunning = status === "running";
              const isSelected = selectedStage === stage;

              return (
                <div key={stage}>
                  <div
                    className={`flex cursor-pointer items-center gap-2 rounded px-2 py-1 ${
                      isSelected ? "bg-[#1a1a1a]" : "hover:bg-[#141414]"
                    }`}
                    onClick={() => onSelect(stage)}
                  >
                    <StatusGlyph status={status} showLabel={false} />
                    <span className="flex-1 truncate font-mono text-xs text-neutral-400">
                      {stage}
                    </span>
                    <button
                      disabled={isRunning}
                      onClick={(e) => {
                        e.stopPropagation();
                        onRun(stage);
                      }}
                      className="micro-label rounded border border-neutral-700 px-1.5 py-0.5 text-neutral-500 transition-colors hover:border-neutral-500 hover:text-neutral-200 disabled:cursor-not-allowed disabled:opacity-30"
                    >
                      RUN
                    </button>
                  </div>
                  {/* Warning under seed_conversion */}
                  {stage === "seed_conversion" && (
                    <div className="stat-line ml-8 mt-0.5 mb-1 border-l-2 border-neutral-600 pl-2">
                      TRUNCATES sft.jsonl→32 · dpo.jsonl→2 — run idiomatic batches after, then downstream stages
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        ))}
      </div>
    </div>
  );
}
