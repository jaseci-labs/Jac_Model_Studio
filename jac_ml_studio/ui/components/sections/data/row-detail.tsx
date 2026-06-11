import { CodeBlock } from "@/components/shared/code-block";
import type { DataRow } from "@/lib/api-data";

export function RowDetail({ row }: { row: DataRow }) {
  return (
    <div className="rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 space-y-2">
      {/* Prompt */}
      {row.prompt && (
        <div>
          <div className="micro-label mb-1 text-neutral-600">PROMPT</div>
          <pre className="whitespace-pre-wrap font-mono text-xs text-neutral-400 leading-relaxed">
            {row.prompt}
          </pre>
        </div>
      )}

      {/* Python source */}
      {row.python && <CodeBlock lang="python" code={row.python} />}

      {/* Jac output (SFT) */}
      {row.jac && row.kind !== "dpo" && <CodeBlock lang="jac" code={row.jac} />}

      {/* DPO chosen / rejected */}
      {row.kind === "dpo" && (
        <>
          {row.chosen && <CodeBlock lang="jac" label="CHOSEN.JAC" code={row.chosen} />}
          {row.rejected && <CodeBlock lang="jac" label="REJECTED.JAC" code={row.rejected} />}
        </>
      )}

      {/* Raw fallback */}
      {row.kind === "raw" && row.raw && (
        <pre className="overflow-x-auto font-mono text-xs text-neutral-400 leading-relaxed whitespace-pre">
          {row.raw}
        </pre>
      )}
    </div>
  );
}
