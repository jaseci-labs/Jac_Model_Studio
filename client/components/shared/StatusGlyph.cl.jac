"""StatusGlyph — status badge. Ports ui/components/shared/status-glyph.tsx."""

glob GLYPHS: dict = {
    "idle": "○", "running": "⦿", "done": "✓", "failed": "✗", "stopped": "◌", "finished": "✓"
};
glob CLASSES: dict = {
    "idle": "text-muted-foreground/80", "running": "text-accent pulse", "done": "text-foreground",
    "failed": "text-foreground", "stopped": "text-muted-foreground/80", "finished": "text-foreground"
};

def:pub StatusGlyph(status: str, showLabel: bool) -> JsxElement {
    glyph = str(GLYPHS[status]) if status in GLYPHS else "○";
    cls = str(CLASSES[status]) if status in CLASSES else "text-muted-foreground/80";
    failed = "border-b border-dashed border-input" if status == "failed" else "";
    return <span className={"font-mono text-[10px] tracking-widest " + cls + " " + failed}>
        {glyph}{(" " + status.upper()) if showLabel else ""}
    </span>;
}
