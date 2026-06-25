"""RL section — GRPO + warm-start + STaR weekend results (static, historical).

Ports ui/components/sections/rl/rl-section.tsx: verdict, stat tiles, STaR line
charts (pass@1 / pass@4 by round), Phase-1 warm-start bars, failures. Proves
recharts renders inside a .cl.jac.
"""

import from "recharts" {
    ResponsiveContainer, LineChart, Line, BarChart, Bar,
    XAxis, YAxis, CartesianGrid, Tooltip, Legend
}

glob STAR1: list[dict] = [
    {"x": 0, "qwen3coder": 16.7, "jac-qwen3coder": 16.7},
    {"x": 1, "qwen3coder": 16.7, "jac-qwen3coder": 16.7},
    {"x": 2, "qwen3coder": 16.7, "jac-qwen3coder": 16.7}
];
glob STAR4: list[dict] = [
    {"x": 0, "qwen3coder": 16.7, "jac-qwen3coder": 16.7},
    {"x": 1, "qwen3coder": 25.0, "jac-qwen3coder": 16.7},
    {"x": 2, "qwen3coder": 16.7, "jac-qwen3coder": 16.7}
];
glob PHASE1: list[dict] = [
    {"model": "qwen3coder·fresh", "BASE": 0, "WARM": 14.3, "GRPO": 14.3},
    {"model": "jac-qwen3coder", "BASE": 14.3, "WARM": 14.3, "GRPO": 14.3}
];
glob TILES: list[dict] = [
    {"label": "WARM-START LIFT", "value": "0 → 14.3%", "sub": "fresh qwen3coder · the one RL-adjacent win"},
    {"label": "GRPO Δ GREEDY", "value": "0.0", "sub": "byte-identical · KL≈0 · pass@8==pass@1"},
    {"label": "STaR PEAK · pass@4", "value": "25.0%", "sub": "qwen3coder round 1 · did not hold"},
    {"label": "pass@1 FLOOR", "value": "16.7%", "sub": "SFT floor · RL never beat it"}
];
glob FAILS: list[dict] = [
    {"t": "σ=0 zero-advantage trap", "b": "at ~0% base pass every rollout scores alike → advantage (r−mean)/σ = 0 → no gradient. Dense body-sim reward broke it."},
    {"t": "broken splice (faked attempts 1–2)", "b": "full unit spliced into inner hole → nested broken Jac, never ran. unwrap_unit fixed it; runs==pass after."},
    {"t": "LoRA-GRPO can't move greedy", "b": "real reward variance (σ≤0.11, loss 0.02–0.05) yet +grpo eval byte-identical, KL≈0. pass@8==pass@1. The core null."},
    {"t": "Qwen3.6 untrainable on 48 GB", "b": "dense 27B activates all params/token; 35B-A3B keeps 256 experts resident. Both OOM SFT at iter 1. Inference-only."},
    {"t": "STaR flicker didn't hold", "b": "qwen3coder pass@4 touched 25% at round 1 then fell back; greedy never left the 16.7% SFT floor."}
];
glob STROKES: list[str] = ["#7aa2f7", "#d8a657", "#9ec98f"];

def _tick() -> dict {
    return {"fill": "#666", "fontSize": 10, "fontFamily": "ui-monospace, monospace"};
}

def _lineChart(title: str, rows: list[dict]) -> JsxElement {
    return <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
        <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">{title}</span>
        <ResponsiveContainer width="100%" height={180}>
            <LineChart data={rows} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                <CartesianGrid stroke="#1c1c1f" vertical={False} />
                <XAxis dataKey="x" tick={_tick()} tickLine={False} axisLine={{"stroke": "#333"}} />
                <YAxis tick={_tick()} tickLine={False} axisLine={False} width={40} domain={["auto", "auto"]} />
                <Tooltip contentStyle={{"background": "#0a0a0c", "border": "1px solid #333", "borderRadius": 0, "fontFamily": "ui-monospace, monospace", "fontSize": 11}} />
                <Line type="monotone" dataKey="qwen3coder" stroke={STROKES[0]} strokeWidth={1.4} dot={False} isAnimationActive={False} />
                <Line type="monotone" dataKey="jac-qwen3coder" stroke={STROKES[1]} strokeWidth={1.4} dot={False} isAnimationActive={False} />
            </LineChart>
        </ResponsiveContainer>
        <div className="mt-2 flex gap-3">
            <span className="stat-line" style={{"color": STROKES[0]}}>── qwen3coder</span>
            <span className="stat-line" style={{"color": STROKES[1]}}>── jac-qwen3coder</span>
        </div>
    </div>;
}

