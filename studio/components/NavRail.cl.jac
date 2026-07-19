"""App navigation — four switchable layouts (LayoutSwitcher):
  rail    · the classic compact left sidebar (default)
  icons   · slim icon-only sidebar, maximum content width
  cockpit · wide left sidebar with a live status block (resident model + RAM)
  topbar  · horizontal bar on top, nav inline, full-width content
Workspace tiles carry a per-workspace accent dot; the active item gets an
accent bar. All colors are theme tokens."""

import from .ThemeSwitcher { ThemeSwitcher }
import from .LayoutSwitcher { LayoutSwitcher }

glob WS_ORDER: list[str] = ["01", "02", "03"];
glob WS_NAME: dict = {"01": "SFT/DPO", "02": "RL/GRPO", "03": "CPT"};
glob WS_DOT: dict = {"01": "var(--ws01)", "02": "var(--ws02)", "03": "var(--ws03)"};
# Uniform: every workspace exposes the same five sections. What each page shows
# is workspace-specific (01 results = eval runs; 02 train = the deployed
# best-of-k generator, GRPO trained offline; 03 results = CPT run compare).
glob SECTIONS: dict = {
    "01": ["chat", "data", "train", "results", "plan"],
    "02": ["chat", "data", "train", "results", "plan"],
    "03": ["chat", "data", "train", "results", "plan"]
};
glob LABELS: dict = {
    "chat": "CHAT", "data": "DATA", "train": "TRAIN",
    "results": "RESULTS", "plan": "PLAN"
};

