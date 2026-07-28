"""SubTabs — dot-separated tab strip. Ports ui/components/shared/sub-tabs.tsx.

The active tab was signalled by colour + underline ONLY, so a screen reader read
four identical buttons. `aria-current` carries that state non-visually; the `·`
separators are decorative and hidden. Prop shape unchanged (Cloud/Train pass
tabs/active/onTab)."""

def:pub SubTabs(tabs: list[str], active: str, onTab: Callable[([str], None)]) -> JsxElement {
    return <div className="flex items-center gap-0 border-b border-border pb-0">
        {for (i, t) in enumerate(tabs) {
            <span key={t} className="flex items-center">
                {i > 0 and <span aria-hidden={True} className="micro-label px-2 text-muted-foreground/60">·</span>}
                <button
                    aria-current={"true" if active == t else "false"}
                    onClick={lambda (e: MouseEvent) { onTab(t); }}
                    className={"micro-label pb-1 transition-colors hover:text-foreground/80 " + (
                        "border-b-2 border-accent text-foreground" if active == t
                        else "text-muted-foreground/80"
                    )}
                >
                    {t}
                </button>
            </span>
        }}
    </div>;
}
