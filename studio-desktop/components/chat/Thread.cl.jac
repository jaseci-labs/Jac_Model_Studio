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

    return <div className="relative mt-3 mb-1 rounded-lg border border-neutral-800 bg-[#121212]">
        <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">
            OUTPUT.{(lang.upper() if lang else "TXT")}
        </span>
        <button
            onClick={lambda (e: MouseEvent) {
                _copy(code);
                copied = True;
                setTimeout(lambda -> None { copied = False; }, 1200);
            }}
            className="absolute right-2 top-2 font-mono text-[9px] text-neutral-500 hover:text-neutral-200"
        >{"COPIED" if copied else "COPY"}</button>
        <pre className="overflow-x-auto p-3 pt-4 font-mono text-xs leading-relaxed text-neutral-200">{code}</pre>
    </div>;
}

def:pub Bubble(msg: dict, label: str, paired: bool, userText: str, onSave: any) -> JsxElement {
    has saved: bool = False;

    if msg["role"] == "user" {
        return <div className="my-2 flex justify-end">
            <div className="max-w-[80%] whitespace-pre-wrap rounded-xl bg-neutral-200 px-4 py-2 text-sm text-neutral-900">{str(msg["content"])}</div>
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
                    <p className="whitespace-pre-wrap text-sm leading-relaxed text-neutral-200">{str(part["text"])}</p>
                    skip;
                }}
            </div>
        }}
        {(streaming and content) and <span className="animate-pulse font-mono text-neutral-400">▍</span>}
        {msg["error"] and <div className="stat-line mt-1 border border-dashed border-neutral-600 p-2">ERROR: {str(msg["error"])}</div>}
        {msg["stats"] and <div className="stat-line mt-1.5">└─ {str(msg["stats"]["tps"])} tok/s · {str(msg["stats"]["tokens"])} tok · Δ{str(msg["stats"]["gen_s"])}s · load {str(msg["stats"]["load_s"])}s</div>}
        {(onSave is not None and not streaming and content and userText) and <button
            onClick={lambda (e: MouseEvent) {
                onSave(userText, content);
                saved = True;
                setTimeout(lambda -> None { saved = False; }, 1400);
            }}
            className="micro-label mt-1.5 rounded border border-neutral-700 px-1.5 py-0.5 text-neutral-500 transition-colors hover:border-neutral-500 hover:text-neutral-200"
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
                        <div className="rounded-lg border border-dashed border-neutral-800 p-3">
                            <Bubble msg={row["a"]} label={lbl(str(row["a"]["modelId"]))} paired={True} userText={str(row["user"])} onSave={onSave} />
                        </div>
                        <div className="rounded-lg border border-dashed border-neutral-800 p-3">
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
