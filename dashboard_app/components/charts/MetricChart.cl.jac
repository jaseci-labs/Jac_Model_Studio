"""A single labelled Recharts line chart over a [{x, y}, ...] series.
HUD panel; white stroke default, green ReferenceDot marks the live tip."""

import from "recharts" { ResponsiveContainer, LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid, ReferenceDot }

def:pub MetricChart(title: str, data: list[dict], color: str, live: bool) -> JsxElement {
    n: int = len(data);
    return <div className="dg-panel dg-chart">
        <span className="dg-panel-label">{title}</span>
        {n == 0 and <div className="dg-chart-empty">NO SIGNAL</div>}
        {n > 0 and <ResponsiveContainer width="100%" height={180}>
            <LineChart data={data} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                <CartesianGrid stroke="#1c1c1f" vertical={False} />
                <XAxis dataKey="x" tick={{"fill": "#666", "fontSize": 10, "fontFamily": "ui-monospace, Menlo, monospace"}} tickLine={False} axisLine={{"stroke": "#333"}} />
                <YAxis tick={{"fill": "#666", "fontSize": 10, "fontFamily": "ui-monospace, Menlo, monospace"}} tickLine={False} axisLine={False} width={46} domain={["auto", "auto"]} />
                <Tooltip
                    contentStyle={{"background": "#0a0a0c", "border": "1px solid #333", "borderRadius": "0px", "fontFamily": "ui-monospace, Menlo, monospace", "fontSize": "11px"}}
                    labelStyle={{"color": "#777"}}
                    itemStyle={{"color": "#fafafa"}}
                />
                <Line type="monotone" dataKey="y" stroke={color} strokeWidth={1.4} dot={False} isAnimationActive={False} />
                {live and <ReferenceDot x={data[n - 1]["x"]} y={data[n - 1]["y"]} r={3} fill="none" stroke="#4ade80" strokeWidth={1.5} />}
            </LineChart>
        </ResponsiveContainer>}
    </div>;
}
