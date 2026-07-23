"""AssistantPanel — self-contained floating AI-assistant widget.

Task A4+ of the phase-2 grounded-assistant feature. A single fixed ✦ launcher
bubble (bottom-right, glass) mounted once at each shell level (JmsShell +
AppShell) that owns its own open/closed state — no parent wiring needed beyond
an optional `pageContext` string describing what the user is currently looking
at (folded into the grounding context sent with every message). On first open
it fetches `assistant_providers()` (mlx/claude/openai — API providers carry
`requires_key`/`configured`) and picks a sane default: local MLX if it has any
model on disk, else the first configured API provider, else whatever's first.

Provider selection is never gated behind a lock — picking an unconfigured API
provider swaps the drawer body for an inline "Connect <Provider>" key-entry
screen (saving via `set_anthropic_key`/`set_openai_key`, mirroring
`ApiKeyModal.cl.jac`) instead of disabling the chip. Once configured the body
switches back to the normal thread + composer.

Chat history persists to the OSP graph (`persistence.sv.jac`) under the
`"assistant"` workspace, same shape `sections/Chat.cl.jac` uses for the main
chat surface — a togglable history list (newest first) with new/open/delete,
so an assistant conversation survives a page reload.

Sending a message streams `/function/assistant_stream` with the exact
raw-fetch-reader pattern `Chat.cl.jac` uses for `/function/chat_stream` (same
SSE frame protocol: `load`/`token`/`done`/`error`, plus the jaclang
`event: end` / `event: error` sentinel frame the generator-backed endpoint
sends instead of closing the socket — miss it and the reader hangs forever).
Grounding (full app state: workspaces, projects, runs, evals, deployments)
happens entirely server-side via `assistant_context()`; this component only
prepends the current-page hint and sends the raw message list, provider, and
model_id.

Reuses `chat/Thread` for the bubble list and `chat/Composer` for the input —
both already glass-styled and theme-aware — rather than hand-rolling either.
"""

sv import from ..assistant {
    assistant_providers, assistant_context, set_openai_key
}
sv import from ..jms_llm { set_anthropic_key }
sv import from ..persistence {
    list_chats, create_chat, get_messages, add_message, delete_chat
}
import from ..auth_session { bearerHeaders, handleUnauthorized }
import from .chat.Thread { Thread }
import from .chat.Composer { Composer }

"""Model ids for provider `pid`, or [] if `pid` isn't in `providers` (still
loading) or has no models (e.g. an ungated provider with no local weights)."""
def _modelsFor(providers: list[dict], pid: str) -> list[str] {
    for p in providers {
        if str(p["id"]) == pid {
            return list(p["models"]);
        }
    }
    return [];
}

"""The `providers` entry for `pid`, or None while still loading / unknown id."""
def _providerInfo(providers: list[dict], pid: str) -> dict | None {
    for p in providers {
        if str(p["id"]) == pid {
            return p;
        }
    }
    return None;
}

