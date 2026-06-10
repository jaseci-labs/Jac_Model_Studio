"""Overlay line chart: one line per run, merged on x. Used by History's compare view.
HUD panel; each run keeps a distinct color from the compare palette."""

import from "recharts" { ResponsiveContainer, LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid, Legend }

def:pub MultiLineChart(title: str, data: list[dict], names: list[str], colors: list[str]) -> JsxElement {
    return <div className="dg-panel dg-chart">
        <span className="dg-panel-label">{title}</span>
        {len(data) == 0 and <div className="dg-chart-empty">NO SIGNAL</div>}
        {len(data) > 0 and <ResponsiveContainer width="100%" height={210}>
            <LineChart data={data} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                <CartesianGrid stroke="#1c1c1f" vertical={False} />
                <XAxis dataKey="x" tick={{"fill": "#666", "fontSize": 10, "fontFamily": "ui-monospace, Menlo, monospace"}} tickLine={False} axisLine={{"stroke": "#333"}} />
                <YAxis tick={{"fill": "#666", "fontSize": 10, "fontFamily": "ui-monospace, Menlo, monospace"}} tickLine={False} axisLine={False} width={46} domain={["auto", "auto"]} />
                <Tooltip
                    contentStyle={{"background": "#0a0a0c", "border": "1px solid #333", "borderRadius": "0px", "fontFamily": "ui-monospace, Menlo, monospace", "fontSize": "11px"}}
                    labelStyle={{"color": "#777"}}
                    itemStyle={{"color": "#fafafa"}}
                />
                <Legend wrapperStyle={{"fontSize": "0.72rem", "color": "#9a9aa5", "fontFamily": "ui-monospace, Menlo, monospace"}} />
                {for (i, nm) in enumerate(names) {
                    <Line key={nm} type="monotone" dataKey={nm} stroke={colors[i % len(colors)]} strokeWidth={1.4} dot={False} isAnimationActive={False} connectNulls={True} />
                }}
            </LineChart>
        </ResponsiveContainer>}
    </div>;
}
