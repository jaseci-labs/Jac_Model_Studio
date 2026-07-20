"""SubTabs — dot-separated tab strip. Ports ui/components/shared/sub-tabs.tsx."""

def:pub SubTabs(tabs: list[str], active: str, onTab: Callable[([str], None)]) -> JsxElement {
    return <div className="flex items-center gap-0 border-b border-neutral-800 pb-0">
        {for (i, t) in enumerate(tabs) {
            <span key={t} className="flex items-center">
                {i > 0 and <span className="micro-label px-2 text-neutral-700">·</span>}
                <button
                    onClick={lambda (e: MouseEvent) { onTab(t); }}
                    className={"micro-label pb-1 transition-colors hover:text-neutral-300 " + (
                        "border-b-2 border-neutral-400 text-neutral-100" if active == t
                        else "text-neutral-600"
                    )}
                >
                    {t}
                </button>
            </span>
        }}
    </div>;
}
