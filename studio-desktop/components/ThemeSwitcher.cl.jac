"""ThemeSwitcher — flips the data-theme attribute on <html> and persists to
localStorage("jacml.theme"). All theming is CSS vars (global.css), so no state
needs to reach any other component; AppShell re-applies the stored theme at
boot (before NavRail mounts) to cover the loading/offline screens."""

glob THEMES: list[str] = [
    "terminal", "shadcn-light", "shadcn-dark", "linear", "paper", "gruvbox", "high-contrast"
];

def:pub ThemeSwitcher(up: bool = True) -> JsxElement {
    has open: bool = False,
        theme: str = "terminal";

    can with entry {
        win: any = window;
        try {
            saved: any = win.localStorage.getItem("jacml.theme");
            if saved { theme = str(saved); }
        } except Exception { }
    }

    def apply(t: str) {
        theme = t;
        open = False;
        doc: any = document;
        win: any = window;
        if t == "terminal" {
            doc.documentElement.removeAttribute("data-theme");
        } else {
            doc.documentElement.setAttribute("data-theme", t);
        }
        try {
            win.localStorage.setItem("jacml.theme", t);
        } except Exception { }
    }

    return <div className="relative">
        {open and <div className={"absolute left-0 z-50 flex w-36 flex-col gap-1 exp-panel !bg-popover p-2 " + ("bottom-8" if up else "top-8")}>
            {for t in THEMES {
                <button
                    key={t}
                    onClick={lambda (e: MouseEvent) { apply(t); }}
                    className={"exp-chip " + (
                        "exp-chip-active" if t == theme
                        else ""
                    )}
                >
                    {t}
                </button>
            }}
        </div>}
        <button
            onClick={lambda (e: MouseEvent) { open = not open; }}
            className="micro-label px-2 transition-colors hover:text-foreground/80"
        >
            THEME · {theme}
        </button>
    </div>;
}
