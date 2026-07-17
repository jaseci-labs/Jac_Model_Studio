"""LogView — reversed monospace log with error/prompt line coloring.
Ports ui/components/shared/log-view.tsx."""

def _lineClass(ln: str) -> str {
    low = ln.lower();
    if "error" in low or "✗" in ln or "traceback" in low {
        return "text-neutral-100";
    }
    if ln.startswith(">>>") {
        return "text-neutral-300";
    }
    return "text-neutral-500";
}

def:pub LogView(text: str, maxH: str) -> JsxElement {
    nl = String.fromCharCode(10);
    lines = text.split(nl);
    lines.reverse();
    return <pre
        className="flex flex-col-reverse overflow-y-auto rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 font-mono text-[11px] leading-relaxed"
        style={{"maxHeight": maxH}}
    >
        {for (i, ln) in enumerate(lines) {
            <div key={str(i)} className={_lineClass(ln)}>{ln if ln else " "}</div>
        }}
    </pre>;
}
