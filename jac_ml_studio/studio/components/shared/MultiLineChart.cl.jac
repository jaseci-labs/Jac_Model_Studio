"""MultiLineChart — N overlaid lines (one per run). Ports ui/components/shared/multi-line-chart.tsx.

`rows` is list[dict] each keyed by "x" plus one key per name in `names`.
"""

import from "recharts" {
    ResponsiveContainer, LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip
}

glob MONO2: str = "ui-monospace, monospace";
glob HUES: list[str] = ["#7aa2f7", "#d8a657", "#9ec98f", "#b89ce8", "#6fc3b2", "#e08a8a"];

def _tick2() -> dict {
    return {"fill": "#666", "fontSize": 10, "fontFamily": MONO2};
}

def:pub MultiLineChart(title: str, rows: list[dict], names: list[str]) -> JsxElement {
    return <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
        <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">{title}</span>
        {if len(rows) == 0 {
            <div className="micro-label flex items-center justify-center" style={{"height": 180}}>NO SIGNAL</div>
            skip;
        }}
        {if len(rows) > 0 {
            <ResponsiveContainer width="100%" height={180}>
                <LineChart data={rows} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                    <CartesianGrid stroke="#1c1c1f" vertical={False} />
                    <XAxis dataKey="x" tick={_tick2()} tickLine={False} axisLine={{"stroke": "#333"}} />
                    <YAxis tick={_tick2()} tickLine={False} axisLine={False} width={46} domain={["auto", "auto"]} />
                    <Tooltip contentStyle={{"background": "#0a0a0c", "border": "1px solid #333", "borderRadius": 0, "fontFamily": MONO2, "fontSize": 11}} labelStyle={{"color": "#777"}} itemStyle={{"color": "#fafafa"}} />
                    {for (i, name) in enumerate(names) {
                        <Line key={name} type="monotone" dataKey={name} stroke={HUES[i % len(HUES)]} strokeWidth={1.4} dot={False} isAnimationActive={False} connectNulls={True} />
                    }}
                </LineChart>
            </ResponsiveContainer>
        }}
        <div className="mt-2 flex flex-wrap gap-3">
            {for (i, name) in enumerate(names) {
                <span key={name} className="stat-line" style={{"color": HUES[i % len(HUES)]}}>── {name}</span>
            }}
        </div>
    </div>;
}
