"use client";
import {
  ResponsiveContainer,
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ReferenceDot,
} from "recharts";
import type { Pt } from "@/lib/api-train";

const MONO_FONT = "var(--font-geist-mono), monospace";
const TICK = { fill: "#666", fontSize: 10, fontFamily: MONO_FONT };

export function MonoChart({
  title,
  data,
  live,
  height = 180,
  yFmt,
  secondary,
}: {
  title: string;
  data: Pt[];
  live?: boolean;
  height?: number;
  yFmt?: (v: number) => string;
  secondary?: Pt[];
}) {
  const last = data.length > 0 ? data[data.length - 1] : null;

  // Merge primary + secondary into unified rows keyed by x
  const merged: Record<number, { x: number; y?: number; y2?: number }> = {};
  for (const pt of data) {
    merged[pt.x] = { ...merged[pt.x], x: pt.x, y: pt.y };
  }
  if (secondary) {
    for (const pt of secondary) {
      merged[pt.x] = { ...merged[pt.x], x: pt.x, y2: pt.y };
    }
  }
  const chartData = Object.values(merged).sort((a, b) => a.x - b.x);

  return (
    <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
      <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">{title}</span>
      {data.length === 0 ? (
        <div
          className="micro-label flex items-center justify-center"
          style={{ height }}
        >
          NO SIGNAL
        </div>
      ) : (
        <ResponsiveContainer width="100%" height={height}>
          <LineChart data={chartData} margin={{ top: 10, right: 14, left: 0, bottom: 0 }}>
            <CartesianGrid stroke="#1c1c1f" vertical={false} />
            <XAxis
              dataKey="x"
              tick={TICK}
              tickLine={false}
              axisLine={{ stroke: "#333" }}
            />
            <YAxis
              tick={TICK}
              tickLine={false}
              axisLine={false}
              width={46}
              domain={["auto", "auto"]}
              tickFormatter={yFmt}
            />
            <Tooltip
              contentStyle={{
                background: "#0a0a0c",
                border: "1px solid #333",
                borderRadius: 0,
                fontFamily: MONO_FONT,
                fontSize: 11,
              }}
              labelStyle={{ color: "#777" }}
              itemStyle={{ color: "#fafafa" }}
              cursor={{ stroke: "#333", strokeDasharray: "3 3" }}
            />
            <Line
              type="monotone"
              dataKey="y"
              stroke="#ededed"
              strokeWidth={1.4}
              dot={false}
              isAnimationActive={false}
            />
            {secondary && (
              <Line
                type="monotone"
                dataKey="y2"
                stroke="#ededed"
                strokeWidth={1.4}
                strokeDasharray="5 3"
                dot={{ r: 2 }}
                isAnimationActive={false}
                connectNulls
              />
            )}
            {live && last && (
              <ReferenceDot
                x={last.x}
                y={last.y}
                r={3}
                fill="#0a0a0a"
                stroke="#ededed"
              />
            )}
          </LineChart>
        </ResponsiveContainer>
      )}
    </div>
  );
}
