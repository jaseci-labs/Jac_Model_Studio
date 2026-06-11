"use client";
import { StatusGlyph } from "@/components/shared/status-glyph";
import type { EvalRecord, EvalScores } from "@/lib/api-evals";

interface EvalHistoryProps {
  history: EvalRecord[];
  onOpen: (id: number) => void;
  onDelete: (id: number) => void;
}

function headlineScore(record: EvalRecord): string {
  const s = record.scores as EvalScores | null;
  if (!s) return record.status;
  if (record.kind === "probe") {
    return s.test_pass_pct != null ? `${s.test_pass_pct}%` : record.status;
  }
  return s.avg_sim != null ? `sim ${s.avg_sim}` : record.status;
}

function stripModelsPrefix(model: string): string {
  return model.replace(/^models\//, "");
}

export function EvalHistory({ history, onOpen, onDelete }: EvalHistoryProps) {
  return (
    <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
      <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">EVAL.HISTORY</span>

      {history.length === 0 ? (
        <span className="micro-label text-neutral-600">no evals yet</span>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-xs">
            <thead>
              <tr className="border-b border-neutral-800 text-neutral-600">
                <th className="pb-1.5 pr-3 text-left font-normal micro-label">#</th>
                <th className="pb-1.5 pr-3 text-left font-normal micro-label">DATE</th>
                <th className="pb-1.5 pr-3 text-left font-normal micro-label">KIND</th>
                <th className="pb-1.5 pr-3 text-left font-normal micro-label">MODEL</th>
                <th className="pb-1.5 pr-3 text-left font-normal micro-label">HOLDOUT</th>
                <th className="pb-1.5 pr-3 text-left font-normal micro-label">SCORE</th>
                <th className="pb-1.5 pr-3 text-left font-normal micro-label">ST</th>
                <th className="pb-1.5 text-left font-normal micro-label" />
              </tr>
            </thead>
            <tbody>
              {history.map((r) => (
                <tr
                  key={r.id}
                  onClick={() => onOpen(r.id)}
                  className="cursor-pointer border-b border-neutral-900 text-neutral-400 transition-colors hover:bg-[#111] hover:text-neutral-200"
                >
                  <td className="py-1.5 pr-3 font-mono text-neutral-500">{r.id}</td>
                  <td className="py-1.5 pr-3 font-mono whitespace-nowrap">
                    {r.started.slice(0, 16)}
                  </td>
                  <td className="py-1.5 pr-3">{r.kind}</td>
                  <td
                    className="py-1.5 pr-3 max-w-[160px] truncate font-mono"
                    title={r.model}
                  >
                    {stripModelsPrefix(r.model)}
                  </td>
                  <td className="py-1.5 pr-3">{r.holdout}</td>
                  <td className="py-1.5 pr-3 font-mono">{headlineScore(r)}</td>
                  <td className="py-1.5 pr-3">
                    <StatusGlyph status={r.status} showLabel={false} />
                  </td>
                  <td className="py-1.5">
                    <button
                      onClick={(e) => {
                        e.stopPropagation();
                        onDelete(r.id);
                      }}
                      className="micro-label text-neutral-600 transition-colors hover:text-neutral-300"
                    >
                      DEL
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
