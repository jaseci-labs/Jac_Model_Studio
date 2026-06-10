"""A single labelled Recharts line chart over a [{x, y}, ...] series.
Glass card; the stroke color is the only color in the whole UI."""

import from "recharts" { ResponsiveContainer, LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid }

def:pub MetricChart(title: str, data: list[dict], color: str) -> JsxElement {
    return <div className="dg-glass dg-chart">
        <div className="dg-chart-title">{title}</div>
        {len(data) == 0 and <div className="dg-chart-empty">no data yet</div>}
        {len(data) > 0 and <ResponsiveContainer width="100%" height={168}>
            <LineChart data={data} margin={{"top": 6, "right": 12, "left": 0, "bottom": 0}}>
                <CartesianGrid stroke="rgba(255,255,255,0.06)" strokeDasharray="3 3" vertical={False} />
                <XAxis dataKey="x" stroke="rgba(255,255,255,0.28)" tick={{"fill": "#7a7a85", "fontSize": 11}} tickLine={False} axisLine={False} />
                <YAxis stroke="rgba(255,255,255,0.28)" tick={{"fill": "#7a7a85", "fontSize": 11}} tickLine={False} axisLine={False} width={46} domain={["auto", "auto"]} />
                <Tooltip
                    contentStyle={{"background": "rgba(16,16,20,0.9)", "border": "1px solid rgba(255,255,255,0.14)", "borderRadius": "8px", "backdropFilter": "blur(8px)"}}
                    labelStyle={{"color": "#9a9aa5"}}
                    itemStyle={{"color": "#fafafa"}}
                />
                <Line type="monotone" dataKey="y" stroke={color} strokeWidth={2} dot={False} isAnimationActive={False} />
            </LineChart>
        </ResponsiveContainer>}
    </div>;
}
