"""JmsThemeSwitcher — inline row of five two-tone theme swatches.

Each dot is the theme's bg+accent (fixed colors in jms.css, independent of the
active tokens); the active one is ringed with the current accent and its name
prints beside the row. Clicking calls onTheme(name) — persistence lives in the
frontend gate, not here. Renders inside .jms-scope in every JMS surface."""

glob JMS_THEMES: list[str] = [
    "electric-minimal", "warm-industrial", "bright-lab", "phosphor", "print-shop"
];

def:pub JmsThemeSwitcher(theme: str = "", onTheme: any = None) -> JsxElement {
    active: str = theme if theme else "electric-minimal";
    return <div className="jms-switcher">
        <span className="jms-switcher-name">{active}</span>
        {for t in JMS_THEMES {
            <button
                key={t}
                title={t}
                aria-label={"theme: " + t}
                onClick={lambda e: MouseEvent {
                    if onTheme is not None { onTheme(t); }
                }}
                className={"jms-swatch jms-swatch-" + t + (
                    " jms-swatch-active" if t == active else ""
                )}
            />
        }}
    </div>;
}
