"""Left section sidebar — the active workspace's sections (CHAT/DATA/TRAIN/…).

The workspace switcher now lives in the top <WorkspaceBar/>; this rail carries only
the section tiles for whichever workspace is active, one per row. Sections are read
from the graph via ui_layout (root --> Workspace --> Section). The active tile marks
itself with a --ws-accent bar (stamped on the shell root via data-ws)."""

def _glyph(s: str) -> JsxElement {
    if s == "chat" {
        return <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
            <path d="M2 3h12v8H6l-3 3v-3H2z" strokeLinejoin="miter" />
        </svg>;
    }
    if s == "train" {
        return <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
            <path d="M2 13h12" stroke="#444" />
            <path d="M2 3c3 0 3 7 6 7 2 0 3-2 6-2" />
        </svg>;
    }
    if s == "data" {
        return <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
            <rect x="3" y="2" width="10" height="3.4" />
            <rect x="3" y="6.3" width="10" height="3.4" />
            <rect x="3" y="10.6" width="10" height="3.4" />
        </svg>;
    }
    if s == "evals" {
        return <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
            <rect x="2.5" y="2.5" width="5" height="5" />
            <rect x="8.5" y="2.5" width="5" height="5" />
            <rect x="2.5" y="8.5" width="5" height="5" />
            <path d="M9.5 11l1.5 1.5L13.5 9" />
        </svg>;
    }
    if s == "generate" {
        return <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
            <rect x="2" y="2.5" width="12" height="11" rx="1" />
            <path d="M6.5 5.5l4 2.5-4 2.5z" fill="currentColor" stroke="none" />
        </svg>;
    }
    if s == "plan" {
        return <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
            <path d="M3 4h7M3 8h5M3 12h4" />
            <path d="M10.5 11.5l1.5 1.5L14.5 10" />
        </svg>;
    }
    if s == "cloud" {
        return <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
            <path d="M4.5 11.5h7a2.5 2.5 0 000-5 3 3 0 00-5.8-1A2.2 2.2 0 004.5 11.5z" />
        </svg>;
    }
    # results (also the old rl fallback): sparkline + point
    return <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
        <path d="M2 13h12" stroke="#444" />
        <path d="M2 11l3-3 3 2 5-6" strokeLinejoin="miter" />
        <circle cx="13" cy="4" r="1.2" fill="currentColor" stroke="none" />
    </svg>;
}

def _sectionsFor(layout: any, workspace: str) -> list {
    for ws in list(layout["workspaces"]) {
        wd = ws as dict;
        if str(wd["id"]) == workspace {
            return list(wd["sections"]);
        }
    }
    return [];
}

def:pub NavRail(
    layout: any, workspace: str, section: str,
    onSection: Callable[([str], None)]
) -> JsxElement {
    secList: list = _sectionsFor(layout, workspace);
    return <nav className="flex w-40 shrink-0 flex-col border-r border-border bg-card px-2 py-3">
        <div className="flex flex-col gap-1">
            {for sec in secList {
                sd = sec as dict;
                sid = str(sd["id"]);
                <button
                    key={sid}
                    onClick={lambda e: MouseEvent { onSection(sid); }}
                    className={"exp-hoverable relative flex h-9 items-center gap-3 rounded-lg border px-3 " + (
                        "border-border bg-accent/15 text-foreground" if sid == section
                        else "border-transparent text-muted-foreground/80 hover:text-foreground"
                    )}
                >
                    {sid == section and <span className="absolute left-0 top-2 bottom-2 w-[2px]" style={{"background": "var(--ws-accent)"}} />}
                    {_glyph({"s": sid})}
                    <span className="font-mono text-[11px] tracking-[0.15em]">{str(sd["label"])}</span>
                </button>
            }}
        </div>
        <div className="flex-1" />
        <span className="micro-label px-2">v3</span>
    </nav>;
}
