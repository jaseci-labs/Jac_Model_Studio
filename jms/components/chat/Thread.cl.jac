"""Message thread — ports ui/components/thread.tsx.

Asymmetric bubbles: the user is a right-aligned light pill, the assistant is a
left-aligned borderless block whose fenced ```code``` segments render as labelled
copy-able OUTPUT panes. When two assistant messages share a `pairGroup` (COMPARE
mode) they render side-by-side in a 2-col grid of dashed panes labelled per model.
"""

def _copy(text: str) -> None {
    nav: any = navigator;
    nav.clipboard.writeText(text);
}

# Split assistant content into prose + fenced code segments.
def _codeParts(content: str) -> list[dict] {
    nl = String.fromCharCode(10);
    segs = content.split("```");
    out: list[dict] = [];
    for (i, p) in enumerate(segs) {
        if i % 2 == 0 {
            if p {
                out.append({"kind": "text", "text": p, "lang": ""});
            }
        } else {
            lines = p.split(nl);
            lang = lines[0].strip() if len(lines) > 0 else "";
            body = nl.join(lines[1:]) if len(lines) > 1 else p;
            out.append({"kind": "code", "text": body, "lang": lang});
        }
    }
    return out;
}

# --- lightweight markdown (ponytail: common md only — headings, bold, inline +
# fenced code (fences handled upstream by _codeParts), bullet lists, links.
# No tables / nested lists / italics / images; swap in react-markdown if richer
# docs ever need it). Built as JSX, never dangerouslySetInnerHTML → no XSS. ---

"""Split one line of prose into inline segments: plain / `code` / **bold** /
[text](url). Longest-prefix scan on the nearest marker; unterminated markers fall
back to plain text so partial (streaming) markdown never throws."""
def _inlineSegs(s: str) -> list {
    out: list = [];
    rest = str(s);
    while rest {
        ic = rest.find("`");
        ib = rest.find("**");
        il = rest.find("[");
        cand: list = [];
        if ic >= 0 { cand.append(ic); }
        if ib >= 0 { cand.append(ib); }
        if il >= 0 { cand.append(il); }
        if len(cand) == 0 { out.append({"t": "text", "v": rest, "u": ""}); break; }
        m = min(cand);
        if m > 0 { out.append({"t": "text", "v": rest[:m], "u": ""}); rest = rest[m:]; continue; }
        if rest[:1] == "`" {
            e = rest.find("`", 1);
            if e < 0 { out.append({"t": "text", "v": rest, "u": ""}); break; }
            out.append({"t": "code", "v": rest[1:e], "u": ""}); rest = rest[e + 1:];
        } elif rest[:2] == "**" {
            e = rest.find("**", 2);
            if e < 0 { out.append({"t": "text", "v": rest, "u": ""}); break; }
            out.append({"t": "bold", "v": rest[2:e], "u": ""}); rest = rest[e + 2:];
        } elif rest[:1] == "[" {
            rb = rest.find("]");
            ok = rb >= 0 and rb + 1 < len(rest) and rest[rb + 1:rb + 2] == "(";
            if not ok { out.append({"t": "text", "v": rest[:1], "u": ""}); rest = rest[1:]; continue; }
            rp = rest.find(")", rb);
            if rp < 0 { out.append({"t": "text", "v": rest[:1], "u": ""}); rest = rest[1:]; continue; }
            out.append({"t": "link", "v": rest[1:rb], "u": rest[rb + 2:rp]}); rest = rest[rp + 1:];
        } else {
            out.append({"t": "text", "v": rest[:1], "u": ""}); rest = rest[1:];
        }
    }
    return out;
}

def _hcls(level: int) -> str {
    if level == 1 { return "mt-2 mb-1 text-base font-semibold text-foreground"; }
    if level == 2 { return "mt-2 mb-1 text-sm font-semibold text-foreground"; }
    return "mt-1.5 mb-0.5 text-sm font-medium text-foreground";
}

