"""Message thread — ports ui/components/thread.tsx.

Asymmetric bubbles: the user is a right-aligned light pill, the assistant is a
left-aligned borderless block whose fenced ```code``` segments render as labelled
copy-able OUTPUT panes. When two assistant messages share a `pairGroup` (COMPARE
mode) they render side-by-side in a 2-col grid of dashed panes labelled per model.

Prose segments (headers/bold/lists/tables/links -- anything outside a fenced
```code``` block) render through react-markdown + remark-gfm instead of a flat
whitespace-pre-wrap <p>, so a model's markdown formatting actually shows up
instead of raw ** and | characters. Component overrides below map each
markdown element to the app's semantic design tokens (same border / foreground /
muted-foreground scale as CodeBlock uses) rather than pulling in the Tailwind
Typography plugin, which would fight this app's deliberately custom look.
"""

cl import from "react-markdown" { default as Markdown }
cl import from "remark-gfm" { default as remarkGfm }
import from ..shared.CodeBlock { CodeBlock }

def _mdH1(props: any) -> JsxElement {
    return <h2 className="mb-2 mt-3 text-base font-semibold text-foreground first:mt-0">{props.children}</h2>;
}
def _mdH2(props: any) -> JsxElement {
    return <h3 className="mb-2 mt-3 text-sm font-semibold text-foreground first:mt-0">{props.children}</h3>;
}
def _mdH3(props: any) -> JsxElement {
    return <h4 className="mb-1.5 mt-2.5 text-sm font-semibold text-foreground first:mt-0">{props.children}</h4>;
}
def _mdP(props: any) -> JsxElement {
    return <p className="mb-2 text-sm leading-relaxed text-foreground last:mb-0">{props.children}</p>;
}
def _mdUl(props: any) -> JsxElement {
    return <ul className="mb-2 ml-4 list-disc space-y-1 text-sm leading-relaxed text-foreground">{props.children}</ul>;
}
def _mdOl(props: any) -> JsxElement {
    return <ol className="mb-2 ml-4 list-decimal space-y-1 text-sm leading-relaxed text-foreground">{props.children}</ol>;
}
def _mdLi(props: any) -> JsxElement {
    return <li className="pl-1">{props.children}</li>;
}
def _mdStrong(props: any) -> JsxElement {
    return <strong className="font-semibold text-foreground">{props.children}</strong>;
}
def _mdEm(props: any) -> JsxElement {
    return <em className="italic text-foreground">{props.children}</em>;
}
def _mdCode(props: any) -> JsxElement {
    return <code className="rounded bg-popover px-1 py-0.5 font-mono text-xs text-foreground">{props.children}</code>;
}
def _mdA(props: any) -> JsxElement {
    return <a
        href={props.href}
        target="_blank"
        rel="noreferrer"
        className="text-foreground underline decoration-ring underline-offset-2 hover:text-foreground"
    >{props.children}</a>;
}
def _mdBlockquote(props: any) -> JsxElement {
    return <blockquote className="mb-2 border-l-2 border-input pl-3 text-sm italic text-muted-foreground">{props.children}</blockquote>;
}
def _mdHr(props: any) -> JsxElement {
    return <hr className="my-3 border-border" />;
}
def _mdTable(props: any) -> JsxElement {
    return <div className="mb-2 overflow-x-auto"><table className="w-full border-collapse text-sm">{props.children}</table></div>;
}
def _mdThead(props: any) -> JsxElement {
    return <thead className="border-b border-input">{props.children}</thead>;
}
def _mdTh(props: any) -> JsxElement {
    return <th className="px-2 py-1 text-left font-mono text-[10px] uppercase tracking-wide text-muted-foreground">{props.children}</th>;
}
def _mdTd(props: any) -> JsxElement {
    return <td className="border-t border-border px-2 py-1 text-foreground">{props.children}</td>;
}

glob MD_COMPONENTS: dict = {
    "h1": _mdH1, "h2": _mdH2, "h3": _mdH3, "h4": _mdH3, "h5": _mdH3, "h6": _mdH3,
    "p": _mdP, "ul": _mdUl, "ol": _mdOl, "li": _mdLi,
    "strong": _mdStrong, "em": _mdEm, "code": _mdCode, "a": _mdA,
    "blockquote": _mdBlockquote, "hr": _mdHr,
    "table": _mdTable, "thead": _mdThead, "th": _mdTh, "td": _mdTd,
};

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

def:pub Bubble(msg: dict, label: str, paired: bool, userText: str, onSave: any) -> JsxElement {
    has saved: bool = False;

    if msg["role"] == "user" {
        return <div className="my-2 flex justify-end">
            <div className="max-w-[80%] whitespace-pre-wrap rounded-xl bg-primary px-4 py-2 text-sm text-primary-foreground">{str(msg["content"])}</div>
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
                    <CodeBlock key="code" label="" code={str(part["text"])} lang={str(part["lang"])} />
                    skip;
                }}
                {if part["kind"] == "text" {
                    <Markdown key="text" remarkPlugins={[remarkGfm]} components={MD_COMPONENTS}>{str(part["text"])}</Markdown>
                    skip;
                }}
            </div>
        }}
        {(streaming and content) and <span className="animate-pulse font-mono text-muted-foreground">▍</span>}
        {msg["error"] and <div className="stat-line mt-1 border border-dashed border-ring p-2">ERROR: {str(msg["error"])}</div>}
        {msg["stats"] and <div className="stat-line mt-1.5">└─ {str(msg["stats"]["tps"])} tok/s · {str(msg["stats"]["tokens"])} tok · Δ{str(msg["stats"]["gen_s"])}s · load {str(msg["stats"]["load_s"])}s</div>}
        {(onSave is not None and not streaming and content and userText) and <button
            onClick={lambda e: MouseEvent {
                onSave(userText, content);
                saved = True;
                setTimeout(lambda -> None { saved = False; }, 1400);
            }}
            className="micro-label mt-1.5 rounded border border-input px-1.5 py-0.5 text-muted-foreground transition-colors hover:border-ring hover:text-foreground"
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
            <div key="empty" className="flex h-full items-center justify-center">
                <p className="micro-label">SELECT A PROMPT OR TYPE BELOW</p>
            </div>
            skip;
        }}
        {for (ri, row) in enumerate(_rows(messages)) {
            <div key={str(ri)}>
                {if row["kind"] == "pair" {
                    <div key="pair" className="grid grid-cols-2 gap-4">
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
                    <Bubble key="single" msg={row["a"]} label={lbl(str(row["a"]["modelId"]))} paired={False} userText={str(row["user"])} onSave={onSave} />
                    skip;
                }}
            </div>
        }}
        <div id="chat-end" />
    </div>;
}
