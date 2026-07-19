"""LayoutSwitcher — picks the shell layout (sidebar style / top bar). Controlled
by AppShell (structure changes need a re-render up there, unlike themes which
are pure CSS); persists to localStorage("jacml.layout")."""

glob LAYOUTS: list[str] = ["rail", "icons", "cockpit", "topbar", "deck", "dock"];
glob BLURB: dict = {
    "rail": "compact sidebar",
    "icons": "icons only · max content",
    "cockpit": "wide sidebar · live status",
    "topbar": "nav on top · full width",
    "deck": "two-tier header · tabs",
    "dock": "floating bottom dock"
};

def:pub LayoutSwitcher(
    layout: str,
    onLayout: Callable[([str], None)],
    up: bool = True
) -> JsxElement {
    has open: bool = False;

    return <div className="relative">
        {open and <div className={"absolute left-0 z-50 flex w-52 flex-col gap-1 rounded-md border border-border bg-popover p-2 " + ("bottom-8" if up else "top-8")}>
            {for l in LAYOUTS {
                <button
                    key={l}
                    onClick={lambda e: MouseEvent { open = False; onLayout(l); }}
                    className={"flex flex-col items-start rounded-md border px-2 py-1 text-left transition-colors " + (
                        "border-ring bg-accent" if l == layout else "border-transparent hover:bg-muted"
                    )}
                >
                    <span className={"font-mono text-[10px] tracking-[0.12em] uppercase " + ("text-foreground" if l == layout else "text-muted-foreground")}>{l}</span>
                    <span className="stat-line">{str(BLURB[l])}</span>
                </button>
            }}
        </div>}
        <button
            onClick={lambda e: MouseEvent { open = not open; }}
            className="micro-label px-2 transition-colors hover:text-foreground/80"
        >
            LAYOUT · {layout}
        </button>
    </div>;
}
