"""Shared HUD primitives: bracket stat tiles, status glyphs, syntax-colored logs.

Color is semantic only (green good / red fail / amber caution); One-Dark palette
for code tokens in logs. Pure presentation — no server imports.
"""

glob KEYWORDS: list[str] = [
    "def", "walker", "can", "obj", "node", "edge", "return", "import", "from",
    "has", "with", "entry", "visit", "spawn", "report", "glob", "let",
    "if", "else", "for", "while", "in", "not", "and", "or", "class", "lambda"
];

def word_color(w: str) -> str {
    s: str = w.strip("():;,{}[]<>");
    if s in KEYWORDS { return "#c678dd"; }
    if w.startswith("\"") or w.startswith("'") or w.startswith("`") { return "#98c379"; }
    if "✓" in w or s == "PASS" or s == "saved" { return "#4ade80"; }
    if "✗" in w or "FAIL" in s or "rror" in w or "Traceback" in w { return "#f87171"; }
    t: str = s.replace(".", "").replace("-", "").replace("e", "").replace("%", "").replace("/", "");
    if t != "" and t.isdigit() { return "#61afef"; }
    return "";
}

def word_style(w: str) -> dict[str, str] {
    c: str = word_color(w);
    if c == "" { return {}; }
    return {"color": c};
}

def:pub BracketTile(label: str, value: str, sub: str, subcls: str) -> JsxElement {
    return <div className="dg-tile">
        <span className="dg-br dg-br-tl"></span>
        <span className="dg-br dg-br-br"></span>
        <div className="dg-tile-label">{label}</div>
        <div className="dg-tile-value">{value}</div>
        {sub != "" and <div className={"dg-tile-sub " + subcls}>{sub}</div>}
    </div>;
}

def:pub StatusGlyph(status: str) -> JsxElement {
    g: str = "○";
    c: str = "dg-glyph-idle";
    if status == "running" { g = "⦿"; c = "dg-glyph-run"; }
    if status == "done" or status == "finished" { g = "✓"; c = "dg-glyph-done"; }
    if status == "failed" { g = "✗"; c = "dg-glyph-fail"; }
    return <span className={"dg-status " + c}>{g + " " + status.upper()}</span>;
}

def:pub LogView(text: str, maxh: str) -> JsxElement {
    # Newest-last text rendered newest-first inside a column-reverse flex pre:
    # visual order stays chronological and the scroll position pins to the tail.
    lines: list[str] = [];
    for ln in text.split("\n") {
        lines.insert(0, ln);
    }
    return <pre className="dg-log dg-log-follow" style={{"maxHeight": maxh}}>
        {for (i, ln) in enumerate(lines) {
            <div key={str(i)}>
                {for (j, w) in enumerate(ln.split(" ")) {
                    <span key={str(j)} style={word_style(w)}>{w + " "}</span>
                }}
            </div>
        }}
    </pre>;
}

def seg_style(i: int) -> dict[str, str] {
    if i % 2 == 1 { return {"color": "#98c379"}; }
    return {"color": "#8b8b96"};
}

def seg_text(i: int, p: str) -> str {
    if i % 2 == 1 { return "\"" + p + "\""; }
    return p;
}

def:pub JsonRow(text: str) -> JsxElement {
    parts: list[str] = text.split("\"");
    return <pre className="dg-log dg-json">
        {for (i, p) in enumerate(parts) {
            <span key={str(i)} style={seg_style(i)}>{seg_text(i, p)}</span>
        }}
    </pre>;
}