# props-component convention: called as {_glyph({"s": ...})} from JSX, so the
# param is optional any and arrives as the mapped prop value at runtime.
def _glyph(s: any = None) -> JsxElement {
    if s == "chat" {
        return <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
            <path d="M2 3h12v8H6l-3 3v-3H2z" strokeLinejoin="miter" />
        </svg>;
    }
    if s == "train" {
        return <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
            <path d="M2 13h12" stroke="var(--input)" />
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
    # results: sparkline + point
    return <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
        <path d="M2 13h12" stroke="var(--input)" />
        <path d="M2 11l3-3 3 2 5-6" strokeLinejoin="miter" />
        <circle cx="13" cy="4" r="1.2" fill="currentColor" stroke="none" />
    </svg>;
}

def WsBtn(w: any = None, workspace: any = None, onWorkspace: any = None, slim: any = None, horizontal: any = None) -> JsxElement {
    active = str(w) == str(workspace);
    base = "relative flex items-center rounded-md transition-colors ";
    shape = "h-9 gap-2.5 px-3 " if not slim else "h-9 justify-center px-0 ";
    if horizontal { shape = "h-8 gap-2 px-2.5 "; }
    tone = "bg-muted text-foreground" if active else "text-muted-foreground hover:bg-popover hover:text-foreground/80";
    return <button
        key={str(w)}
        title={str(w) + " " + str(WS_NAME[str(w)])}
        onClick={lambda e: MouseEvent { onWorkspace(str(w)); }}
        className={base + shape + tone}
    >
        {active and not horizontal and <span className="absolute left-0 top-2 bottom-2 w-[2px]" style={{"background": "var(--ws-accent)"}} />}
        <span className="h-2 w-2 shrink-0 rounded-full" style={{"background": str(WS_DOT[str(w)]), "opacity": (1.0 if active else 0.4)}} />
        {not slim and <span className="font-mono text-[10px] tracking-[0.12em]">{str(w)} {str(WS_NAME[str(w)])}</span>}
    </button>;
}

def SecBtn(s: any = None, section: any = None, onSection: any = None, slim: any = None, horizontal: any = None) -> JsxElement {
    active = str(s) == str(section);
    base = "relative flex items-center rounded-md transition-colors ";
    shape = "h-9 gap-3 px-3 " if not slim else "h-9 justify-center px-0 ";
    if horizontal { shape = "h-8 gap-2 px-2.5 "; }
    tone = "bg-muted text-foreground" if active else "text-muted-foreground/70 hover:bg-popover hover:text-foreground/80";
    return <button
        key={str(s)}
        title={str(LABELS[str(s)])}
        onClick={lambda e: MouseEvent { onSection(str(s)); }}
        className={base + shape + tone}
    >
        {active and not horizontal and <span className="absolute left-0 top-2 bottom-2 w-[2px]" style={{"background": "var(--ws-accent)"}} />}
        {_glyph({"s": str(s)})}
        {not slim and <span className="font-mono text-[11px] tracking-[0.15em]">{LABELS[str(s)]}</span>}
    </button>;
}

"""Live status block for the cockpit layout: resident model + RAM bar."""
def StatusBlock(info: any = None, ramGb: any = None) -> JsxElement {
    d: any = info or {};
    mid = str(d.get("id", "") or "") if d else "";
    used = float(str(d.get("resident_gb", 0.0) or 0.0)) if d else 0.0;
    total = float(str(ramGb or 0.0));
    pct = 0.0;
    if total > 0.0 { pct = used / total * 100.0; }
    if pct > 100.0 { pct = 100.0; }
    return <div className="relative mt-3 rounded-md border border-border bg-card p-3 pt-4">
        <span className="micro-label absolute -top-2 left-3 bg-card px-2">STATUS</span>
        <div className="stat-line">model</div>
        <div className="truncate font-mono text-[11px] text-foreground">{mid if mid else "none loaded"}</div>
        <div className="stat-line mt-2">memory · {f"{used:.1f}"} / {str(int(total))} GB</div>
        <div className="mt-1 h-1 w-full rounded bg-muted">
            <div className="h-1 rounded bg-primary" style={{"width": f"{pct:.0f}%"}} />
        </div>
    </div>;
}

def:pub NavRail(
    workspace: str, section: str,
    onWorkspace: Callable[([str], None)], onSection: Callable[([str], None)],
    layout: str = "rail",
    onLayout: Callable[([str], None)] = None,
    loadedInfo: any = None,
    ramGb: float = 0.0
) -> JsxElement {
    slim = layout == "icons";

    if layout == "topbar" {
        return <nav className="flex h-12 w-full shrink-0 items-center gap-1 border-b border-border bg-card px-3">
            <span className="micro-label mr-3">JAC·ML STUDIO</span>
            {for w in WS_ORDER {
                <WsBtn key={w} w={w} workspace={workspace} onWorkspace={onWorkspace} slim={False} horizontal={True} />
            }}
            <div className="mx-2 h-5 w-px bg-border" />
            {for s in list(SECTIONS[workspace]) {
                <SecBtn key={s} s={s} section={section} onSection={onSection} slim={False} horizontal={True} />
            }}
            <div className="flex-1" />
            {onLayout and <LayoutSwitcher layout={layout} onLayout={onLayout} up={False} />}
            <ThemeSwitcher up={False} />
        </nav>;
    }

    if layout == "deck" {
        # two-tier header: row 1 = brand + workspaces + switchers, row 2 = the
        # active workspace's sections as underline tabs.
        return <nav className="flex w-full shrink-0 flex-col border-b border-border bg-card">
            <div className="flex h-11 items-center gap-1 border-b border-border/50 px-3">
                <span className="micro-label mr-3">JAC·ML STUDIO</span>
                {for w in WS_ORDER {
                    <WsBtn key={w} w={w} workspace={workspace} onWorkspace={onWorkspace} slim={False} horizontal={True} />
                }}
                <div className="flex-1" />
                {onLayout and <LayoutSwitcher layout={layout} onLayout={onLayout} up={False} />}
                <ThemeSwitcher up={False} />
            </div>
            <div className="flex items-center gap-4 px-4">
                {for s in list(SECTIONS[workspace]) {
                    <button
                        key={s}
                        onClick={lambda e: MouseEvent { onSection(str(s)); }}
                        className={"flex items-center gap-2 border-b-2 px-1 py-2 font-mono text-[11px] tracking-[0.15em] transition-colors " + (
                            "border-current text-foreground" if str(s) == str(section)
                            else "border-transparent text-muted-foreground/70 hover:text-foreground/80"
                        )}
                        style={{"borderBottomColor": "var(--ws-accent)"} if str(s) == str(section) else {}}
                    >
                        {_glyph({"s": str(s)})}{LABELS[str(s)]}
                    </button>
                }}
            </div>
        </nav>;
    }

    if layout == "dock" {
        # floating bottom dock; content runs full-bleed behind/above it.
        return <nav className="fixed bottom-4 left-1/2 z-40 flex -translate-x-1/2 items-center gap-1 rounded-xl border border-border bg-popover px-2 py-1.5 shadow-lg">
            {for w in WS_ORDER {
                <WsBtn key={w} w={w} workspace={workspace} onWorkspace={onWorkspace} slim={True} horizontal={True} />
            }}
            <div className="mx-1 h-5 w-px bg-border" />
            {for s in list(SECTIONS[workspace]) {
                <SecBtn key={s} s={s} section={section} onSection={onSection} slim={True} horizontal={True} />
            }}
            <div className="mx-1 h-5 w-px bg-border" />
            {onLayout and <LayoutSwitcher layout={layout} onLayout={onLayout} />}
            <ThemeSwitcher />
        </nav>;
    }

    width = "w-40";
    if slim { width = "w-14"; }
    if layout == "cockpit" { width = "w-64"; }

    return <nav className={"flex shrink-0 flex-col border-r border-border bg-card px-2 py-3 " + width}>
        <span className={"micro-label mb-4 " + ("px-0 text-center" if slim else "px-2")}>{"J·ML" if slim else "JAC·ML STUDIO"}</span>
        <div className="flex flex-col gap-1">
            {for w in WS_ORDER {
                <WsBtn key={w} w={w} workspace={workspace} onWorkspace={onWorkspace} slim={slim} horizontal={False} />
            }}
        </div>
        <div className="dashed-rule my-3"></div>
        <div className="flex flex-col gap-1">
            {for s in list(SECTIONS[workspace]) {
                <SecBtn key={s} s={s} section={section} onSection={onSection} slim={slim} horizontal={False} />
            }}
        </div>
        {layout == "cockpit" and <StatusBlock info={loadedInfo} ramGb={ramGb} />}
        <div className="flex-1" />
        {not slim and <div className="mb-1"><LayoutSwitcher layout={layout} onLayout={onLayout} /></div>}
        {not slim and <div className="mb-2"><ThemeSwitcher /></div>}
        {slim and <div className="mb-1"><LayoutSwitcher layout={layout} onLayout={onLayout} /></div>}
        {slim and <div className="mb-2"><ThemeSwitcher /></div>}
    </nav>;
}
