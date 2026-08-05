"""RESULTS section (workspace 02 RL/GRPO) — LIVE SFT/GRPO ladder + corrected
results + weekend archive.

The live block fetches get_rl_ladder() (rl.sv.jac, reads 02-rl-grpo/results/
rl_ladder.jsonl as the ladder runs) and renders the holdout pass@1 curve over
rungs + the per-cell table; get_rl_corrected() drives the corrected charts. The
archive below is the static weekend GRPO/STaR result, kept for context. The
deployable best-of-k generate widget lives in the sibling Generate section.
"""

sv import from ...rl { get_rl_ladder, get_rl_corrected }

import from "recharts" {
    ResponsiveContainer, LineChart, Line, BarChart, Bar,
    XAxis, YAxis, CartesianGrid, Tooltip, Legend
}
import from ...lib.chartkit {
    chartColor, gridStroke, axisStroke, tick,
    tipContentStyle, tipLabelStyle, tipItemStyle, tipCursor
}

# ponytail: chartkit's `MONO` is a plain `glob`, and globs don't cross a compiled
# .cl.jac module boundary (it is absent from chartkit.js's export list), so the
# token string is repeated here rather than imported. It is still a token, so
# light/dark both resolve correctly.
glob MONO: str = "var(--font-mono)";
# Bar/area charts want a filled hover band, which chartkit only ships as a
# stroked cursor (tipCursor) — one token-based literal covers it.
glob FILL_CURSOR: dict = {"fill": "var(--muted)", "fillOpacity": 0.5};

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
glob PCT_TICKS: list[int] = [0, 25, 50, 75, 100];

# Color encodes CONDITION (stable by name, not list index — so the same cond is
# the same color across every chart). Model is encoded by line style instead:
# solid = jac- finetuned, dashed = base model. See _colorFor / _dashFor.
# Indices into chartkit's palette, so the ramp re-skins with the theme.
glob COND_SLOT: dict = {
    "base": 3, "sft": 1, "raw_grpo": 0, "sft_grpo": 5, "sft_grpo_tuned": 4
};

def _n(v: any) -> str {
    return (str(v) + "%") if v != None else "·";
}

def _condOf(key: str) -> str {
    parts = str(key).split("·");
    return str(parts[1]) if len(parts) > 1 else str(key);
}

def _colorFor(key: str) -> str {
    c = _condOf(key);
    return chartColor(int(str(COND_SLOT[c]))) if c in COND_SLOT else chartColor(2);
}

# solid line = jac- finetuned model; dashed = base model. Lets two series that
# share a condition color stay distinguishable where they overlap.
def _dashFor(key: str) -> str {
    return "" if str(key).startswith("jac-") else "5 3";
}

# Custom tooltip: lists EVERY series at the hovered rung, with an explicit N/A
# (dim, dotted swatch) for any series that had no eval there. Recharts clones
# this element injecting active/payload/label; `seriesKeys` is the full series
# list. Must stay PascalCase — JSX treats a lowercase/underscore tag name as a
# raw HTML element, which silently kills the tooltip.
def LadderTip(
    seriesKeys: any = None,
    active: any = False,
    payload: any = None,
    label: any = None
) -> JsxElement {
    if not active { return <span></span>; }
    rows: list = list(payload or []);
    keys: list = list(seriesKeys or []);
    present: dict = {};
    for p in rows {
        if p.get("value") != None { present[str(p.get("dataKey"))] = p.get("value"); }
    }
    return <div className="rounded-sm border border-input bg-background px-2.5 py-2" style={{"fontFamily": MONO, "fontSize": 11}}>
        <div className="micro-label mb-1 text-muted-foreground">rung {label} · pass@1</div>
        {for k in keys {
            <div key={k} className="flex items-center justify-between gap-4 leading-5">
                <span className="flex items-center gap-1.5">
                    <span style={{"display": "inline-block", "width": 14, "borderTop": (("2px dashed " + _colorFor(k)) if _dashFor(k) else ("2px solid " + _colorFor(k)))}}></span>
                    <span style={{"color": _colorFor(k)}}>{k}</span>
                </span>
                {(<span className="text-foreground">{str(present[k]) + "%"}</span>) if (k in present) else (<span className="rounded-sm border border-dashed border-input px-1 italic text-muted-foreground">N/A</span>)}
            </div>
        }}
    </div>;
}

