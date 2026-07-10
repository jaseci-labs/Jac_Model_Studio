"""StatusGlyph — status badge. Ports ui/components/shared/status-glyph.tsx."""

glob GLYPHS: dict = {
    "idle": "○", "running": "⦿", "done": "✓", "failed": "✗", "stopped": "◌", "finished": "✓"
};
glob CLASSES: dict = {
    "idle": "text-neutral-600", "running": "text-neutral-100 pulse", "done": "text-neutral-100",
    "failed": "text-neutral-100", "stopped": "text-neutral-600", "finished": "text-neutral-100"
};

def:pub StatusGlyph(status: str, showLabel: bool) -> JsxElement {
    glyph = str(GLYPHS[status]) if status in GLYPHS else "○";
    cls = str(CLASSES[status]) if status in CLASSES else "text-neutral-600";
    failed = "border-b border-dashed border-neutral-500" if status == "failed" else "";
    return <span className={"font-mono text-[10px] tracking-widest " + cls + " " + failed}>
        {glyph}{(" " + status.upper()) if showLabel else ""}
    </span>;
}
