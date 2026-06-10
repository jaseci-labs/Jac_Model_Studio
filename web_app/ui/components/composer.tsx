"use client";
import type { PromptCategory } from "@/lib/api";

export function Composer(props: {
  value: string;
  busy: boolean;
  categories: PromptCategory[];
  onChange: (v: string) => void;
  onSend: (text: string) => void;
  onChip: (categoryId: string) => void;
}) {
  return (
    <div className="px-6 pb-4">
      <div className="mb-2 flex gap-1.5">
        {props.categories.map((c) => (
          <button
            key={c.id}
            onClick={() => props.onChip(c.id)}
            className="rounded-full border border-dashed border-neutral-600 px-2.5 py-0.5 font-mono text-[9px] text-neutral-400 hover:border-neutral-400 hover:text-neutral-200"
          >
            {c.id}
          </button>
        ))}
      </div>
      <div className="flex items-end gap-2 rounded-xl border border-neutral-700 bg-[#121212] p-2 focus-within:border-neutral-500">
        <textarea
          value={props.value}
          onChange={(e) => props.onChange(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              props.onSend(props.value);
            }
          }}
          rows={Math.min(8, Math.max(1, props.value.split("\n").length))}
          placeholder="Ask the model…  (Enter to send, Shift+Enter for newline)"
          className="max-h-48 flex-1 resize-none bg-transparent px-2 py-1 text-sm text-neutral-200 outline-none placeholder:text-neutral-600"
        />
        <button
          onClick={() => props.onSend(props.value)}
          disabled={props.busy || !props.value.trim()}
          className="rounded-lg border border-neutral-600 px-3 py-1 font-mono text-[10px] text-neutral-300 hover:border-neutral-400 disabled:opacity-30"
        >
          {props.busy ? "…" : "⏎ SEND"}
        </button>
      </div>
    </div>
  );
}