def _ladderChart(props: dict) -> JsxElement {
    rows = props["rows"];
    keys: list = list(props["keys"]);
    return <div className="relative exp-panel p-3 pt-4">
        <span className="micro-label absolute -top-2 left-3 bg-background px-2">HOLDOUT pass@1 % · by rung (train-N) · Y axis 0–100</span>
        <ResponsiveContainer width="100%" height={260}>
            <LineChart data={rows} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                <CartesianGrid stroke={gridStroke()} vertical={False} />
                <XAxis dataKey="x" tick={tick()} tickLine={False} axisLine={{"stroke": axisStroke()}} />
                <YAxis tick={tick()} tickLine={False} axisLine={False} width={40} domain={[0, 100]} ticks={PCT_TICKS} unit="%" />
                <Tooltip cursor={tipCursor()} content={<LadderTip seriesKeys={keys}/>} />
                <Legend wrapperStyle={{"fontFamily": MONO, "fontSize": 10, "color": "var(--muted-foreground)"}} />
                {for k in keys {
                    <Line key={k} type="monotone" dataKey={k} stroke={_colorFor(k)} strokeDasharray={_dashFor(k)} strokeWidth={1.8} dot={{"r": 3.2, "fill": _colorFor(k), "strokeWidth": 0}} activeDot={{"r": 4.5}} isAnimationActive={False} connectNulls={False} />
                }}
            </LineChart>
        </ResponsiveContainer>
        <div className="stat-line mt-2 text-muted-foreground/80">color = condition (base / sft / raw_grpo / sft_grpo / sft_grpo_tuned) · solid = jac- finetuned, dashed = base model · a broken line / lone dot = that series was only evaluated at that rung; gaps = N/A (hover for the full per-series breakdown incl. N/A) · coincident lines mean equal scores, not a render bug.</div>
    </div>;
}

def _archiveLine(props: dict) -> JsxElement {
    return <div className="relative exp-panel p-3 pt-4">
        <span className="micro-label absolute -top-2 left-3 bg-background px-2">{props["title"]}</span>
        <ResponsiveContainer width="100%" height={180}>
            <LineChart data={props["rows"]} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                <CartesianGrid stroke={gridStroke()} vertical={False} />
                <XAxis dataKey="x" tick={tick()} tickLine={False} axisLine={{"stroke": axisStroke()}} />
                <YAxis tick={tick()} tickLine={False} axisLine={False} width={40} domain={[0, 100]} ticks={PCT_TICKS} unit="%" />
                <Tooltip cursor={tipCursor()} contentStyle={tipContentStyle()} labelStyle={tipLabelStyle()} itemStyle={tipItemStyle()} />
                <Legend wrapperStyle={{"fontFamily": MONO, "fontSize": 10, "color": "var(--muted-foreground)"}} />
                <Line type="monotone" dataKey="qwen3coder" stroke={chartColor(1)} strokeDasharray="5 3" strokeWidth={1.8} dot={{"r": 2.6, "fill": chartColor(1), "strokeWidth": 0}} isAnimationActive={False} />
                <Line type="monotone" dataKey="jac-qwen3coder" stroke={chartColor(0)} strokeWidth={1.8} dot={{"r": 2.6, "fill": chartColor(0), "strokeWidth": 0}} isAnimationActive={False} />
            </LineChart>
        </ResponsiveContainer>
    </div>;
}

