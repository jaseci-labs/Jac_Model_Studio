"use client";
import { useEvals } from "@/lib/use-evals";
import { EvalLaunch } from "./eval-launch";
import { EvalRunView } from "./eval-run-view";
import { EvalHistory } from "./eval-history";
import { EvalCompare } from "./eval-compare";

export default function EvalsSection({ active }: { active: boolean }) {
  const {
    models,
    form,
    setForm,
    history,
    activeEval,
    error,
    busy,
    start,
    stopActive,
    removeEval,
    openEval,
  } = useEvals(active);

  return (
    <div className="flex h-full min-w-0 flex-1 flex-col">
      {/* Header */}
      <div className="flex items-center justify-between border-b border-neutral-800 px-4 py-2.5">
        <span className="micro-label">EVALS</span>
        <span className="micro-label text-neutral-600">EVAL.CTL</span>
      </div>

      {/* Body */}
      <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
        {/* Top row: launch + run view */}
        <div className="grid gap-4" style={{ gridTemplateColumns: "360px 1fr" }}>
          <EvalLaunch
            models={models}
            form={form}
            onForm={setForm}
            onStart={start}
            busy={busy}
            error={error}
          />
          <EvalRunView run={activeEval} onStop={stopActive} />
        </div>

        {/* Bottom row: history + compare */}
        <div className="grid grid-cols-2 gap-4">
          <EvalHistory
            history={history}
            onOpen={openEval}
            onDelete={removeEval}
          />
          <EvalCompare history={history} />
        </div>
      </div>
    </div>
  );
}
