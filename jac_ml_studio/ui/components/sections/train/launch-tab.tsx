"use client";
import { Field, TextInput, Segmented } from "@/components/shared/field";
import { StatusGlyph } from "@/components/shared/status-glyph";
import { LogView } from "@/components/shared/log-view";
import type { JobStatus } from "@/lib/api-train";

interface LaunchForm {
  modelId: string;
  name: string;
  mode: "sft" | "dpo";
  opts: Record<string, string>;
}

interface LaunchTabProps {
  form: LaunchForm;
  updateForm: <K extends keyof LaunchForm>(key: K, value: LaunchForm[K]) => void;
  updateOpt: (key: string, value: string) => void;
  job: JobStatus | null;
  error: string | null;
  onStart: () => void;
  onStop: () => void;
  sftKeys: readonly string[];
  dpoKeys: readonly string[];
}

const BTN =
  "border border-neutral-600 rounded-lg px-3 py-1 font-mono text-[10px] hover:border-neutral-400 disabled:opacity-30 transition-colors";

export function LaunchTab({
  form,
  updateForm,
  updateOpt,
  job,
  error,
  onStart,
  onStop,
  sftKeys,
  dpoKeys,
}: LaunchTabProps) {
  const isRunning = job?.status === "running";
  const optKeys = form.mode === "sft" ? sftKeys : dpoKeys;

  return (
    <div className="flex gap-4 p-4 h-full min-h-0">
      {/* LEFT — LAUNCH.CONFIG */}
      <div className="relative flex-1 rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5 flex flex-col gap-3 min-w-0 overflow-y-auto">
        <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">LAUNCH.CONFIG</span>

        {form.mode === "sft" && (
          <Field label="BASE MODEL (HF ID)">
            <TextInput
              value={form.modelId}
              onChange={(v) => updateForm("modelId", v)}
              placeholder="org/model"
              mono
            />
          </Field>
        )}

        <Field label="SHORT NAME">
          <TextInput
            value={form.name}
            onChange={(v) => updateForm("name", v)}
            placeholder="qwen"
            mono
          />
        </Field>

        <Field label="MODE">
          <Segmented
            options={["sft", "dpo"]}
            value={form.mode}
            onChange={(v) => updateForm("mode", v as "sft" | "dpo")}
          />
        </Field>

        {optKeys.map((key) => (
          <Field key={key} label={key}>
            <TextInput
              value={form.opts[key] ?? ""}
              onChange={(v) => updateOpt(key, v)}
              placeholder={key}
              mono
            />
          </Field>
        ))}

        <p className="stat-line text-neutral-500 mt-1">
          heavy workload — one training at a time, runs detached
        </p>

        <div className="flex gap-2 mt-2">
          <button
            onClick={onStart}
            disabled={isRunning}
            className={`${BTN} text-neutral-100`}
          >
            ▶ START {form.mode.toUpperCase()}
          </button>
          <button
            onClick={onStop}
            disabled={!isRunning}
            className={`${BTN} text-neutral-400`}
          >
            ■ STOP
          </button>
        </div>

        {error && <p className="stat-line text-neutral-400 mt-1">{error}</p>}
      </div>

      {/* RIGHT — RUN.STATUS */}
      <div className="relative flex-1 rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5 flex flex-col gap-3 min-w-0 overflow-y-auto">
        <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">RUN.STATUS</span>

        <div className="flex items-center gap-3 flex-wrap">
          <StatusGlyph status={job?.status ?? "idle"} />
        </div>

        {job && (
          <div className="flex flex-col gap-1">
            {job.pid > 0 && (
              <span className="font-mono text-[11px] text-neutral-500">PID {job.pid}</span>
            )}
            {job.started && (
              <span className="font-mono text-[11px] text-neutral-500">
                STARTED {job.started || "n/a"}
              </span>
            )}
            {job.last_iter > 0 && (
              <span className="font-mono text-[11px] text-neutral-500">
                LAST ITER {job.last_iter}
              </span>
            )}
          </div>
        )}

        <LogView text={job?.log_tail ?? ""} maxH="24rem" />
      </div>
    </div>
  );
}
