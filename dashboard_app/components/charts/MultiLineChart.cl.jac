"""Overlay line chart: one line per run, merged on x. Used by Monitor's compare view.
Each run gets a distinct color (the only color in the UI)."""

import from "recharts" { ResponsiveContainer, LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid, Legend }

def:pub MultiLineChart(title: str, data: list[dict], names: list[str], colors: list[str]) -> JsxElement {
    return <div className="dg-glass dg-chart">
        <div className="dg-chart-title">{title}</div>
        {len(data) == 0 and <div className="dg-chart-empty">no data yet</div>}
        {len(data) > 0 and <ResponsiveContainer width="100%" height={210}>
            <LineChart data={data} margin={{"top": 6, "right": 12, "left": 0, "bottom": 0}}>
                <CartesianGrid stroke="rgba(255,255,255,0.06)" strokeDasharray="3 3" vertical={False} />
                <XAxis dataKey="x" stroke="rgba(255,255,255,0.28)" tick={{"fill": "#7a7a85", "fontSize": 11}} tickLine={False} axisLine={False} />
                <YAxis stroke="rgba(255,255,255,0.28)" tick={{"fill": "#7a7a85", "fontSize": 11}} tickLine={False} axisLine={False} width={46} domain={["auto", "auto"]} />
                <Tooltip
                    contentStyle={{"background": "rgba(16,16,20,0.9)", "border": "1px solid rgba(255,255,255,0.14)", "borderRadius": "8px", "backdropFilter": "blur(8px)"}}
                    labelStyle={{"color": "#9a9aa5"}}
                    itemStyle={{"color": "#fafafa"}}
                />
                <Legend wrapperStyle={{"fontSize": "0.75rem", "color": "#9a9aa5"}} />
                {for (i, nm) in enumerate(names) {
                    <Line key={nm} type="monotone" dataKey={nm} stroke={colors[i % len(colors)]} strokeWidth={2} dot={False} isAnimationActive={False} connectNulls={True} />
                }}
            </LineChart>
        </ResponsiveContainer>}
    </div>;
}
