"""MonoChart — single (optionally dual) line chart. Ports ui/components/shared/mono-chart.tsx.

`data`/`secondary` are list[dict] of {x, y}. `expY` formats the Y axis as an
exponent (learning-rate panel). `live` marks the last point with a ReferenceDot.
"""

import from "recharts" {
    ResponsiveContainer, LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ReferenceDot
}

glob MONO: str = "'Geist Mono', ui-monospace, monospace";

def _tick() -> dict {
    return {"fill": "#666", "fontSize": 10, "fontFamily": MONO};
}

def:pub MonoChart(
    title: str, data: list[dict], secondary: list[dict], live: bool, accent: str, expY: bool
) -> JsxElement {
    # merge primary (y) + secondary (y2) by x, preserving data order (x is monotonic)
    rows: list[dict] = [];
    seen: dict = {};
    for pt in data {
        row = {"x": pt["x"], "y": pt["y"]};
        seen[pt["x"]] = row;
        rows.append(row);
    }
    for pt in secondary {
        if pt["x"] in seen {
            seen[pt["x"]]["y2"] = pt["y"];
        } else {
            rows.append({"x": pt["x"], "y2": pt["y"]});
        }
    }
    last: any = data[len(data) - 1] if len(data) > 0 else None;
    yfmt: any = (lambda v: any { return f"{v:.0e}"; }) if expY else None;

    return <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
        <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">{title}</span>
        {if len(data) == 0 {
            <div className="micro-label flex items-center justify-center" style={{"height": 180}}>NO SIGNAL</div>
            skip;
        }}
        {if len(data) > 0 {
            <ResponsiveContainer width="100%" height={180}>
                <LineChart data={rows} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                    <CartesianGrid stroke="#1c1c1f" vertical={False} />
                    <XAxis dataKey="x" tick={_tick()} tickLine={False} axisLine={{"stroke": "#333"}} />
                    <YAxis tick={_tick()} tickLine={False} axisLine={False} width={46} domain={["auto", "auto"]} tickFormatter={yfmt} />
                    <Tooltip cursor={{"stroke": "#333", "strokeDasharray": "3 3"}} contentStyle={{"background": "#0a0a0c", "border": "1px solid #333", "borderRadius": 0, "fontFamily": MONO, "fontSize": 11}} labelStyle={{"color": "#777"}} itemStyle={{"color": "#fafafa"}} />
                    <Line type="monotone" dataKey="y" stroke={accent} strokeWidth={1.4} dot={False} isAnimationActive={False} />
                    {secondary and len(secondary) > 0 and <Line type="monotone" dataKey="y2" stroke={accent} strokeWidth={1.4} strokeDasharray="5 3" dot={{"r": 2}} isAnimationActive={False} connectNulls={True} />}
                    {live and last and <ReferenceDot x={last["x"]} y={last["y"]} r={3} fill="#0a0a0a" stroke={accent} />}
                </LineChart>
            </ResponsiveContainer>
        }}
    </div>;
}
