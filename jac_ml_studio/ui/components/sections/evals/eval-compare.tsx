"use client";
import type { EvalRecord } from "@/lib/api-evals";

interface EvalCompareProps {
  history: EvalRecord[];
}

type CellValue = { score: number; kind: "probe" | "idiom" } | null;

function headlineNum(r: EvalRecord): number | null {
  const s = r.scores;
  if (!s) return null;
  if (r.kind === "probe") {
    const v = s.test_pass_pct;
    return typeof v === "number" ? v : v != null ? parseFloat(String(v)) : null;
  }
  const v = s.avg_sim;
  return typeof v === "number" ? v : v != null ? parseFloat(String(v)) : null;
}

function formatCell(cell: CellValue): string {
  if (!cell) return "—";
  if (cell.kind === "probe") return `${cell.score}%`;
  return `sim ${cell.score}`;
}

function stripModelsPrefix(model: string): string {
  return model.replace(/^models\//, "");
}

export function EvalCompare({ history }: EvalCompareProps) {
  const done = history.filter((r) => r.status === "done");

  if (done.length < 2) {
    return (
      <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
        <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">
          MODEL × HOLDOUT
        </span>
        <span className="micro-label text-neutral-600">need ≥2 completed evals</span>
      </div>
    );
  }

  // Unique models and holdouts
  const models = Array.from(new Set(done.map((r) => r.model)));
  const holdouts: Array<"function" | "graph"> = ["function", "graph"];

  // Build pivot: model → holdout → latest done eval cell
  const pivot: Record<string, Record<string, CellValue>> = {};
  for (const model of models) {
    pivot[model] = { function: null, graph: null };
    for (const holdout of holdouts) {
      // Find latest matching eval (history is ordered DESC by id)
      const match = done.find(
        (r) => r.model === model && r.holdout === holdout
      );
      if (match) {
        const score = headlineNum(match);
        if (score != null) {
          pivot[model][holdout] = { score, kind: match.kind as "probe" | "idiom" };
        }
      }
    }
  }

  // Best probe pass% per column (for highlight)
  const bestPerCol: Record<string, number> = {};
  for (const holdout of holdouts) {
    let best: number | null = null;
    for (const model of models) {
      const cell = pivot[model][holdout];
      if (cell?.kind === "probe" && (best === null || cell.score > best)) {
        best = cell.score;
      }
    }
    if (best !== null) bestPerCol[holdout] = best;
  }

  // For columns with no probe scores, highlight the lowest avg_sim idiom cell
  const bestIdiomPerCol: Record<string, number> = {};
  for (const holdout of holdouts) {
    if (bestPerCol[holdout] != null) continue; // probe column already handled
    let best: number | null = null;
    for (const model of models) {
      const cell = pivot[model][holdout];
      if (cell?.kind === "idiom" && (best === null || cell.score < best)) {
        best = cell.score;
      }
    }
    if (best !== null) bestIdiomPerCol[holdout] = best;
  }

  return (
    <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
      <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">
        MODEL × HOLDOUT
      </span>

      <div className="overflow-x-auto">
        <table className="w-full text-xs">
          <thead>
            <tr className="border-b border-neutral-800 text-neutral-600">
              <th className="pb-1.5 pr-4 text-left font-normal micro-label">MODEL</th>
              {holdouts.map((h) => (
                <th key={h} className="pb-1.5 pr-4 text-left font-normal micro-label">
                  {h.toUpperCase()}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {models.map((model) => (
              <tr
                key={model}
                className="border-b border-neutral-900"
              >
                <td
                  className="py-1.5 pr-4 font-mono text-neutral-500 max-w-[160px] truncate"
                  title={model}
                >
                  {stripModelsPrefix(model)}
                </td>
                {holdouts.map((holdout) => {
                  const cell = pivot[model][holdout];
                  const isBest =
                    (cell?.kind === "probe" &&
                      bestPerCol[holdout] != null &&
                      cell.score === bestPerCol[holdout]) ||
                    (cell?.kind === "idiom" &&
                      bestIdiomPerCol[holdout] != null &&
                      cell.score === bestIdiomPerCol[holdout]);
                  return (
                    <td
                      key={holdout}
                      className={`py-1.5 pr-4 font-mono ${
                        isBest
                          ? "font-semibold text-neutral-100"
                          : "text-neutral-400"
                      }`}
                    >
                      {formatCell(cell)}
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
