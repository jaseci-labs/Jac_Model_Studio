function lineClass(ln: string): string {
  if (/error|✗|Traceback/i.test(ln)) return "text-neutral-100";
  if (ln.startsWith(">>>")) return "text-neutral-300";
  return "text-neutral-500";
}

export function LogView({
  text,
  maxH = "16rem",
}: {
  text: string;
  maxH?: string;
}) {
  const lines = text.split("\n").reverse();
  return (
    <pre
      className="flex flex-col-reverse overflow-y-auto rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 font-mono text-[11px] leading-relaxed"
      style={{ maxHeight: maxH }}
    >
      {lines.map((ln, i) => (
        <div key={i} className={lineClass(ln)}>
          {ln || " "}
        </div>
      ))}
    </pre>
  );
}