"""Render one prose line's inline markdown."""
def:pub Inline(text: str) -> JsxElement {
    return <span>
        {for (si, sg) in enumerate(_inlineSegs(text)) {
            <span key={str(si)}>
                {if sg["t"] == "code" {
                    <code className="rounded bg-popover px-1 py-0.5 font-mono text-[0.85em]">{str(sg["v"])}</code>
                    skip;
                }}
                {if sg["t"] == "bold" {
                    <strong className="font-semibold">{str(sg["v"])}</strong>
                    skip;
                }}
                {if sg["t"] == "link" {
                    <a href={str(sg["u"])} target="_blank" rel="noreferrer" className="text-accent underline">{str(sg["v"])}</a>
                    skip;
                }}
                {if sg["t"] == "text" {
                    <span className="whitespace-pre-wrap">{str(sg["v"])}</span>
                    skip;
                }}
            </span>
        }}
    </span>;
}

"""Block-level markdown → JSX: headings (#/##/###), bullet lists (- / *),
blank-line-separated paragraphs. Wrapped lines in a paragraph are joined."""
def:pub MarkdownText(text: str) -> JsxElement {
    nl = String.fromCharCode(10);
    lines = str(text).split(nl);
    blocks: list = [];
    para: str = "";
    items: list = [];
    for raw in lines {
        stripped = raw.strip();
        isBullet = stripped[:2] == "- " or stripped[:2] == "* ";
        h = 0;
        if stripped[:4] == "### " { h = 3; }
        elif stripped[:3] == "## " { h = 2; }
        elif stripped[:2] == "# " { h = 1; }
        if isBullet {
            if para { blocks.append({"kind": "p", "text": para, "items": []}); para = ""; }
            items.append(stripped[2:]);
            continue;
        }
        if len(items) > 0 { blocks.append({"kind": "ul", "text": "", "items": list(items)}); items = []; }
        if h > 0 {
            if para { blocks.append({"kind": "p", "text": para, "items": []}); para = ""; }
            blocks.append({"kind": "h" + str(h), "text": stripped[h + 1:], "items": []});
            continue;
        }
        if stripped == "" {
            if para { blocks.append({"kind": "p", "text": para, "items": []}); para = ""; }
            continue;
        }
        para = (para + " " + stripped) if para else stripped;
    }
    if para { blocks.append({"kind": "p", "text": para, "items": []}); }
    if len(items) > 0 { blocks.append({"kind": "ul", "text": "", "items": list(items)}); }

    return <div className="text-sm leading-relaxed text-foreground">
        {for (bi, b) in enumerate(blocks) {
            <div key={str(bi)}>
                {if str(b["kind"])[:1] == "h" {
                    <div className={_hcls(int(str(b["kind"])[1:]))}><Inline text={str(b["text"])} /></div>
                    skip;
                }}
                {if b["kind"] == "ul" {
                    <ul className="my-1 ml-4 list-disc space-y-0.5">
                        {for (li, it) in enumerate(list(b["items"])) {
                            <li key={str(li)}><Inline text={str(it)} /></li>
                        }}
                    </ul>
                    skip;
                }}
                {if b["kind"] == "p" {
                    <p className="my-1"><Inline text={str(b["text"])} /></p>
                    skip;
                }}
            </div>
        }}
    </div>;
}

# Group consecutive paired assistant messages so the thread can render them 2-up.
# Each row carries the most recent user prompt ("user") so a saved example can pair
# the assistant reply with the prompt that produced it.
def _rows(messages: list) -> list[dict] {
    out: list[dict] = [];
    n = len(messages);
    i = 0;
    lastUser = "";
    while i < n {
        m: any = messages[i];
        if m["role"] == "user" {
            lastUser = str(m["content"]);
            out.append({"kind": "single", "a": m, "b": None, "user": lastUser});
            i += 1;
            continue;
        }
        nxt: any = messages[i + 1] if i + 1 < n else None;
        paired = (
            m["role"] == "assistant" and m["pairGroup"]
            and nxt and nxt["pairGroup"] == m["pairGroup"]
        );
        if paired {
            out.append({"kind": "pair", "a": m, "b": nxt, "user": lastUser});
            i += 2;
        } else {
            out.append({"kind": "single", "a": m, "b": None, "user": lastUser});
            i += 1;
        }
    }
    return out;
}