def:pub Results -> JsxElement {
    has cells: list = [],
        curve: list = [],
        keys: list = [],
        sgcells: list = [],
        sgcurve: list = [],
        sgkeys: list = [],
        v84cells: list = [],
        v84curve: list = [],
        v84keys: list = [],
        corrLadder: list = [],
        corrHold: list = [],
        corrJourney: list = [],
        corrKscale: list = [],
        loadErr: str = "";

    async can with entry {
        # Both blocks are guarded independently so a failure in one still renders
        # the other; unguarded these were un-.catch()ed async IIFEs whose
        # rejection left every panel on its empty state with no explanation.
        try {
            d = await get_rl_ladder();
            cells = list(d["cells"]);
            curve = list(d["curve"]);
            keys = list(d["curve_keys"]);
            # `sg`/`v84` were indexed blind — an older payload without them threw
            # a KeyError here and killed the whole mount, including the corrected
            # charts below.
            if "sg" in d and d["sg"] is not None {
                sgd = d["sg"];
                sgcells = list(sgd["cells"]);
                sgcurve = list(sgd["curve"]);
                sgkeys = list(sgd["curve_keys"]);
            }
            if "v84" in d and d["v84"] is not None {
                v84d = d["v84"];
                v84cells = list(v84d["cells"]);
                v84curve = list(v84d["curve"]);
                v84keys = list(v84d["curve_keys"]);
            }
        } except Exception as e {
            loadErr = "ladder load failed · " + str(e);
        }
        try {
            cr = await get_rl_corrected();
            corrLadder = list(cr["ladder"]);
            corrHold = list(cr["holdouts"]);
            corrJourney = list(cr["journey"]);
            corrKscale = list(cr["kscale"]);
        } except Exception as e {
            loadErr = (loadErr + " · " if loadErr else "") + "corrected results failed · " + str(e);
        }
    }

    has_live = len(cells) > 0;
    has_sg = len(sgcells) > 0;
    has_v84 = len(v84cells) > 0;

    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="flex items-center justify-between border-b border-border px-4 py-2.5">
            <span className="micro-label">RESULTS · SFT/GRPO LADDER (live) + corrected + weekend archive</span>
            <span className="micro-label text-muted-foreground/80">{(str(len(cells)) + " cells") if has_live else "no ladder run yet"}</span>
        </div>

        {loadErr and <div key="reserr" className="border-b border-border px-4 py-1.5">
            <span className="stat-line" style={{"color": "var(--danger)"}}>{loadErr}</span>
        </div>}

        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            <div className="relative rounded-md border border-emerald-900/40 bg-card p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2 text-emerald-500/80">THE STORY · a measurement bug hid an 11%→94% Jac generator</span>
                <ResponsiveContainer width="100%" height={210}>
                    <LineChart data={corrJourney} margin={{"top": 14, "right": 20, "left": 0, "bottom": 0}}>
                        <CartesianGrid stroke={gridStroke()} vertical={False} />
                        <XAxis dataKey="stage" tick={{"fill": "var(--label)", "fontSize": 9, "fontFamily": MONO}} tickLine={False} axisLine={{"stroke": axisStroke()}} interval={0} />
                        <YAxis tick={tick()} tickLine={False} axisLine={False} width={40} domain={[0, 100]} ticks={PCT_TICKS} unit="%" />
                        <Tooltip cursor={FILL_CURSOR} contentStyle={tipContentStyle()} labelStyle={tipLabelStyle()} itemStyle={tipItemStyle()} />
                        <Line type="monotone" dataKey="acc" name="holdout accuracy %" stroke={chartColor(5)} strokeWidth={2} dot={{"r": 4, "fill": chartColor(5)}} isAnimationActive={False} />
                    </LineChart>
                </ResponsiveContainer>
            </div>

            <div className="relative rounded-md border border-emerald-900/40 bg-card p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2 text-emerald-500/80">CORRECTED LADDER · greedy vs pass@8 · pure-fn holdout (n=18) · jac-qwen3coder</span>
                <ResponsiveContainer width="100%" height={230}>
                    <BarChart data={corrLadder} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                        <CartesianGrid stroke={gridStroke()} vertical={False} />
                        <XAxis dataKey="cell" tick={tick()} tickLine={False} axisLine={{"stroke": axisStroke()}} />
                        <YAxis tick={tick()} tickLine={False} axisLine={False} width={40} domain={[0, 100]} ticks={PCT_TICKS} unit="%" />
                        <Tooltip cursor={FILL_CURSOR} contentStyle={tipContentStyle()} labelStyle={tipLabelStyle()} itemStyle={tipItemStyle()} />
                        <Legend wrapperStyle={{"fontFamily": MONO, "fontSize": 10, "color": "var(--muted-foreground)"}} />
                        <Bar dataKey="greedy" name="greedy pass@1" fill={chartColor(1)} isAnimationActive={False} />
                        <Bar dataKey="passk" name="pass@8 (~best-of-k)" fill={chartColor(5)} isAnimationActive={False} />
                    </BarChart>
                </ResponsiveContainer>
                <div className="stat-line mt-1 text-muted-foreground/80">SFT lifts greedy 39%→61% (peak rung-20); GRPO≈SFT; raw-GRPO=base. The v1 "SFT does nothing" was the eval bug.</div>
            </div>

            <div className="relative rounded-md border border-emerald-900/40 bg-card p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2 text-emerald-500/80">BEST-OF-K + COMPILER VERIFIER · base vs SFT · across 3 holdouts</span>
                <ResponsiveContainer width="100%" height={230}>
                    <BarChart data={corrHold} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                        <CartesianGrid stroke={gridStroke()} vertical={False} />
                        <XAxis dataKey="name" tick={tick()} tickLine={False} axisLine={{"stroke": axisStroke()}} />
                        <YAxis tick={tick()} tickLine={False} axisLine={False} width={40} domain={[0, 100]} ticks={PCT_TICKS} unit="%" />
                        <Tooltip cursor={FILL_CURSOR} contentStyle={tipContentStyle()} labelStyle={tipLabelStyle()} itemStyle={tipItemStyle()} />
                        <Legend wrapperStyle={{"fontFamily": MONO, "fontSize": 10, "color": "var(--muted-foreground)"}} />
                        <Bar dataKey="greedy_base" name="greedy·base" fill={chartColor(3)} isAnimationActive={False} />
                        <Bar dataKey="greedy_sft" name="greedy·SFT" fill={chartColor(1)} isAnimationActive={False} />
                        <Bar dataKey="bok_base" name="best-of-k·base" fill={chartColor(4)} isAnimationActive={False} />
                        <Bar dataKey="bok_sft" name="best-of-k·SFT" fill={chartColor(5)} isAnimationActive={False} />
                    </BarChart>
                </ResponsiveContainer>
                <div className="stat-line mt-1 text-muted-foreground/80">best-of-k+compiler-verifier is the universal win (deploy==oracle: the compiler is a perfect picker). Conversion+SFT peaks at 82%. Fresh model dead (gap 0). clean n=16 → 94%.</div>
            </div>

            <div className="relative rounded-md border border-emerald-900/40 bg-card p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2 text-emerald-500/80">SAMPLING BUDGET vs ACCURACY · more samples, more solved (compiler picks)</span>
                <ResponsiveContainer width="100%" height={200}>
                    <BarChart data={corrKscale} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                        <CartesianGrid stroke={gridStroke()} vertical={False} />
                        <XAxis dataKey="k" tick={tick()} tickLine={False} axisLine={{"stroke": axisStroke()}} />
                        <YAxis tick={tick()} tickLine={False} axisLine={False} width={40} domain={[0, 100]} ticks={PCT_TICKS} unit="%" />
                        <Tooltip cursor={FILL_CURSOR} contentStyle={tipContentStyle()} labelStyle={tipLabelStyle()} itemStyle={tipItemStyle()} />
                        <Bar dataKey="acc" name="pure-fn accuracy %" fill={chartColor(1)} isAnimationActive={False} />
                    </BarChart>
                </ResponsiveContainer>
                <div className="stat-line mt-1 text-muted-foreground/80">greedy 39% → k=8 72% → k=32 89%. The correct Jac is reachable; the compiler finds it among samples.</div>
            </div>

            <div className="mt-1 border-t border-border pt-2">
                <span className="micro-label text-amber-500/70">⚠️ ARCHIVE BELOW · INVALIDATED broken-eval runs (~3.5× undercount) · kept for record</span>
            </div>

            {(<div className="flex flex-col gap-4">
                {_ladderChart({"rows": curve, "keys": keys})}
                <div className="relative exp-panel p-3 pt-4">
                    <span className="micro-label absolute -top-2 left-3 bg-background px-2">LADDER CELLS</span>
                    <table className="w-full font-mono text-xs">
                        <thead>
                            <tr className="text-muted-foreground">
                                <th className="py-1 text-left">model</th><th className="text-left">rung</th>
                                <th className="text-left">cond</th><th className="text-right">gen@1</th>
                                <th className="text-right">gen@k</th><th className="text-right">mem</th>
                                <th className="text-right">n</th>
                            </tr>
                        </thead>
                        <tbody>
                            {for c in cells {
                                <tr key={str(c["model"]) + str(c["rung"]) + str(c["cond"])} className="border-t border-border text-foreground/80">
                                    <td className="py-1">{c["model"]}</td><td>{c["rung"]}</td>
                                    <td className="text-muted-foreground">{c["cond"]}</td>
                                    <td className="text-right text-foreground">{_n(c["gen_pass1"])}</td>
                                    <td className="text-right">{_n(c["gen_passk"])}</td>
                                    <td className="text-right text-muted-foreground">{_n(c["mem_pass1"])}</td>
                                    <td className="text-right text-muted-foreground/80">{c["n"] if c["n"] != None else "·"}</td>
                                </tr>
                            }}
                        </tbody>
                    </table>
                    <div className="stat-line mt-2 text-muted-foreground/80">gen=holdout (generalization), mem=train recall. Read pass@k, not bare pass@1 — n is small.</div>
                </div>
            </div>) if has_live else (<div className="relative exp-panel p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">LADDER</span>
                <p className="text-sm text-muted-foreground">No ladder results yet. Run <span className="font-mono text-foreground">JAC_LADDER_GO=1 jac run 02-rl-grpo/rl/run_ladder.jac</span> — cells stream into this graph as evals land.</p>
            </div>)}

            {(<div className="relative exp-panel p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">STEP 7 · SG-IDIOM HOLDOUT (sg walkers held out file-disjoint)</span>
                {_ladderChart({"rows": sgcurve, "keys": sgkeys})}
                <table className="mt-3 w-full font-mono text-xs">
                    <thead>
                        <tr className="text-muted-foreground">
                            <th className="py-1 text-left">model</th><th className="text-left">rung</th>
                            <th className="text-left">cond</th><th className="text-right">gen@1</th>
                            <th className="text-right">gen@k</th><th className="text-right">n</th>
                        </tr>
                    </thead>
                    <tbody>
                        {for c in sgcells {
                            <tr key={"sg" + str(c["model"]) + str(c["rung"]) + str(c["cond"])} className="border-t border-border text-foreground/80">
                                <td className="py-1">{c["model"]}</td><td>{c["rung"]}</td>
                                <td className="text-muted-foreground">{c["cond"]}</td>
                                <td className="text-right text-foreground">{_n(c["gen_pass1"])}</td>
                                <td className="text-right">{_n(c["gen_passk"])}</td>
                                <td className="text-right text-muted-foreground/80">{c["n"] if c["n"] != None else "·"}</td>
                            </tr>
                        }}
                    </tbody>
                </table>
                <div className="stat-line mt-2 text-muted-foreground/80">Held-out sg slice is the hard frontier (0/5 base). Fresh qwen3coder SFT at rung-all is the only cell to crack it: sg 0→1/5, overall 14.3%→28.6%.</div>
            </div>) if has_sg else <span></span>}

            {(<div className="relative exp-panel p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">84-TASK HIGHER-POWER RE-RUN (null reproduced on a 2nd corpus)</span>
                {_ladderChart({"rows": v84curve, "keys": v84keys})}
                <table className="mt-3 w-full font-mono text-xs">
                    <thead>
                        <tr className="text-muted-foreground">
                            <th className="py-1 text-left">model</th><th className="text-left">rung</th>
                            <th className="text-left">cond</th><th className="text-right">gen@1</th>
                            <th className="text-right">gen@k</th><th className="text-right">mem</th>
                            <th className="text-right">n</th>
                        </tr>
                    </thead>
                    <tbody>
                        {for c in v84cells {
                            <tr key={"v84" + str(c["model"]) + str(c["rung"]) + str(c["cond"])} className="border-t border-border text-foreground/80">
                                <td className="py-1">{c["model"]}</td><td>{c["rung"]}</td>
                                <td className="text-muted-foreground">{c["cond"]}</td>
                                <td className="text-right text-foreground">{_n(c["gen_pass1"])}</td>
                                <td className="text-right">{_n(c["gen_passk"])}</td>
                                <td className="text-right text-muted-foreground">{_n(c["mem_pass1"])}</td>
                                <td className="text-right text-muted-foreground/80">{c["n"] if c["n"] != None else "·"}</td>
                            </tr>
                        }}
                    </tbody>
                </table>
                <div className="stat-line mt-2 text-muted-foreground/80">Corpus squeezed 66→84 tasks for power. Same null: SFT moves cells, GRPO does not.</div>
            </div>) if has_v84 else <span></span>}

            <div className="mt-2 border-t border-border pt-3">
                <span className="micro-label text-muted-foreground">— WEEKEND ARCHIVE · GRPO + WARM-START + STaR (Jun 20–21) —</span>
            </div>

            <div className="relative exp-panel p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">RESULT (archive)</span>
                <p className="text-sm text-foreground/80">
                    Supervised levers (SFT, DPO, gold warm-start) move models here. <b>RL does not.</b> GRPO added nothing (confirmed by pass@8), STaR added a faint flicker that didn't hold, and the bigger Qwen3.6 models can't be trained on 48 GB.
                </p>
            </div>

            <div className="grid grid-cols-2 gap-4">
                {_archiveLine({"title": "STaR · pass@1 greedy · by round", "rows": STAR1})}
                {_archiveLine({"title": "STaR · pass@4 sampled · by round", "rows": STAR4})}
            </div>

            <div className="relative exp-panel p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">PHASE 1 · WARM-START LIFT · holdout pass%</span>
                <ResponsiveContainer width="100%" height={200}>
                    <BarChart data={PHASE1} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                        <CartesianGrid stroke={gridStroke()} vertical={False} />
                        <XAxis dataKey="model" tick={tick()} tickLine={False} axisLine={{"stroke": axisStroke()}} />
                        <YAxis tick={tick()} tickLine={False} axisLine={False} width={40} domain={[0, 100]} ticks={PCT_TICKS} unit="%" />
                        <Tooltip cursor={FILL_CURSOR} contentStyle={tipContentStyle()} labelStyle={tipLabelStyle()} itemStyle={tipItemStyle()} />
                        <Legend wrapperStyle={{"fontFamily": MONO, "fontSize": 10, "color": "var(--muted-foreground)"}} />
                        <Bar dataKey="BASE" fill={chartColor(1)} isAnimationActive={False} />
                        <Bar dataKey="WARM" fill={chartColor(0)} isAnimationActive={False} />
                        <Bar dataKey="GRPO" fill={chartColor(5)} isAnimationActive={False} />
                    </BarChart>
                </ResponsiveContainer>
            </div>

            <div className="relative exp-panel p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">FAILURES &amp; WHY (archive)</span>
                <div className="flex flex-col gap-2.5">
                    {for f in FAILS {
                        <div key={f["t"]} className="grid grid-cols-[200px_1fr] gap-3">
                            <span className="font-mono text-xs text-foreground/80">{f["t"]}</span>
                            <span className="stat-line text-muted-foreground">{f["b"]}</span>
                        </div>
                    }}
                </div>
            </div>
        </div>
    </div>;
}
