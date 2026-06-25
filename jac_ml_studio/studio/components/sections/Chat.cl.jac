"""CHAT section — 3-pane: history sidebar | thread + composer | sampling rail.

Ports ui/components/chat-section.tsx + use-studio.ts. Chats persist to the OSP
graph (persistence.sv.jac). Completion streams from /function/chat_stream (raw
SSE fetch reader). Assistant messages render code blocks with copy + per-message
stats; the rail drives sampling and shows last-run stats.
"""

sv import from ...models { list_models, system_ram, ModelView }
sv import from ...prompts { list_prompts }
sv import from ...persistence {
    create_chat, list_chats, delete_chat, get_messages, add_message, ChatView, MsgView
}
import from ..chat.Sidebar { Sidebar }
import from ..chat.Rail { Rail }

def _r1(v: any) -> float {
    return float(int(float(v) * 10.0 + 0.5)) / 10.0;
}

def _copy(text: str) -> None {
    nav: any = navigator;
    nav.clipboard.writeText(text);
}

# Split assistant content into prose + fenced code segments.
def _codeParts(content: str) -> list[dict] {
    nl = String.fromCharCode(10);
    parts = content.split("```");
    out: list[dict] = [];
    for (i, p) in enumerate(parts) {
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

def:pub Chat -> JsxElement {
    has models: list[ModelView] = [],
        chats: list = [],
        chatId: str = "",
        messages: list[dict] = [],
        modelId: str = "",
        draft: str = "",
        streaming: bool = False,
        status: str = "",
        temperature: float = 0.2,
        topP: float = 0.9,
        maxTokens: int = 1024,
        ramGb: float = 0.0,
        prompts: list = [],
        lastStats: any = None,
        railCollapsed: bool = False;

    async can with entry {
        ms = await list_models();
        models = ms;
        for m in ms {
            if m.available {
                modelId = m.id;
                break;
            }
        }
        ramGb = float(await system_ram());
        cs = await list_chats();
        chats = cs;
        pr = await list_prompts();
        prompts = list(pr["categories"]);
    }

    async def newChat -> None {
        chatId = "";
        messages = [];
        lastStats = None;
    }

    async def openChat(id: str) -> None {
        chatId = id;
        rows = await get_messages(id);
        ms: list[dict] = [];
        for r in rows {
            ms.append({"role": r.role, "content": r.content, "stats": None});
        }
        messages = ms;
    }

    async def removeChat(id: str) -> None {
        await delete_chat(id);
        cs = await list_chats();
        chats = cs;
        if id == chatId {
            chatId = "";
            messages = [];
        }
    }

    async def send -> None {
        prompt = draft.strip();
        if not prompt or streaming or not modelId {
            return;
        }
        draft = "";
        streaming = True;
        status = "loading model…";
        # Local accumulators — reading the `chatId`/`messages` state mid-send
        # returns the stale render value (React writes are async), so the thread
        # would never update. Build on `cid`/`base`, write state from them.
        cid = chatId;
        if not cid {
            c = await create_chat(prompt[:40]);
            cid = c.id;
            chatId = cid;
        }
        await add_message(cid, "user", prompt, "", "", "");
        hist: list[dict] = [];
        base: list[dict] = [];
        for mm in messages {
            hist.append({"role": mm["role"], "content": mm["content"]});
            base.append(mm);
        }
        hist.append({"role": "user", "content": prompt});
        base.append({"role": "user", "content": prompt, "stats": None});
        base.append({"role": "assistant", "content": "", "stats": None});
        ai = len(base) - 1;
        messages = list(base);
        acc = "";
        donestats: any = None;
        try {
            resp: any = await fetch(
                "/function/chat_stream",
                {
                    "method": "POST",
                    "headers": {"Content-Type": "application/json"},
                    "body": JSON.stringify({
                        "messages": hist, "model_id": modelId,
                        "temperature": temperature, "top_p": topP, "max_tokens": maxTokens
                    })
                }
            );
            reader: any = resp.body.getReader();
            dec: any = new(TextDecoder);
            nl = String.fromCharCode(10);
            sep = nl + nl;
            buf = "";
            while True {
                chunk: any = await reader.read();
                if chunk.done {
                    break;
                }
                buf = buf + str(dec.decode(chunk.value, {"stream": True}));
                parts = buf.split(sep);
                buf = parts[len(parts) - 1];
                i = 0;
                while i < len(parts) - 1 {
                    data = "";
                    for line in parts[i].split(nl) {
                        if len(line) >= 5 and line[:5] == "data:" {
                            data = data + line[5:].strip();
                        }
                    }
                    if data {
                        try {
                            msg: any = JSON.parse(data);
                            if msg.kind == "load" {
                                status = "generating…";
                            } elif msg.kind == "token" {
                                acc = str(msg.text);
                                base[ai] = {"role": "assistant", "content": acc, "stats": None};
                                messages = list(base);
                            } elif msg.kind == "done" {
                                donestats = {
                                    "tps": _r1(msg.tps), "tokens": msg.tokens,
                                    "gen_s": _r1(msg.gen_s), "load_s": msg.load_s
                                };
                                base[ai] = {"role": "assistant", "content": acc, "stats": donestats};
                                messages = list(base);
                                lastStats = donestats;
                                status = "";
                            } elif msg.kind == "error" {
                                status = "error: " + str(msg.text);
                            }
                        } except Exception { }
                    }
                    i += 1;
                }
            }
        } except Exception as e {
            status = "stream failed";
        }
        if acc {
            sj = JSON.stringify(donestats) if donestats else "";
            await add_message(cid, "assistant", acc, modelId, sj, "");
        }
        cs = await list_chats();
        chats = cs;
        streaming = False;
        status = "";
    }

    def onKey(e: KeyboardEvent) -> None {
        if e.key == "Enter" and not e.shiftKey {
            e.preventDefault();
            send();
        }
    }

    def pickFirst(cat: any) -> None {
        prs = list(cat["prompts"]);
        if len(prs) > 0 {
            draft = str(prs[0]);
        }
    }

    return <div className="flex h-full min-w-0 flex-1 overflow-hidden">
        <Sidebar
            chats={chats} activeId={chatId} ramGb={ramGb} residentGb={0.0}
            onNew={newChat} onOpen={openChat} onDelete={removeChat}
        />
        <main className="flex min-w-0 flex-1 flex-col">
            <div className="flex items-center justify-between border-b border-neutral-800 px-4 py-2.5">
                <div className="flex items-center gap-3">
                    <span className="micro-label">CHAT</span>
                    <select
                        value={modelId}
                        onChange={lambda e: ChangeEvent { modelId = e.target.value; }}
                        className="rounded-md border border-neutral-800 bg-[#161616] px-2 py-1 font-mono text-[11px] text-neutral-300"
                    >
                        {for m in models {
                            <option key={m.id} value={m.id} disabled={not m.available}>{m.label}</option>
                        }}
                    </select>
                    {status and <span className="stat-line">{status}</span>}
                </div>
                <span className="micro-label text-neutral-600">MLX · LOCAL</span>
            </div>

            <div className="flex flex-1 flex-col gap-3 overflow-y-auto p-4">
                {if len(messages) == 0 {
                    <div className="flex h-full items-center justify-center">
                        <span className="micro-label">SELECT A PROMPT OR TYPE BELOW</span>
                    </div>
                    skip;
                }}
                {for (idx, msg) in enumerate(messages) {
                    <div key={str(idx)} className="mx-auto w-full max-w-3xl">
                        <div className="micro-label mb-1">{"ASSISTANT" if msg["role"] == "assistant" else "YOU"}</div>
                        <div className={"rounded-md border border-neutral-800 px-3.5 py-2.5 text-sm " + (
                            "bg-[#0d0d0d] text-neutral-200" if msg["role"] == "assistant" else "bg-[#161616] text-neutral-300"
                        )}>
                            {if msg["role"] != "assistant" {
                                <div className="whitespace-pre-wrap">{msg["content"]}</div>
                                skip;
                            }}
                            {if msg["role"] == "assistant" {
                                <div className="flex flex-col gap-2">
                                    {for (pi, part) in enumerate(_codeParts(msg["content"]))  {
                                        <div key={str(pi)}>
                                            {if part["kind"] == "text" {
                                                <div className="whitespace-pre-wrap leading-relaxed">{part["text"]}</div>
                                                skip;
                                            }}
                                            {if part["kind"] == "code" {
                                                <div className="relative rounded-md border border-neutral-800 bg-[#121212]">
                                                    <div className="flex items-center justify-between border-b border-neutral-800 px-2 py-1">
                                                        <span className="micro-label">OUTPUT.{str(part["lang"]).upper() if part["lang"] else "TXT"}</span>
                                                        <button
                                                            onClick={lambda e: MouseEvent { _copy(str(part["text"])); }}
                                                            className="micro-label text-neutral-600 hover:text-neutral-300"
                                                        >COPY</button>
                                                    </div>
                                                    <pre className="overflow-x-auto p-2 font-mono text-[11px] text-neutral-300">{part["text"]}</pre>
                                                </div>
                                                skip;
                                            }}
                                        </div>
                                    }}
                                    {streaming and idx == len(messages) - 1 and <span className="pulse font-mono text-neutral-500">▍</span>}
                                </div>
                                skip;
                            }}
                        </div>
                        {msg["stats"] and <div className="stat-line mt-1">└─ {str(msg["stats"]["tps"])} tok/s · {str(msg["stats"]["tokens"])} tok · Δ{str(msg["stats"]["gen_s"])}s · load {str(msg["stats"]["load_s"])}s</div>}
                    </div>
                }}
            </div>

            <div className="border-t border-neutral-800 p-3">
                <div className="mx-auto w-full max-w-3xl">
                    <div className="mb-2 flex flex-wrap gap-1.5">
                        {for cat in prompts {
                            <button
                                key={str(cat["id"])}
                                onClick={lambda e: MouseEvent { pickFirst(cat); }}
                                className="rounded-full border border-dashed border-neutral-700 px-2.5 py-0.5 font-mono text-[9px] uppercase tracking-wider text-neutral-500 hover:border-neutral-500 hover:text-neutral-300"
                            >{str(cat["label"])}</button>
                        }}
                    </div>
                    <div className="flex gap-2">
                    <textarea
                        value={draft}
                        onChange={lambda e: ChangeEvent { draft = e.target.value; }}
                        onKeyDown={onKey}
                        placeholder="Ask the model…  (Enter to send, Shift+Enter for newline)"
                        rows={2}
                        className="flex-1 resize-none rounded-md border border-neutral-800 bg-[#161616] px-3 py-2 font-mono text-sm text-neutral-200 outline-none focus:border-neutral-600"
                    />
                    <button
                        onClick={lambda e: MouseEvent { send(); }}
                        disabled={streaming}
                        className={"rounded-md px-4 py-2 font-mono text-xs " + (
                            "bg-neutral-800 text-neutral-500" if streaming else "bg-neutral-100 text-neutral-900 hover:bg-white"
                        )}
                    >
                        {"…" if streaming else "⏎ SEND"}
                    </button>
                    </div>
                </div>
            </div>
        </main>
        <Rail
            prompts={prompts}
            temperature={temperature} topP={topP} maxTokens={maxTokens} lastStats={lastStats}
            collapsed={railCollapsed}
            onPick={lambda p: str { draft = p; }}
            onTemp={lambda v: float { temperature = v; }}
            onTopP={lambda v: float { topP = v; }}
            onMaxTokens={lambda v: float { maxTokens = int(v); }}
            onToggle={lambda { railCollapsed = not railCollapsed; }}
        />
    </div>;
}