def:pub CodeBlock(lang: str, code: str) -> JsxElement {
    has copied: bool = False;

    return <div className="relative mt-3 mb-1 exp-panel !bg-popover">
        <span className="micro-label absolute -top-2 left-3 bg-background px-2">
            OUTPUT.{(lang.upper() if lang else "TXT")}
        </span>
        <button
            onClick={lambda e: MouseEvent {
                _copy(code);
                copied = True;
                setTimeout(lambda -> None { copied = False; }, 1200);
            }}
            className="absolute right-2 top-2 font-mono text-[9px] text-muted-foreground hover:text-foreground"
        >{"COPIED" if copied else "COPY"}</button>
        <pre className="overflow-x-auto p-3 pt-4 font-mono text-xs leading-relaxed text-foreground">{code}</pre>
    </div>;
}

def:pub Bubble(msg: dict, label: str, paired: bool, userText: str, onSave: any) -> JsxElement {
    has saved: bool = False;

    if msg["role"] == "user" {
        return <div className="my-2 flex justify-end">
            <div className="max-w-[80%] whitespace-pre-wrap rounded-xl bg-accent px-4 py-2 text-sm text-accent-foreground">{str(msg["content"])}</div>
        </div>;
    }
    content = str(msg["content"]);
    streaming = msg["streaming"];
    return <div className="my-3 max-w-[92%]">
        {paired and <div className="micro-label mb-1">{label}</div>}
        {(streaming and not content) and <div className="stat-line animate-pulse">loading {label}…</div>}
        {for (pi, part) in enumerate(_codeParts(content)) {
            <div key={str(pi)}>
                {if part["kind"] == "code" {
                    <CodeBlock lang={str(part["lang"])} code={str(part["text"])} />
                    skip;
                }}
                {if part["kind"] == "text" {
                    <MarkdownText text={str(part["text"])} />
                    skip;
                }}
            </div>
        }}
        {(streaming and content) and <span className="animate-pulse font-mono text-muted-foreground">▍</span>}
        {msg["error"] and <div className="stat-line mt-1 border border-dashed border-input p-2">ERROR: {str(msg["error"])}</div>}
        {msg["stats"] and <div className="stat-line mt-1.5">└─ {str(msg["stats"]["tps"])} tok/s · {str(msg["stats"]["tokens"])} tok · Δ{str(msg["stats"]["gen_s"])}s · load {str(msg["stats"]["load_s"])}s</div>}
        {(onSave is not None and not streaming and content and userText) and <button
            onClick={lambda e: MouseEvent {
                onSave(userText, content);
                saved = True;
                setTimeout(lambda -> None { saved = False; }, 1400);
            }}
            className="exp-btn mt-1.5"
        >{"SAVED ✓ → sft.jsonl" if saved else "+ SAVE EXAMPLE"}</button>}
    </div>;
}

def:pub Thread(messages: list, labels: dict, onSave: any) -> JsxElement {
    can with [messages] entry {
        doc: any = document;
        el: any = doc.getElementById("chat-end");
        if el { el.scrollIntoView({"behavior": "smooth"}); }
    }

    def lbl(mid: str) -> str {
        return str(labels[mid]) if mid and mid in labels else mid;
    }

    return <div className="flex-1 overflow-y-auto px-6 py-4">
        {if len(messages) == 0 {
            <div className="flex h-full items-center justify-center">
                <p className="micro-label">SELECT A PROMPT OR TYPE BELOW</p>
            </div>
            skip;
        }}
        {for (ri, row) in enumerate(_rows(messages)) {
            <div key={str(ri)}>
                {if row["kind"] == "pair" {
                    <div className="grid grid-cols-2 gap-4">
                        <div className="rounded-lg border border-dashed border-border p-3">
                            <Bubble msg={row["a"]} label={lbl(str(row["a"]["modelId"]))} paired={True} userText={str(row["user"])} onSave={onSave} />
                        </div>
                        <div className="rounded-lg border border-dashed border-border p-3">
                            <Bubble msg={row["b"]} label={lbl(str(row["b"]["modelId"]))} paired={True} userText={str(row["user"])} onSave={onSave} />
                        </div>
                    </div>
                    skip;
                }}
                {if row["kind"] == "single" {
                    <Bubble msg={row["a"]} label={lbl(str(row["a"]["modelId"]))} paired={False} userText={str(row["user"])} onSave={onSave} />
                    skip;
                }}
            </div>
        }}
        <div id="chat-end" />
    </div>;
}
