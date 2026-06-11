"use client";
import {
  ResponsiveContainer,
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
} from "recharts";
import type { CompareRow } from "@/lib/api-train";

const MONO_FONT = "var(--font-geist-mono), monospace";
const TICK = { fill: "#666", fontSize: 10, fontFamily: MONO_FONT };

const STROKES = ["#ededed", "#8a8a8a", "#525252", "#b8b8b8"];
const DASHES = ["", "5 3", "1 3", "7 2 1 2"];

export function MultiLineChart({
  title,
  rows,
  names,
  height = 180,
}: {
  title: string;
  rows: CompareRow[];
  names: string[];
  height?: number;
}) {
  return (
    <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
      <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">{title}</span>
      {rows.length === 0 ? (
        <div
          className="micro-label flex items-center justify-center"
          style={{ height }}
        >
          NO SIGNAL
        </div>
      ) : (
        <>
          <ResponsiveContainer width="100%" height={height}>
            <LineChart data={rows} margin={{ top: 10, right: 14, left: 0, bottom: 0 }}>
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
              {names.map((name, i) => (
                <Line
                  key={name}
                  type="monotone"
                  dataKey={name}
                  stroke={STROKES[i % STROKES.length]}
                  strokeWidth={1.4}
                  strokeDasharray={DASHES[i % DASHES.length]}
                  dot={false}
                  isAnimationActive={false}
                  connectNulls
                />
              ))}
            </LineChart>
          </ResponsiveContainer>
          {/* Legend */}
          <div className="mt-2 flex flex-wrap gap-3">
            {names.map((name, i) => (
              <span
                key={name}
                className="stat-line"
                style={{ color: STROKES[i % STROKES.length] }}
              >
                ── {name}
              </span>
            ))}
          </div>
        </>
      )}
    </div>
  );
}