def:pub AssistantPanel(pageContext: str = "") -> JsxElement {
    has widgetOpen: bool = False,
        providers: list[dict] = [],
        provider: str = "mlx",
        modelId: str = "",
        messages: list[dict] = [],
        draft: str = "",
        streaming: bool = False,
        activeReader: any = None,
        chatId: str = "",
        historyOpen: bool = False,
        chats: list = [],
        keyInput: str = "",
        keyBusy: bool = False,
        keyErr: str = "",
        loaded: bool = False;

    async def refreshProviders -> list {
        try {
            res = await assistant_providers();
            plist: list[dict] = [];
            for p in list(res["providers"]) {
                plist.append(p as dict);
            }
            providers = plist;
            return plist;
        } except Exception { return []; }
    }

    async def refreshHistory -> None {
        try {
            cs = await list_chats("assistant");
            chats = cs;
        } except Exception { }
    }

    async def loadOnce -> None {
        if loaded {
            return;
        }
        loaded = True;
        # Pick from the RETURNED local list — the `providers` state set inside
        # refreshProviders is not yet visible in this closure (useState is async).
        plist: list = await refreshProviders();

        # Prefer local MLX when it actually has a model on disk; otherwise the
        # first provider that's already configured (key set / env fallback);
        # otherwise just the first provider so the picker isn't empty.
        pick = "";
        pickModel = "";
        for p in plist {
            if str(p["id"]) == "mlx" {
                mdls = list(p["models"]);
                if len(mdls) > 0 {
                    pick = "mlx";
                    pickModel = str(mdls[0]);
                }
            }
        }
        if not pick {
            for p in plist {
                if bool(p["configured"]) {
                    mdls = list(p["models"]);
                    pick = str(p["id"]);
                    pickModel = str(mdls[0]) if len(mdls) > 0 else "";
                    break;
                }
            }
        }
        if not pick and len(plist) > 0 {
            pick = str(plist[0]["id"]);
            m0 = list(plist[0]["models"]);
            pickModel = str(m0[0]) if len(m0) > 0 else "";
        }
        provider = pick;
        modelId = pickModel;
        await refreshHistory();
    }

    async def toggleWidget -> None {
        nextOpen = not widgetOpen;
        widgetOpen = nextOpen;
        if nextOpen {
            await loadOnce();
        }
    }

    def closeWidget(e: MouseEvent) -> None {
        widgetOpen = False;
    }

    def pickProvider(pid: str) -> None {
        provider = pid;
        keyInput = "";
        keyErr = "";
        mdls = _modelsFor(providers, pid);
        modelId = str(mdls[0]) if len(mdls) > 0 else "";
    }

    def pickModel(v: str) -> None {
        modelId = v;
    }

    def updateDraft(v: str) -> None {
        draft = v;
    }

    def noopChip(cid: str) -> None { }

    async def toggleHistory -> None {
        nextHistory = not historyOpen;
        historyOpen = nextHistory;
        if nextHistory {
            await refreshHistory();
        }
    }

    async def newChat -> None {
        chatId = "";
        messages = [];
        historyOpen = False;
    }

    async def openChat(cid: str) -> None {
        try {
            rows = await get_messages(cid);
            ms: list[dict] = [];
            for r in rows {
                ms.append({
                    "role": r.role, "content": r.content, "stats": None,
                    "modelId": r.model_id, "pairGroup": "",
                    "streaming": False, "error": ""
                });
            }
            messages = ms;
            chatId = cid;
        } except Exception { }
        historyOpen = False;
    }

    async def removeChat(cid: str) -> None {
        try {
            await delete_chat(cid);
            await refreshHistory();
        } except Exception { }
        if cid == chatId {
            chatId = "";
            messages = [];
        }
    }

    """Save the Claude/OpenAI key for whichever provider is selected, then
    re-check configured status so the drawer can flip back to the chat."""
    async def saveKey -> None {
        val = keyInput.strip();
        if not val {
            keyErr = "enter a key first";
            return;
        }
        keyBusy = True;
        keyErr = "";
        res: any = None;
        try {
            if provider == "claude" {
                res = await set_anthropic_key(val);
            } elif provider == "openai" {
                res = await set_openai_key(val);
            }
        } except Exception {
            keyErr = "save failed";
            keyBusy = False;
            return;
        }
        if res and not res["ok"] {
            keyErr = str(res["error"]);
            keyBusy = False;
            return;
        }
        keyInput = "";
        keyBusy = False;
        await refreshProviders();
    }

    # Cancel the in-flight stream (if any) so the composer frees up immediately.
    async def stop -> None {
        r: any = activeReader;
        if r {
            try {
                await r.cancel();
            } except Exception { }
        }
    }

    async def send(text: str) -> None {
        prompt = text.strip();
        info = _providerInfo(providers, provider);
        gated = bool(info and bool(info["requires_key"]) and not bool(info["configured"]));
        if not prompt or streaming or not modelId or gated {
            return;
        }
        draft = "";
        streaming = True;

        cid = chatId;
        try {
            if not cid {
                cv = await create_chat(prompt[:40], "assistant");
                cid = cv.id;
                chatId = cid;
            }
            await add_message(cid, "user", prompt, "", "", "");
        } except Exception { }

        hist: list[dict] = [];
        work: list[dict] = [];
        for mm in messages {
            work.append(mm);
            if not mm["error"] {
                hist.append({"role": str(mm["role"]), "content": str(mm["content"])});
            }
        }
        work.append({
            "role": "user", "content": prompt, "stats": None,
            "modelId": "", "pairGroup": "", "streaming": False, "error": ""
        });
        hist.append({"role": "user", "content": prompt});

        work.append({
            "role": "assistant", "content": "", "stats": None,
            "modelId": modelId, "pairGroup": "", "streaming": True, "error": ""
        });
        ai = len(work) - 1;
        messages = list(work);

        acc = "";
        errtext = "";
        try {
            # Assemble the grounding context HERE (a normal sv call = correct
            # user-root). assistant_stream is an SSE generator whose body runs
            # deferred, outside the auth root, so it can't read the graph itself.
            ctx: str = "";
            try { ctx = await assistant_context(); } except Exception { ctx = ""; }
            fullCtx = ("CURRENT PAGE: " + pageContext + "\n\n" + ctx) if pageContext else ctx;
            # Raw fetch (not sv import) → bearer token + 401 recovery, same as Chat.cl.jac.
            hdrs: dict = bearerHeaders();
            body: str = JSON.stringify({
                "messages": hist, "provider": provider, "model_id": modelId,
                "context": fullCtx,
                "temperature": 0.3, "top_p": 0.9, "max_tokens": 1536
            });
            resp: any = await fetch(
                "/function/assistant_stream",
                {"method": "POST", "headers": hdrs, "body": body}
            );
            if int(str(resp.status)) == 401 {
                restored: bool = False;
                restored = await handleUnauthorized();
                if restored {
                    hdrs = bearerHeaders();
                    resp = await fetch(
                        "/function/assistant_stream",
                        {"method": "POST", "headers": hdrs, "body": body}
                    );
                }
            }
            if int(str(resp.status)) == 401 {
                errtext = "session expired — sign in again";
                activeReader = None;
                work[ai] = {
                    "role": "assistant", "content": acc, "stats": None,
                    "modelId": modelId, "pairGroup": "", "streaming": False,
                    "error": errtext
                };
                messages = list(work);
                streaming = False;
                return;
            }
            reader: any = resp.body.getReader();
            activeReader = reader;
            dec: any = new(TextDecoder);
            nl = String.fromCharCode(10);
            sep = nl + nl;
            buf = "";
            streamEnded = False;
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
                    evt = "message";
                    for line in parts[i].split(nl) {
                        if len(line) >= 5 and line[:5] == "data:" {
                            data = data + line[5:].strip();
                        } elif len(line) >= 6 and line[:6] == "event:" {
                            evt = line[6:].strip();
                        }
                    }
                    # jaclang SSE framing sends a sentinel "event: end"/"event: error"
                    # frame rather than closing the socket — without this check the
                    # read loop waits forever on a chunk.done that never comes.
                    if evt == "end" {
                        streamEnded = True;
                    } elif evt == "error" {
                        errtext = str(data) if data else "stream failed";
                        streamEnded = True;
                    } elif data {
                        try {
                            msg: any = JSON.parse(data);
                            if msg.kind == "token" {
                                acc = str(msg.text);
                                work[ai] = {
                                    "role": "assistant", "content": acc, "stats": None,
                                    "modelId": modelId, "pairGroup": "",
                                    "streaming": True, "error": ""
                                };
                                messages = list(work);
                            } elif msg.kind == "done" {
                                work[ai] = {
                                    "role": "assistant", "content": acc, "stats": None,
                                    "modelId": modelId, "pairGroup": "",
                                    "streaming": False, "error": ""
                                };
                                messages = list(work);
                            } elif msg.kind == "error" {
                                errtext = str(msg.text);
                            }
                        } except Exception { }
                    }
                    i += 1;
                }
                if streamEnded {
                    try {
                        await reader.cancel();
                    } except Exception { }
                    break;
                }
            }
        } except Exception as e {
            errtext = "stream failed";
        }
        activeReader = None;
        # Unconditional finalize covers a normal "done" frame, a mid-stream error
        # (errtext set), and an early stop via reader.cancel() (neither done nor
        # error frame arrives) — this is what always clears the streaming flag.
        work[ai] = {
            "role": "assistant", "content": acc, "stats": None,
            "modelId": modelId, "pairGroup": "", "streaming": False, "error": errtext
        };
        messages = list(work);
        streaming = False;

        if acc {
            try {
                await add_message(cid, "assistant", acc, modelId, "", "");
                await refreshHistory();
            } except Exception { }
        }
    }

    curModels: list[str] = _modelsFor(providers, provider);
    curInfo: dict | None = _providerInfo(providers, provider);
    needsKey: bool = bool(curInfo and bool(curInfo["requires_key"]) and not bool(curInfo["configured"]));
    connectLabel: str = str(curInfo["label"]) if curInfo else provider;

    return <div>
        <button
            onClick={lambda e: MouseEvent { toggleWidget(); }}
            title="ask the assistant"
            className="assistant-launcher fixed bottom-6 right-6 z-40 flex h-14 w-14 items-center justify-center rounded-full text-xl transition-colors"
            style={{
                "background": "var(--surface-strong)",
                "backdropFilter": "var(--blur)",
                "border": "1px solid var(--border)",
                "boxShadow": "var(--shadow-nav)"
            }}
        >✦</button>

        {if widgetOpen {
            <div className="fixed inset-0 z-50 flex">
                <div
                    className="flex-1 bg-black/60"
                    onClick={closeWidget}
                />
                <aside className="exp-panel flex h-full w-[34rem] max-w-[92vw] shrink-0 flex-col !rounded-none !border-y-0 !border-r-0">
                    <div className="flex items-center justify-between border-b border-border px-4 py-3">
                        <span className="micro-label">✦ ASSISTANT</span>
                        <div className="flex items-center gap-2">
                            <button
                                onClick={lambda e: MouseEvent { toggleHistory(); }}
                                className={"exp-btn " + ("exp-chip-active" if historyOpen else "")}
                            >⧉ HISTORY</button>
                            <button
                                onClick={closeWidget}
                                className="text-muted-foreground hover:text-foreground"
                            >✕</button>
                        </div>
                    </div>

                    {if historyOpen {
                        <div className="flex-1 overflow-y-auto border-b border-border px-4 py-3">
                            <button
                                onClick={lambda e: MouseEvent { newChat(); }}
                                className="exp-btn exp-btn-accent mb-2 w-full"
                            >+ NEW CHAT</button>
                            {if len(chats) == 0 {
                                <p className="stat-line">no saved chats yet</p>
                                skip;
                            }}
                            {for c in chats {
                                <div key={str(c.id)} className="mb-1 flex items-center gap-2">
                                    <button
                                        onClick={lambda e: MouseEvent { openChat(str(c.id)); }}
                                        className={"exp-btn flex-1 truncate text-left " + ("exp-chip-active" if str(c.id) == chatId else "")}
                                    >{str(c.title) if c.title else "untitled"}</button>
                                    <button
                                        onClick={lambda e: MouseEvent { removeChat(str(c.id)); }}
                                        className="text-muted-foreground hover:text-foreground"
                                        title="delete"
                                    >✕</button>
                                </div>
                            }}
                        </div>
                        skip;
                    }}

                    {if not historyOpen {
                        <div className="flex flex-wrap items-center gap-1.5 border-b border-border px-4 py-3">
                            {for p in providers {
                                pid = str(p["id"]);
                                <button
                                    key={pid}
                                    onClick={lambda e: MouseEvent { pickProvider(pid); }}
                                    className={"exp-chip " + ("exp-chip-active" if pid == provider else "")}
                                >{str(p["label"])}</button>
                            }}
                        </div>
                        skip;
                    }}

                    {if not historyOpen and not needsKey and len(curModels) > 0 {
                        <div className="border-b border-border px-4 py-2">
                            <select
                                value={modelId}
                                onChange={lambda e: ChangeEvent { pickModel(str(e.target.value)); }}
                                className="exp-input w-full"
                            >
                                {for mid in curModels {
                                    <option key={mid} value={mid}>{mid}</option>
                                }}
                            </select>
                        </div>
                        skip;
                    }}
                    {if not historyOpen and not needsKey and len(curModels) == 0 {
                        <div className="border-b border-border px-4 py-2">
                            <span className="stat-line">no models available for this provider</span>
                        </div>
                        skip;
                    }}

                    {if not historyOpen and needsKey {
                        <div className="flex flex-1 flex-col gap-3 overflow-y-auto px-4 py-4">
                            <h3 className="text-sm font-medium text-foreground">{"Connect " + connectLabel}</h3>
                            <p className="stat-line">Enter your API key to continue.</p>
                            <input
                                type="password"
                                className="exp-input w-full"
                                value={keyInput}
                                placeholder="sk-…"
                                onChange={lambda e: ChangeEvent { keyInput = str(e.target.value); keyErr = ""; }}
                            />
                            {keyErr and <span className="stat-line" style={{"color": "var(--danger)"}}>{keyErr}</span>}
                            <button
                                onClick={lambda e: MouseEvent { saveKey(); }}
                                disabled={keyBusy}
                                className="exp-btn exp-btn-accent"
                            >{"SAVING…" if keyBusy else "Save & Continue"}</button>
                        </div>
                        skip;
                    }}

                    {if not historyOpen and not needsKey {
                        <Thread messages={messages} labels={{}} onSave={None} />
                        <Composer
                            value={draft} busy={streaming} categories={[]}
                            onSet={updateDraft}
                            onSend={send}
                            onStop={stop}
                            onChip={noopChip}
                        />
                        skip;
                    }}
                </aside>
            </div>
            skip;
        }}
    </div>;
}