def:pub Rl -> JsxElement {
    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="flex items-center justify-between border-b border-neutral-800 px-4 py-2.5">
            <span className="micro-label">RL · GRPO + WARM-START + STaR</span>
            <span className="micro-label text-neutral-600">Jun 20–21 · MLX 48GB</span>
        </div>

        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">RESULT</span>
                <p className="text-sm text-neutral-300">
                    Supervised levers (SFT, DPO, gold warm-start) move models here. <b>RL does not.</b> GRPO added nothing (confirmed by pass@8), STaR added a faint flicker that didn't hold, and the bigger Qwen3.6 models can't be trained on 48 GB. The science result: LoRA-RL on a 30B-class model doesn't beat SFT at this task difficulty / scale / hardware.
                </p>
            </div>

            <div className="grid grid-cols-4 gap-3">
                {for t in TILES {
                    <div key={t["label"]} className="relative p-3 pt-4">
                        <span className="absolute left-0 top-0 h-[10px] w-[10px] border-l border-t border-neutral-600" />
                        <span className="absolute right-0 top-0 h-[10px] w-[10px] border-r border-t border-neutral-600" />
                        <span className="absolute bottom-0 left-0 h-[10px] w-[10px] border-b border-l border-neutral-600" />
                        <span className="absolute bottom-0 right-0 h-[10px] w-[10px] border-b border-r border-neutral-600" />
                        <div className="micro-label mb-1">{t["label"]}</div>
                        <div className="font-mono text-xl text-neutral-100">{t["value"]}</div>
                        <div className="stat-line mt-0.5">{t["sub"]}</div>
                    </div>
                }}
            </div>

            <div className="grid grid-cols-2 gap-4">
                {_lineChart("STaR · pass@1 greedy · by round", STAR1)}
                {_lineChart("STaR · pass@4 sampled · by round", STAR4)}
            </div>

            <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">PHASE 1 · WARM-START LIFT · holdout pass%</span>
                <ResponsiveContainer width="100%" height={200}>
                    <BarChart data={PHASE1} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                        <CartesianGrid stroke="#1c1c1f" vertical={False} />
                        <XAxis dataKey="model" tick={_tick()} tickLine={False} axisLine={{"stroke": "#333"}} />
                        <YAxis tick={_tick()} tickLine={False} axisLine={False} width={32} domain={[0, "auto"]} />
                        <Tooltip contentStyle={{"background": "#0a0a0c", "border": "1px solid #333", "borderRadius": 0, "fontFamily": "ui-monospace, monospace", "fontSize": 11}} />
                        <Legend wrapperStyle={{"fontFamily": "ui-monospace, monospace", "fontSize": 10, "color": "#777"}} />
                        <Bar dataKey="BASE" fill={STROKES[0]} isAnimationActive={False} />
                        <Bar dataKey="WARM" fill={STROKES[1]} isAnimationActive={False} />
                        <Bar dataKey="GRPO" fill={STROKES[2]} isAnimationActive={False} />
                    </BarChart>
                </ResponsiveContainer>
                <div className="stat-line mt-2 text-neutral-600">warm-start lifts fresh qwen3coder 0 → 14.3%. GRPO adds nothing on top of either base.</div>
            </div>

            <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">FAILURES &amp; WHY</span>
                <div className="flex flex-col gap-2.5">
                    {for f in FAILS {
                        <div key={f["t"]} className="grid grid-cols-[200px_1fr] gap-3">
                            <span className="font-mono text-xs text-neutral-300">{f["t"]}</span>
                            <span className="stat-line text-neutral-500">{f["b"]}</span>
                        </div>
                    }}
                </div>
            </div>
        </div>
    </div>;
}
