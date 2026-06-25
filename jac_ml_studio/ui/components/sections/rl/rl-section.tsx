"use client";
// RL weekend results — static historical run (GRPO + warm-start + STaR on Jac).
// Numbers are final and sourced from RL_WEEKEND_RESULTS.md; no backend, no DB.
// ponytail: data inlined as a const — these are frozen results, not a live job.
import {
  ResponsiveContainer,
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
} from "recharts";
import { StatTile } from "@/components/shared/stat-tile";
import { MultiLineChart } from "@/components/shared/multi-line-chart";
import type { CompareRow } from "@/lib/api-train";

const MONO_FONT = "var(--font-geist-mono), monospace";
const TICK = { fill: "#666", fontSize: 10, fontFamily: MONO_FONT };
const STROKES = ["#7aa2f7", "#d8a657", "#9ec98f"];

// Phase 1 — 31 tasks, holdout 7. Pass % (exact stdout) by lever.
// qwen3.6 dense omitted: OOM'd warm-start at iter 1, never trained (see FAILURES).
const PHASE1 = [
  { model: "qwen3coder · fresh MoE", BASE: 0, WARM: 14.3, GRPO: 14.3 },
  { model: "jac-qwen3coder · SFT+DPO", BASE: 14.3, WARM: 14.3, GRPO: 14.3 },
];

// STaR — iterate warm-start, rounds 0/1/2. pass@1 greedy and pass@4 sampled.
const STAR_PASS1: CompareRow[] = [
  { x: 0, qwen3coder: 16.7, "jac-qwen3coder": 16.7 },
  { x: 1, qwen3coder: 16.7, "jac-qwen3coder": 16.7 },
  { x: 2, qwen3coder: 16.7, "jac-qwen3coder": 16.7 },
];
const STAR_PASS4: CompareRow[] = [
  { x: 0, qwen3coder: 16.7, "jac-qwen3coder": 16.7 },
  { x: 1, qwen3coder: 25.0, "jac-qwen3coder": 16.7 },
  { x: 2, qwen3coder: 16.7, "jac-qwen3coder": 16.7 },
];
const STAR_NAMES = ["qwen3coder", "jac-qwen3coder"];

const FAILURES = [
  ["σ=0 zero-advantage trap", "at ~0% base pass every rollout scores alike → advantage (r−mean)/σ = 0 → no gradient. Dense body-sim reward broke it."],
  ["broken splice (faked attempts 1–2)", "full unit spliced into inner hole → nested broken Jac, never ran. unwrap_unit fixed it; after fix runs==pass."],
  ["LoRA-GRPO can't move greedy", "real reward variance (σ≤0.11, loss 0.02–0.05) yet +grpo eval byte-identical to base, KL≈0. pass@8==pass@1. The core null."],
  ["Qwen3.6 untrainable on 48 GB", "dense 27B activates all params/token; 35B-A3B keeps 256 experts resident. Both OOM SFT at iter 1. Inference-only."],
  ["STaR flicker didn't hold", "qwen3coder pass@4 touched 25% at round 1 then fell back; greedy never left the 16.7% SFT floor."],
];

function Bars() {
  return (
    <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
      <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">
        PHASE 1 · WARM-START LIFT · holdout pass%
      </span>
      <ResponsiveContainer width="100%" height={200}>
        <BarChart data={PHASE1} margin={{ top: 10, right: 14, left: 0, bottom: 0 }}>
          <CartesianGrid stroke="#1c1c1f" vertical={false} />
          <XAxis dataKey="model" tick={TICK} tickLine={false} axisLine={{ stroke: "#333" }} />
          <YAxis tick={TICK} tickLine={false} axisLine={false} width={32} domain={[0, "auto"]} />
          <Tooltip
            contentStyle={{ background: "#0a0a0c", border: "1px solid #333", borderRadius: 0, fontFamily: MONO_FONT, fontSize: 11 }}
            labelStyle={{ color: "#777" }}
            itemStyle={{ color: "#fafafa" }}
            cursor={{ fill: "#ffffff08" }}
          />
          <Legend wrapperStyle={{ fontFamily: MONO_FONT, fontSize: 10, color: "#777" }} />
          <Bar dataKey="BASE" fill={STROKES[0]} isAnimationActive={false} />
          <Bar dataKey="WARM" fill={STROKES[1]} isAnimationActive={false} />
          <Bar dataKey="GRPO" fill={STROKES[2]} isAnimationActive={false} />
        </BarChart>
      </ResponsiveContainer>
      <div className="stat-line mt-2 text-neutral-600">
        warm-start lifts fresh qwen3coder 0 → 14.3%. GRPO adds nothing on top of either base.
      </div>
    </div>
  );
}

export default function RlSection() {
  return (
    <div className="flex h-full min-w-0 flex-1 flex-col">
      <div className="flex items-center justify-between border-b border-neutral-800 px-4 py-2.5">
        <span className="micro-label">RL · GRPO + WARM-START + STaR</span>
        <span className="micro-label text-neutral-600">Jun 20–21 · MLX 48GB</span>
      </div>

      <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
        {/* One-line verdict */}
        <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
          <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">RESULT</span>
          <p className="text-sm text-neutral-300">
            Supervised levers (SFT, DPO, gold warm-start) move models here. <b>RL does not.</b>{" "}
            GRPO added nothing (confirmed by pass@8), STaR added a faint flicker that didn&apos;t hold,
            and the bigger Qwen3.6 models can&apos;t be trained on 48 GB. Harness/reward/eval all proven
            on real 30B — the science result is that LoRA-RL on a 30B-class model doesn&apos;t beat SFT
            at this task difficulty / scale / hardware.
          </p>
        </div>

        {/* Headline tiles */}
        <div className="grid grid-cols-4 gap-3">
          <StatTile label="WARM-START LIFT" value="0 → 14.3%" sub="fresh qwen3coder holdout · the one RL-adjacent win" />
          <StatTile label="GRPO Δ GREEDY" value="0.0" sub="byte-identical · KL≈0 · pass@8==pass@1" />
          <StatTile label="STaR PEAK · pass@4" value="25.0%" sub="qwen3coder round 1 · did not hold" />
          <StatTile label="pass@1 FLOOR" value="16.7%" sub="SFT floor · RL never beat it" />
        </div>

        {/* STaR line charts */}
        <div className="grid grid-cols-2 gap-4">
          <MultiLineChart title="STaR · pass@1 greedy · by round" rows={STAR_PASS1} names={STAR_NAMES} />
          <MultiLineChart title="STaR · pass@4 sampled · by round" rows={STAR_PASS4} names={STAR_NAMES} />
        </div>

        {/* Phase 1 bars */}
        <Bars />

        {/* Failures / why */}
        <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
          <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">FAILURES &amp; WHY</span>
          <div className="flex flex-col gap-2.5">
            {FAILURES.map(([title, body]) => (
              <div key={title} className="grid grid-cols-[200px_1fr] gap-3">
                <span className="font-mono text-xs text-neutral-300">{title}</span>
                <span className="stat-line text-neutral-500">{body}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
