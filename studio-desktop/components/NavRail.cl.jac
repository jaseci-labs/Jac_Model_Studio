"""Left navigation rail — workspace switcher (top) + active workspace's sections.

Workspaces are read from the graph via ui_layout (root --> Workspace, SQLite-persisted).
Accent dots use --ws01/--ws02/--ws03 CSS vars (stamped on the shell root via data-ws).
"""

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
    onWorkspace: Callable[([str], None)], onSection: Callable[([str], None)],
    onSettings: Callable[[], None]
) -> JsxElement {
    wsList: list = list(layout["workspaces"]);
    secList: list = _sectionsFor(layout, workspace);
    return <nav className="flex w-40 shrink-0 flex-col border-r border-neutral-800 bg-[#0d0d0d] px-2 py-3">
        <span className="micro-label mb-4 px-2">JAC·ML STUDIO</span>
        <div className="flex flex-col gap-1">
            {for ws in wsList {
                wd = ws as dict;
                wid = str(wd["id"]);
                accent = str(wd["accent"]);
                <button
                    key={wid}
                    onClick={lambda (e: MouseEvent) { onWorkspace(wid); }}
                    className={"relative flex h-9 items-center gap-2.5 rounded-md px-3 transition-colors " + (
                        "bg-[#161616] text-neutral-100" if wid == workspace
                        else "text-neutral-500 hover:bg-[#121212] hover:text-neutral-300"
                    )}
                >
                    {wid == workspace and <span className="absolute left-0 top-2 bottom-2 w-[2px]" style={{"background": "var(--ws-accent)"}} />}
                    <span className="h-2 w-2 shrink-0 rounded-full" style={{"background": "var(--" + accent + ")", "opacity": (1.0 if wid == workspace else 0.4)}} />
                    <span className="font-mono text-[10px] tracking-[0.12em]">{wid} {str(wd["label"])}</span>
                </button>
            }}
        </div>
        <div className="dashed-rule my-3"></div>
        <div className="flex flex-col gap-1">
            {for sec in secList {
                sd = sec as dict;
                sid = str(sd["id"]);
                <button
                    key={sid}
                    onClick={lambda (e: MouseEvent) { onSection(sid); }}
                    className={"relative flex h-9 items-center gap-3 rounded-md px-3 transition-colors " + (
                        "bg-[#161616] text-neutral-100" if sid == section
                        else "text-neutral-600 hover:bg-[#121212] hover:text-neutral-300"
                    )}
                >
                    {sid == section and <span className="absolute left-0 top-2 bottom-2 w-[2px]" style={{"background": "var(--ws-accent)"}} />}
                    {_glyph(sid)}
                    <span className="font-mono text-[11px] tracking-[0.15em]">{str(sd["label"])}</span>
                </button>
            }}
        </div>
        <div className="flex-1" />
        <button
            onClick={lambda (e: MouseEvent) { onSettings(); }}
            className="mb-2 rounded-md px-2 py-1.5 text-left font-mono text-[10px] tracking-wider text-neutral-600 hover:bg-[#121212] hover:text-neutral-300"
        >⚙ WORKSPACES</button>
        <span className="micro-label px-2">v3</span>
    </nav>;
}
