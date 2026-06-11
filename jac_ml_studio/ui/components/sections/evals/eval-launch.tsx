"use client";
import { Segmented, TextInput, Field } from "@/components/shared/field";
import type { EvalForm } from "@/lib/use-evals";
import type { ModelsResponse } from "@/lib/api";

interface EvalLaunchProps {
  models: ModelsResponse | null;
  form: EvalForm;
  onForm: (patch: Partial<EvalForm>) => void;
  onStart: () => void;
  busy: boolean;
  error: string | null;
}

export function EvalLaunch({ models, form, onForm, onStart, busy, error }: EvalLaunchProps) {
  const available = models?.models.filter((m) => m.available) ?? [];

  return (
    <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
      <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">EVAL.LAUNCH</span>

      <div className="flex flex-col gap-4">
        {/* Kind toggle */}
        <Field label="KIND">
          <div className="flex flex-col gap-1">
            <Segmented
              options={["probe", "idiom"]}
              value={form.kind}
              onChange={(v) => onForm({ kind: v as "probe" | "idiom" })}
            />
            <span className="stat-line text-neutral-600">
              {form.kind === "probe"
                ? "behavioral test-pass on holdout"
                : "ROUGE vs transpile judge: idiomatic similarity score"}
            </span>
          </div>
        </Field>

        {/* Model picker */}
        <Field label="MODEL">
          <div className="flex flex-col gap-2">
            {available.length > 0 && (
              <div className="flex flex-wrap gap-1">
                {available.map((m) => (
                  <button
                    key={m.id}
                    onClick={() => onForm({ modelId: m.id, modelPath: "" })}
                    className={`rounded-md border px-2 py-1 text-xs transition-colors ${
                      form.modelId === m.id && !form.modelPath
                        ? "border-neutral-500 bg-[#1a1a1a] text-neutral-100"
                        : "border-neutral-700 text-neutral-500 hover:text-neutral-300"
                    }`}
                  >
                    {m.label}
                  </button>
                ))}
              </div>
            )}
            <TextInput
              value={form.modelPath}
              onChange={(v) => onForm({ modelPath: v, modelId: v ? null : form.modelId })}
              placeholder="or model path (models/...)"
              mono
            />
          </div>
        </Field>

        {/* Adapter */}
        <Field label="ADAPTER (optional)">
          <TextInput
            value={form.adapter}
            onChange={(v) => onForm({ adapter: v })}
            placeholder="e.g. adapters/qwen-probe"
            mono
          />
        </Field>

        {/* Holdout */}
        <Field label="HOLDOUT">
          <Segmented
            options={["function", "graph"]}
            value={form.holdout}
            onChange={(v) => onForm({ holdout: v as "function" | "graph" })}
          />
        </Field>

        {/* Limit */}
        <Field label="LIMIT">
          <TextInput
            value={form.limit}
            onChange={(v) => onForm({ limit: v })}
            placeholder="all"
            mono
          />
        </Field>

        {/* Sim threshold: only for idiom */}
        {form.kind === "idiom" && (
          <Field label="SIM THRESHOLD">
            <TextInput
              value={form.simThreshold}
              onChange={(v) => onForm({ simThreshold: v })}
              placeholder="0.7"
              mono
            />
          </Field>
        )}

        {/* Launch button */}
        <button
          onClick={onStart}
          disabled={busy}
          className="mt-1 w-full rounded-md border border-neutral-600 bg-[#1a1a1a] py-1.5 text-xs text-neutral-100 transition-colors hover:border-neutral-400 hover:bg-[#222] disabled:cursor-not-allowed disabled:opacity-40"
        >
          {busy ? "LAUNCHING…" : "LAUNCH"}
        </button>

        {/* Error */}
        {error && (
          <span className="stat-line text-neutral-100">{error}</span>
        )}
      </div>
    </div>
  );
}
