"""RL section — LIVE SFT/GRPO ladder (top) + weekend archive (below).

The live block fetches get_rl_ladder() (rl.sv.jac, reads results/rl_ladder.jsonl as
the ladder runs) and renders the holdout pass@1 curve over rungs + the per-cell
table. The archive below is the static weekend GRPO/STaR result, kept for context.
"""

sv import from ...rl { get_rl_ladder }

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
glob FAILS: list[dict] = [
    {"t": "σ=0 zero-advantage trap", "b": "at ~0% base pass every rollout scores alike → advantage (r−mean)/σ = 0 → no gradient. Dense body-sim reward broke it."},
    {"t": "broken splice (faked attempts 1–2)", "b": "full unit spliced into inner hole → nested broken Jac, never ran. unwrap_unit fixed it; runs==pass after."},
    {"t": "LoRA-GRPO can't move greedy", "b": "real reward variance (σ≤0.11, loss 0.02–0.05) yet +grpo eval byte-identical, KL≈0. pass@8==pass@1. The core null."},
    {"t": "Qwen3.6 untrainable on 48 GB", "b": "dense 27B activates all params/token; 35B-A3B keeps 256 experts resident. Both OOM SFT at iter 1. Inference-only."},
    {"t": "STaR flicker didn't hold", "b": "qwen3coder pass@4 touched 25% at round 1 then fell back; greedy never left the 16.7% SFT floor."}
];
glob STROKES: list[str] = ["#7aa2f7", "#d8a657", "#9ec98f"];
glob LCOLORS: list[str] = ["#7aa2f7", "#d8a657", "#9ec98f", "#e07a8b", "#a78bdb", "#6fb8c9"];

def _tick() -> dict {
    return {"fill": "#666", "fontSize": 10, "fontFamily": "'Geist Mono', ui-monospace, monospace"};
}

def _n(v: any) -> str {
    return (str(v) + "%") if v != None else "·";
}

def _ladderChart(props: dict) -> JsxElement {
    rows = props["rows"];
    keys: list = list(props["keys"]);
    return <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
        <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">HOLDOUT pass@1 · by rung (train-N)</span>
        <ResponsiveContainer width="100%" height={220}>
            <LineChart data={rows} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                <CartesianGrid stroke="#1c1c1f" vertical={False} />
                <XAxis dataKey="x" tick={_tick()} tickLine={False} axisLine={{"stroke": "#333"}} />
                <YAxis tick={_tick()} tickLine={False} axisLine={False} width={40} domain={[0, "auto"]} />
                <Tooltip cursor={{"stroke": "#333", "strokeDasharray": "3 3"}} contentStyle={{"background": "#0a0a0c", "border": "1px solid #333", "borderRadius": 0, "fontFamily": "'Geist Mono', ui-monospace, monospace", "fontSize": 11}} labelStyle={{"color": "#777"}} itemStyle={{"color": "#fafafa"}} />
                <Legend wrapperStyle={{"fontFamily": "'Geist Mono', ui-monospace, monospace", "fontSize": 10}} />
                {for (i, k) in enumerate(keys) {
                    <Line key={k} type="monotone" dataKey={k} stroke={LCOLORS[i % len(LCOLORS)]} strokeWidth={1.4} dot={True} isAnimationActive={False} connectNulls={True} />
                }}
            </LineChart>
        </ResponsiveContainer>
    </div>;
}

def _archiveLine(props: dict) -> JsxElement {
    return <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
        <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">{props["title"]}</span>
        <ResponsiveContainer width="100%" height={180}>
            <LineChart data={props["rows"]} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                <CartesianGrid stroke="#1c1c1f" vertical={False} />
                <XAxis dataKey="x" tick={_tick()} tickLine={False} axisLine={{"stroke": "#333"}} />
                <YAxis tick={_tick()} tickLine={False} axisLine={False} width={40} domain={["auto", "auto"]} />
                <Tooltip cursor={{"stroke": "#333", "strokeDasharray": "3 3"}} contentStyle={{"background": "#0a0a0c", "border": "1px solid #333", "borderRadius": 0, "fontFamily": "'Geist Mono', ui-monospace, monospace", "fontSize": 11}} labelStyle={{"color": "#777"}} itemStyle={{"color": "#fafafa"}} />
                <Line type="monotone" dataKey="qwen3coder" stroke={STROKES[0]} strokeWidth={1.4} dot={False} isAnimationActive={False} />
                <Line type="monotone" dataKey="jac-qwen3coder" stroke={STROKES[1]} strokeWidth={1.4} dot={False} isAnimationActive={False} />
            </LineChart>
        </ResponsiveContainer>
    </div>;
}

