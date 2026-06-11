const GLYPHS: Record<string, string> = {
  idle: "○",
  running: "⦿",
  done: "✓",
  failed: "✗",
  stopped: "◌",
  finished: "✓",
};

const CLASSES: Record<string, string> = {
  idle: "text-neutral-600",
  running: "text-neutral-100 pulse",
  done: "text-neutral-100",
  failed: "text-neutral-100",
  stopped: "text-neutral-600",
  finished: "text-neutral-100",
};

export function StatusGlyph({
  status,
  showLabel = true,
}: {
  status: string;
  showLabel?: boolean;
}) {
  const glyph = GLYPHS[status] ?? "○";
  const cls = CLASSES[status] ?? "text-neutral-600";
  const isFailed = status === "failed";

  return (
    <span
      className={`font-mono text-[10px] tracking-widest ${cls} ${isFailed ? "border-b border-dashed border-neutral-500" : ""}`}
    >
      {glyph}
      {showLabel && ` ${status.toUpperCase()}`}
    </span>
  );
}
