"""JmsShell — the JMS product surface. Placeholder for now: top bar (wordmark,
hub return, theme switcher) over an empty-state center. The project pipeline
(sources → generate → curate → train → eval) mounts here in the next phase."""

import from .JmsThemeSwitcher { JmsThemeSwitcher }

def:pub JmsShell(onHub: any = None, theme: str = "", onTheme: any = None) -> JsxElement {
    t: str = theme if theme else "electric-minimal";
    return <div
        className="jms-scope flex h-screen w-screen flex-col overflow-hidden"
        data-jms-theme={t}
    >
        <div className="jms-topbar">
            <div className="flex items-center gap-4">
                <span className="jms-label">JMS</span>
                <button
                    className="jms-btn"
                    title="back to hub"
                    onClick={lambda e: MouseEvent {
                        if onHub is not None { onHub(); }
                    }}
                >◈ HUB</button>
            </div>
            <JmsThemeSwitcher theme={t} onTheme={onTheme} />
        </div>

        <div className="jms-shell-empty">
            <span className="jms-display jms-shell-word">NO PROJECTS YET</span>
            <span className="jms-hero-sub" style={{"maxWidth": "48ch"}}>
                Project pipeline lands next: sources → generate → curate → train → eval.
            </span>
        </div>
    </div>;
}
