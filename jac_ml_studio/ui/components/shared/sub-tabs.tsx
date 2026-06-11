export function SubTabs({
  tabs,
  active,
  onTab,
}: {
  tabs: string[];
  active: string;
  onTab: (t: string) => void;
}) {
  return (
    <div className="flex items-center gap-0 border-b border-neutral-800 pb-0">
      {tabs.map((t, i) => (
        <span key={t} className="flex items-center">
          {i > 0 && <span className="micro-label px-2 text-neutral-700">·</span>}
          <button
            onClick={() => onTab(t)}
            className={`micro-label pb-1 transition-colors hover:text-neutral-300 ${
              active === t
                ? "border-b-2 border-neutral-400 text-neutral-100"
                : "text-neutral-600"
            }`}
          >
            {t}
          </button>
        </span>
      ))}
    </div>
  );
}