def:pub Rl -> JsxElement {
    has cells: list = [],
        curve: list = [],
        keys: list = [];

    async can with entry {
        d = await get_rl_ladder();
        cells = list(d["cells"]);
        curve = list(d["curve"]);
        keys = list(d["curve_keys"]);
    }

    has_live = len(cells) > 0;

    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="flex items-center justify-between border-b border-neutral-800 px-4 py-2.5">
            <span className="micro-label">RL · SFT/GRPO LADDER (live) + weekend archive</span>
            <span className="micro-label text-neutral-600">{(str(len(cells)) + " cells") if has_live else "no ladder run yet"}</span>
        </div>

        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            {(<div className="flex flex-col gap-4">
                {_ladderChart({"rows": curve, "keys": keys})}
                <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
                    <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">LADDER CELLS</span>
                    <table className="w-full font-mono text-xs">
                        <thead>
                            <tr className="text-neutral-500">
                                <th className="py-1 text-left">model</th><th className="text-left">rung</th>
                                <th className="text-left">cond</th><th className="text-right">gen@1</th>
                                <th className="text-right">gen@k</th><th className="text-right">mem</th>
                                <th className="text-right">n</th>
                            </tr>
                        </thead>
                        <tbody>
                            {for c in cells {
                                <tr key={str(c["model"]) + str(c["rung"]) + str(c["cond"])} className="border-t border-neutral-900 text-neutral-300">
                                    <td className="py-1">{c["model"]}</td><td>{c["rung"]}</td>
                                    <td className="text-neutral-500">{c["cond"]}</td>
                                    <td className="text-right text-neutral-100">{_n(c["gen_pass1"])}</td>
                                    <td className="text-right">{_n(c["gen_passk"])}</td>
                                    <td className="text-right text-neutral-500">{_n(c["mem_pass1"])}</td>
                                    <td className="text-right text-neutral-600">{c["n"] if c["n"] != None else "·"}</td>
                                </tr>
                            }}
                        </tbody>
                    </table>
                    <div className="stat-line mt-2 text-neutral-600">gen=holdout (generalization), mem=train recall. Read pass@k, not bare pass@1 — n is small.</div>
                </div>
            </div>) if has_live else (<div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">LADDER</span>
                <p className="text-sm text-neutral-400">No ladder results yet. Run <span className="font-mono text-neutral-200">JAC_LADDER_GO=1 jac run rl/run_ladder.jac</span> — cells stream into this graph as evals land.</p>
            </div>)}

            <div className="mt-2 border-t border-neutral-800 pt-3">
                <span className="micro-label text-neutral-500">— WEEKEND ARCHIVE · GRPO + WARM-START + STaR (Jun 20–21) —</span>
            </div>

            <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">RESULT (archive)</span>
                <p className="text-sm text-neutral-300">
                    Supervised levers (SFT, DPO, gold warm-start) move models here. <b>RL does not.</b> GRPO added nothing (confirmed by pass@8), STaR added a faint flicker that didn't hold, and the bigger Qwen3.6 models can't be trained on 48 GB.
                </p>
            </div>

            <div className="grid grid-cols-2 gap-4">
                {_archiveLine({"title": "STaR · pass@1 greedy · by round", "rows": STAR1})}
                {_archiveLine({"title": "STaR · pass@4 sampled · by round", "rows": STAR4})}
            </div>

            <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">PHASE 1 · WARM-START LIFT · holdout pass%</span>
                <ResponsiveContainer width="100%" height={200}>
                    <BarChart data={PHASE1} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                        <CartesianGrid stroke="#1c1c1f" vertical={False} />
                        <XAxis dataKey="model" tick={_tick()} tickLine={False} axisLine={{"stroke": "#333"}} />
                        <YAxis tick={_tick()} tickLine={False} axisLine={False} width={32} domain={[0, "auto"]} />
                        <Tooltip cursor={{"fill": "#ffffff08"}} contentStyle={{"background": "#0a0a0c", "border": "1px solid #333", "borderRadius": 0, "fontFamily": "'Geist Mono', ui-monospace, monospace", "fontSize": 11}} labelStyle={{"color": "#777"}} itemStyle={{"color": "#fafafa"}} />
                        <Legend wrapperStyle={{"fontFamily": "'Geist Mono', ui-monospace, monospace", "fontSize": 10, "color": "#777"}} />
                        <Bar dataKey="BASE" fill={STROKES[0]} isAnimationActive={False} />
                        <Bar dataKey="WARM" fill={STROKES[1]} isAnimationActive={False} />
                        <Bar dataKey="GRPO" fill={STROKES[2]} isAnimationActive={False} />
                    </BarChart>
                </ResponsiveContainer>
            </div>

            <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">FAILURES &amp; WHY (archive)</span>
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
