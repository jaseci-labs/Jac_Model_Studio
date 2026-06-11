import { LogView } from "@/components/shared/log-view";
import { Segmented } from "@/components/shared/field";

interface AddFormState {
  target: "sft" | "dpo";
  text: string;
  result: { added: number; errors: string[]; total: number } | null;
  busy: boolean;
}

export function AddExamples({
  addForm,
  onSetAddForm,
  onSubmit,
}: {
  addForm: AddFormState;
  onSetAddForm: (updates: Partial<Pick<AddFormState, "target" | "text">>) => void;
  onSubmit: () => void;
}) {
  return (
    <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
      <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">ADD.EXAMPLES</span>

      <div className="flex flex-col gap-3">
        {/* Target selector */}
        <Segmented
          options={["sft", "dpo"]}
          value={addForm.target}
          onChange={(v) => onSetAddForm({ target: v as "sft" | "dpo" })}
        />

        {/* Textarea */}
        <textarea
          rows={6}
          value={addForm.text}
          onChange={(e) => onSetAddForm({ text: e.target.value })}
          placeholder={
            addForm.target === "sft"
              ? `one JSON object per line · sft: {"messages":[...]}`
              : `one JSON object per line · dpo: {"prompt","chosen","rejected"}`
          }
          className="w-full rounded-md border border-neutral-700 bg-[#121212] px-2 py-1.5 font-mono text-xs text-neutral-100 outline-none placeholder:text-neutral-600 focus:border-neutral-500 resize-none"
        />

        {/* Submit */}
        <button
          disabled={addForm.busy || !addForm.text.trim()}
          onClick={onSubmit}
          className="micro-label self-start rounded border border-neutral-600 px-3 py-1.5 text-neutral-300 transition-colors hover:border-neutral-400 hover:text-neutral-100 disabled:cursor-not-allowed disabled:opacity-30"
        >
          {addForm.busy ? "APPENDING…" : "APPEND"}
        </button>

        {/* Result */}
        {addForm.result && (
          <div className="flex flex-col gap-2">
            <div className="stat-line">
              added {addForm.result.added} · total {addForm.result.total}
            </div>
            {addForm.result.errors.length > 0 && (
              <LogView text={addForm.result.errors.join("\n")} maxH="8rem" />
            )}
          </div>
        )}
      </div>
    </div>
  );
}
