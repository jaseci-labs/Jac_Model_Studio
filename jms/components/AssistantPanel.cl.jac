"""AssistantPanel — grounded in-app AI assistant, in a glass slide-over drawer.

Task A4 of the phase-2 grounded-assistant feature. Mounted once at each shell
level (JmsShell + AppShell — see Task A6) and toggled via a global `✦ ASK`
button in the shared `WorkspaceBar`. On mount it fetches `assistant_providers()`
(mlx/claude/openai — API providers carry `requires_key`/`configured`) and picks
a sane default: local MLX if it has any model on disk, else the first
configured API provider, else whatever's first. Sending a message streams
`/function/assistant_stream` with the exact raw-fetch-reader pattern
`Chat.cl.jac` uses for `/function/chat_stream` (same SSE frame protocol:
`load`/`token`/`done`/`error`, plus the jaclang `event: end` / `event: error`
sentinel frame the generator-backed endpoint sends instead of closing the
socket — miss it and the reader hangs forever). Grounding (full app state:
workspaces, projects, runs, evals, deployments) happens entirely server-side —
this component sends only the raw message list, provider, and model_id.

Reuses `chat/Thread` for the bubble list and `chat/Composer` for the input —
both already glass-styled and theme-aware — rather than hand-rolling either.
"""

sv import from ..assistant { assistant_providers }
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

def:pub AssistantPanel(open: bool, onClose: any) -> JsxElement {
    has providers: list[dict] = [],
        provider: str = "mlx",
        modelId: str = "",
        messages: list[dict] = [],
        draft: str = "",
        streaming: bool = False,
        activeReader: any = None;

    async can with entry {
        try {
            res = await assistant_providers();
            plist: list[dict] = [];
            for p in list(res["providers"]) {
                plist.append(p as dict);
            }
            providers = plist;

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
            }
            provider = pick;
            modelId = pickModel;
        } except Exception { }
    }

    def pickProvider(pid: str) -> None {
        provider = pid;
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
        if not prompt or streaming or not modelId {
            return;
        }
        draft = "";
        streaming = True;

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
            # Raw fetch (not sv import) → bearer token + 401 recovery, same as Chat.cl.jac.
            hdrs: dict = bearerHeaders();
            body: str = JSON.stringify({
                "messages": hist, "provider": provider, "model_id": modelId,
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
    }

    if not open {
        return <></>;
    }

    curModels: list[str] = _modelsFor(providers, provider);

    return <div className="fixed inset-0 z-50 flex">
        <div
            className="flex-1 bg-black/60"
            onClick={lambda e: MouseEvent { onClose(); }}
        />
        <aside className="exp-panel flex h-full w-[34rem] max-w-[92vw] shrink-0 flex-col !rounded-none !border-y-0 !border-r-0">
            <div className="flex items-center justify-between border-b border-border px-4 py-3">
                <span className="micro-label">✦ ASSISTANT</span>
                <button
                    onClick={lambda e: MouseEvent { onClose(); }}
                    className="text-muted-foreground hover:text-foreground"
                >✕</button>
            </div>

            <div className="flex flex-wrap items-center gap-1.5 border-b border-border px-4 py-3">
                {for p in providers {
                    pid = str(p["id"]);
                    requiresKey = bool(p["requires_key"]);
                    configured = bool(p["configured"]);
                    gated = requiresKey and not configured;
                    <button
                        key={pid}
                        disabled={gated}
                        title={"set key in ⚙ KEYS" if gated else str(p["label"])}
                        onClick={lambda e: MouseEvent { pickProvider(pid); }}
                        className={"exp-chip " + ("exp-chip-active" if pid == provider else "")}
                    >{str(p["label"])}{" 🔒" if gated else ""}</button>
                }}
            </div>

            {if len(curModels) > 0 {
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
            {if len(curModels) == 0 {
                <div className="border-b border-border px-4 py-2">
                    <span className="stat-line">no models available — set a key in ⚙ KEYS, or add a local MLX model</span>
                </div>
                skip;
            }}

            <Thread messages={messages} labels={{}} onSave={None} />

            <Composer
                value={draft} busy={streaming} categories={[]}
                onSet={updateDraft}
                onSend={send}
                onStop={stop}
                onChip={noopChip}
            />
        </aside>
    </div>;
}
