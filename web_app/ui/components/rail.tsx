"use client";
import { useState } from "react";
import { Slider } from "@/components/ui/slider";
import type { PromptCategory, Sampling, Stats } from "@/lib/api";

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="mb-4">
      <div className="micro-label dashed-rule mb-2 pt-2">{title}</div>
      {children}
    </div>
  );
}

export function Rail(props: {
  prompts: PromptCategory[];
  sampling: Sampling;
  lastStats: Stats | null;
  collapsed: boolean;
  onSampling: (s: Sampling) => void;
  onPick: (text: string) => void;
  onToggle: () => void;
}) {
  const [open, setOpen] = useState<string | null>("py2jac");
  if (props.collapsed) {
    return (
      <button
        onClick={props.onToggle}
        className="micro-label border-l border-neutral-800 px-1.5 hover:text-neutral-300"
        title="expand"
      >
        ⟨
      </button>
    );
  }
  return (
    <aside className="flex w-64 shrink-0 flex-col overflow-y-auto border-l border-neutral-800 bg-[#0d0d0d] p-3">
      <button
        onClick={props.onToggle}
        className="micro-label mb-2 self-end hover:text-neutral-300"
      >
        collapse ⟩
      </button>
      <Section title="PROMPT LIBRARY">
        {props.prompts.map((c) => (
          <div key={c.id} className="mb-1">
            <button
              onClick={() => setOpen(open === c.id ? null : c.id)}
              className="flex w-full justify-between py-1 text-xs text-neutral-300 hover:text-neutral-100"
            >
              <span>
                {open === c.id ? "▾" : "▸"} {c.label}
              </span>
              <span className="font-mono text-[9px] text-neutral-600">
                {c.prompts.length}
              </span>
            </button>
            {open === c.id && (
              <div className="ml-3 space-y-1 border-l border-dashed border-neutral-700 pl-2">
                {c.prompts.map((p, i) => (
                  <button
                    key={i}
                    onClick={() => props.onPick(p)}
                    className="block w-full truncate text-left text-[11px] text-neutral-500 hover:text-neutral-200"
                    title={p}
                  >
                    {p.replace(/\n/g, " ").slice(0, 60)}
                  </button>
                ))}
              </div>
            )}
          </div>
        ))}
      </Section>
      <Section title="SAMPLING">
        {(
          [
            ["temperature", 0, 1.5, 0.05, props.sampling.temperature],
            ["top_p", 0.1, 1, 0.05, props.sampling.top_p],
            ["max_tokens", 128, 4096, 128, props.sampling.max_tokens],
          ] as const
        ).map(([key, min, max, step, val]) => (
          <div key={key} className="mb-3">
            <div className="mb-1 flex justify-between text-[10px] text-neutral-400">
              <span>{key.replace("_", " ")}</span>
              <span className="font-mono">{Number(val.toFixed(2))}</span>
            </div>
            <Slider
              min={min}
              max={max}
              step={step}
              value={[val]}
              onValueChange={(v) => {
                const n = Array.isArray(v) ? v[0] : v;
                if (typeof n === "number" && !Number.isNaN(n)) {
                  props.onSampling({ ...props.sampling, [key]: n });
                }
              }}
            />
          </div>
        ))}
      </Section>
      <Section title="LAST RUN">
        {props.lastStats ? (
          <div className="font-mono text-[10px] leading-relaxed text-neutral-400">
            {props.lastStats.tps.toFixed(0)} tok/s
            <br />
            {props.lastStats.gen_tokens} tokens
            <br />
            Δ {props.lastStats.seconds}s
            {props.lastStats.load_seconds > 0 && (
              <> · load {props.lastStats.load_seconds}s</>
            )}
          </div>
        ) : (
          <p className="font-mono text-[10px] text-neutral-600">no runs yet</p>
        )}
      </Section>
    </aside>
  );
}
