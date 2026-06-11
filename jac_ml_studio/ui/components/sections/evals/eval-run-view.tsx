"use client";
import { StatTile } from "@/components/shared/stat-tile";
import { StatusGlyph } from "@/components/shared/status-glyph";
import { LogView } from "@/components/shared/log-view";
import type { EvalDetail } from "@/lib/api-evals";

interface EvalRunViewProps {
  run: EvalDetail | null;
  onStop: () => void;
}

function ProbeScores({ scores }: { scores: Record<string, number | string> }) {
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
      <StatTile
        label="TEST.PASS%"
        value={scores.test_pass_pct != null ? `${scores.test_pass_pct}` : "·"}
      />
      <StatTile
        label="RUNS%"
        value={scores.runs_pct != null ? `${scores.runs_pct}` : "·"}
      />
      <StatTile
        label="TOK/CORRECT"
        value={scores.tokens_to_correct != null ? `${scores.tokens_to_correct}` : "·"}
      />
      <StatTile
        label="EVAL.TPS"
        value={scores.eval_tps != null ? `${scores.eval_tps}` : "·"}
      />
    </div>
  );
}

function IdiomScores({ scores }: { scores: Record<string, number | string> }) {
  const idiomatic = scores.idiomatic ?? "·";
  const runs = scores.runs ?? "·";
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
      <StatTile
        label="AVG.SIM"
        value={scores.avg_sim != null ? `${scores.avg_sim}` : "·"}
      />
      <StatTile
        label="IDIOMATIC"
        value={idiomatic !== "·" && runs !== "·" ? `${idiomatic}/${runs}` : "·"}
      />
      <StatTile
        label="PY.SHAPED"
        value={scores.python_shaped != null ? `${scores.python_shaped}` : "·"}
      />
      <StatTile
        label="FEAT"
        value={scores.avg_feat != null ? `${scores.avg_feat}` : "·"}
      />
    </div>
  );
}

export function EvalRunView({ run, onStop }: EvalRunViewProps) {
  return (
    <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
      <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">EVAL.RUN</span>

      {!run ? (
        <span className="micro-label text-neutral-600">NO ACTIVE EVAL</span>
      ) : (
        <div className="flex flex-col gap-4">
          {/* Header row */}
          <div className="flex items-center justify-between gap-3">
            <div className="flex items-center gap-3 min-w-0">
              <StatusGlyph status={run.status} />
              <span className="font-mono text-xs text-neutral-300 truncate">
                #{run.id} {run.kind} · {run.model.replace(/^models\//, "")} · {run.holdout}
              </span>
            </div>
            {run.status === "running" && (
              <button
                onClick={onStop}
                className="shrink-0 rounded-md border border-neutral-700 px-3 py-1 text-xs text-neutral-400 transition-colors hover:border-neutral-500 hover:text-neutral-200"
              >
                STOP
              </button>
            )}
          </div>

          {/* Scores */}
          {run.scores && (
            run.kind === "probe" ? (
              <ProbeScores scores={run.scores} />
            ) : (
              <IdiomScores scores={run.scores} />
            )
          )}

          {/* Log */}
          <LogView text={run.log_tail} maxH="16rem" />
        </div>
      )}
    </div>
  );
}
