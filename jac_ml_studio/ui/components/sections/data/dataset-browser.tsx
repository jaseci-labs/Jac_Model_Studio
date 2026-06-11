import { RowDetail } from "./row-detail";
import type { FileRef, DataRow } from "@/lib/api-data";

const KIND_LABEL: Record<string, string> = {
  sft: "SFT",
  dpo: "DPO",
  holdout: "HOLD",
  raw: "RAW",
};

export function DatasetBrowser({
  files,
  browser,
  expanded,
  onOpenFile,
  onPage,
  onToggleRow,
}: {
  files: FileRef[];
  browser: { path: string | null; offset: number; rows: DataRow[]; total: number };
  expanded: number | null;
  onOpenFile: (path: string) => void;
  onPage: (dir: 1 | -1) => void;
  onToggleRow: (idx: number) => void;
}) {
  const canPrev = browser.offset > 0;
  const canNext = browser.offset + browser.rows.length < browser.total;

  return (
    <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
      <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">DATASET.BROWSER</span>

      {/* File picker */}
      <div className="mb-3 flex flex-wrap gap-1">
        {files.length === 0 && (
          <span className="stat-line">no files</span>
        )}
        {files.map((f) => (
          <button
            key={f.path}
            onClick={() => onOpenFile(f.path)}
            className={`rounded border px-2 py-0.5 font-mono text-[10px] transition-colors ${
              browser.path === f.path
                ? "border-neutral-500 bg-[#1a1a1a] text-neutral-100"
                : "border-neutral-700 text-neutral-500 hover:text-neutral-300"
            }`}
          >
            {f.label} {f.count}
          </button>
        ))}
      </div>

      {/* Table */}
      {browser.path && (
        <>
          <div className="overflow-x-auto">
            {/* Header */}
            <div className="mb-1 grid grid-cols-[2rem_1fr_3rem_3rem_5rem_1fr] gap-2">
              {["#", "NAME", "KIND", "DIFF", "SOURCE", "PREVIEW"].map((h) => (
                <span key={h} className="micro-label">{h}</span>
              ))}
            </div>

            {browser.rows.length === 0 && (
              <div className="stat-line py-4 text-center">empty</div>
            )}

            {browser.rows.map((row) => (
              <div key={row.idx}>
                <div
                  className="grid cursor-pointer grid-cols-[2rem_1fr_3rem_3rem_5rem_1fr] gap-2 rounded px-0.5 py-1 font-mono text-xs hover:bg-[#141414]"
                  onClick={() => onToggleRow(row.idx)}
                >
                  <span className="text-neutral-600">{row.idx}</span>
                  <span className="truncate text-neutral-300">{row.name}</span>
                  <span className="text-neutral-500">{KIND_LABEL[row.kind] ?? row.kind}</span>
                  <span className="text-neutral-500">{row.difficulty}</span>
                  <span className="truncate text-neutral-500">{row.source}</span>
                  <span className="truncate text-neutral-600">{row.preview}</span>
                </div>
                {expanded === row.idx && (
                  <div className="mb-1">
                    <RowDetail row={row} />
                  </div>
                )}
              </div>
            ))}
          </div>

          {/* Pager */}
          {browser.total > 0 && (
            <div className="mt-3 flex items-center justify-center gap-3 stat-line">
              <button
                disabled={!canPrev}
                onClick={() => onPage(-1)}
                className="disabled:opacity-30 hover:text-neutral-200 transition-colors"
              >
                ← PREV
              </button>
              <span>
                {browser.offset + 1} to {browser.offset + browser.rows.length} of {browser.total}
              </span>
              <button
                disabled={!canNext}
                onClick={() => onPage(1)}
                className="disabled:opacity-30 hover:text-neutral-200 transition-colors"
              >
                NEXT →
              </button>
            </div>
          )}
        </>
      )}

      {!browser.path && (
        <div className="stat-line py-6 text-center">select a file above</div>
      )}
    </div>
  );
}
