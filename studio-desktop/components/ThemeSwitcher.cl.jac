"""ThemeSwitcher — one button toggling light/dark. Flips the `.dark` class on
<html> and persists to localStorage('jacml.mode'). All theming is CSS vars
(theme.css :root vs .dark), so no state reaches other components."""

def:pub ThemeSwitcher() -> JsxElement {
    has mode: str = "dark";

    can with entry {
        win: any = window;
        try {
            saved: any = win.localStorage.getItem("jacml.mode");
            if saved { mode = str(saved); }
        } except Exception { }
    }

    def toggle(e: MouseEvent) {
        nextMode: str = "light" if mode == "dark" else "dark";
        mode = nextMode;
        doc: any = document;
        win: any = window;
        if nextMode == "dark" { doc.documentElement.classList.add("dark"); }
        else { doc.documentElement.classList.remove("dark"); }
        try { win.localStorage.setItem("jacml.mode", nextMode); } except Exception { }
    }

    return <button
        onClick={toggle}
        className="jms-btn"
        title="toggle light / dark"
    >{"◐ DARK" if mode == "dark" else "◑ LIGHT"}</button>;
}
