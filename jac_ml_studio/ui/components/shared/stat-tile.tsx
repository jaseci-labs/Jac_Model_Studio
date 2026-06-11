export function StatTile({
  label,
  value,
  sub,
  dim,
}: {
  label: string;
  value: string | number;
  sub?: string;
  dim?: boolean;
}) {
  return (
    <div className={`relative p-3 pt-4 ${dim ? "opacity-40" : ""}`}>
      {/* Corner brackets */}
      <span className="absolute left-0 top-0 h-[10px] w-[10px] border-l border-t border-neutral-600" />
      <span className="absolute right-0 top-0 h-[10px] w-[10px] border-r border-t border-neutral-600" />
      <span className="absolute bottom-0 left-0 h-[10px] w-[10px] border-b border-l border-neutral-600" />
      <span className="absolute bottom-0 right-0 h-[10px] w-[10px] border-b border-r border-neutral-600" />
      <div className="micro-label mb-1">{label}</div>
      <div className="font-mono text-xl text-neutral-100">{value}</div>
      {sub && <div className="stat-line mt-0.5">{sub}</div>}
    </div>
  );
}
