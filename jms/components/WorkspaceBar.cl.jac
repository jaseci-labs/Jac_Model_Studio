"""Top workspace bar — horizontal workspace switcher across the app's top edge.

Workspaces are read from the graph via ui_layout (root --> Workspace, SQLite-persisted)
and rendered fully dynamically (3, 4, … up to the --ws0N tokens defined in global.css),
never a hardcoded id list. Accent dots use --ws01/--ws02/… CSS vars and the active
underline uses --ws-accent (stamped on the shell root via data-ws) — the exact same
accent mechanism the old vertical rail used, only laid out horizontally. Settings (⚙
WORKSPACES) sits at the right, mirroring the JMS top bar's right-side action group.

`onKeys` is optional: when a caller passes it (JMS does, for its ⚙ KEYS provider-key
modal), a `⚙ KEYS` button renders just before ⚙ WORKSPACES. Experiments doesn't pass
it, so its bar is unchanged.

`onAssistant` is optional too (phase-2 task A6): when a caller passes it, a
`✦ ASK` button renders in the right group (before ⚙ KEYS/⚙ WORKSPACES) that
toggles the shell-level `<AssistantPanel>`. Both JmsShell and AppShell pass it,
so the grounded assistant is reachable from either surface via the same bar."""

import from .ThemeSwitcher { ThemeSwitcher }

def:pub WorkspaceBar(
    layout: any, workspace: str,
    onWorkspace: Callable[([str], None)], onSettings: Callable[[], None],
    onHub: any = None, backLabel: str = "‹ EXPERIMENTS", onKeys: any = None,
    onAssistant: any = None
) -> JsxElement {
    wsList: list = list(layout["workspaces"]);
    return <header className="exp-topbar">
        <div className="flex min-w-0 items-center gap-4">
            <button
                className="exp-btn shrink-0"
                title="back to hub"
                onClick={lambda e: MouseEvent { if onHub is not None { onHub(); } }}
            >{backLabel}</button>
            <div className="flex min-w-0 items-center gap-1.5 overflow-x-auto">
                {for ws in wsList {
                    wd = ws as dict;
                    wid = str(wd["id"]);
                    accent = str(wd["accent"]);
                    <button
                        key={wid}
                        onClick={lambda e: MouseEvent { onWorkspace(wid); }}
                        className={"exp-hoverable relative flex h-8 shrink-0 items-center gap-2 rounded-lg border px-3 " + (
                            "border-border bg-accent/15 text-foreground" if wid == workspace
                            else "border-transparent text-muted-foreground hover:text-foreground"
                        )}
                    >
                        {wid == workspace and <span className="absolute inset-x-2 bottom-0 h-[2px]" style={{"background": "var(--ws-accent)"}} />}
                        <span className="h-2 w-2 shrink-0 rounded-full" style={{"background": "var(--" + accent + ")", "opacity": (1.0 if wid == workspace else 0.4)}} />
                        <span className="font-mono text-[10px] tracking-[0.12em] whitespace-nowrap">{wid} {str(wd["label"])}</span>
                    </button>
                }}
            </div>
        </div>
        <div className="flex shrink-0 items-center gap-2">
            <ThemeSwitcher />
            {onAssistant is not None and <button
                onClick={lambda e: MouseEvent { onAssistant(); }}
                className="exp-btn exp-btn-accent shrink-0"
            >✦ ASK</button>}
            {onKeys is not None and <button
                onClick={lambda e: MouseEvent { onKeys(); }}
                className="exp-btn exp-btn-ghost shrink-0"
            >⚙ KEYS</button>}
            <button
                onClick={lambda e: MouseEvent { onSettings(); }}
                className="exp-btn exp-btn-ghost shrink-0"
            >⚙ WORKSPACES</button>
        </div>
    </header>;
}
