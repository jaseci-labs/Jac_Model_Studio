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
sv import from ..train { start_training }
sv import from ..evals { create_eval }
sv import from ..workspace { update_workspace, ui_layout }
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

"""Locate the action JSON object regardless of how the model wrapped it — the
canonical <<DO>>{...}<</DO>>, a ```DO``` code fence, or a bare {...}. We anchor on
the '"action"' key, walk back to its enclosing '{', then brace-match forward to the
close. Returns (start, endExclusive) or (-1, -1). Weak local models drift on the
exact marker but keep the JSON intact, so anchoring on the JSON is far more robust
than requiring literal markers."""
def _actionSpan(s: str) -> list {
    key = s.find("\"action\"");
    if key < 0 { return [-1, -1]; }
    start = s[:key].rfind("{");
    if start < 0 { return [-1, -1]; }
    depth = 0;
    i = start;
    while i < len(s) {
        c = s[i];
        if c == "{" { depth += 1; }
        elif c == "}" {
            depth -= 1;
            if depth == 0 { return [start, i + 1]; }
        }
        i += 1;
    }
    return [-1, -1];
}

"""Extract the assistant's action block into a dict (empty if absent/malformed)."""
def _parseAction(text: str) -> dict {
    s = str(text);
    span = _actionSpan(s);
    if span[0] < 0 { return {}; }
    try {
        d = JSON.parse(s[span[0]:span[1]]) as dict;
        if "action" in d { return d; }
    } except Exception { }
    return {};
}

"""The reply with the action block (and any ``` fence / <<DO>> marker wrapping it)
removed, so the chat bubble never shows raw JSON. The block is always last, so we
cut from the earliest wrapper-or-'{' to the end and tidy trailing fence chars."""
def _stripAction(text: str) -> str {
    s = str(text);
    span = _actionSpan(s);
    if span[0] < 0 { return s; }
    cut = span[0];
    for mark in ["<<DO>>", "```DO```", "```DO", "```json", "```"] {
        p = s.find(mark);
        if p >= 0 and p < cut { cut = p; }
    }
    head = s[:cut];
    # drop a trailing lone ``` / backticks / whitespace left above the block
    return head.rstrip().rstrip("`").rstrip();
}

"""Human label for an action, for the confirm card / nav breadcrumb."""
def _actionLabel(a: dict) -> str {
    act = str(a["action"]) if "action" in a else "";
    if act == "navigate" {
        parts: list = [];
        if "surface" in a and a["surface"] { parts.append(str(a["surface"])); }
        if "workspace" in a and a["workspace"] { parts.append(str(a["workspace"])); }
        if "stage" in a and a["stage"] { parts.append(str(a["stage"])); }
        return "Go to " + " · ".join(parts);
    }
    if act == "start_training" {
        md = str(a["mode"]).upper() if "mode" in a else "";
        nm = str(a["name"]) if "name" in a else "";
        return "Start " + md + " training: " + nm;
    }
    if act == "create_eval" {
        return "Create eval: " + (str(a["kind"]) if "kind" in a else "");
    }
    if act == "set_setting" {
        return "Update workspace " + (str(a["wid"]) if "wid" in a else "") + " settings";
    }
    return act;
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
        pendingAction: dict = {},
        actionNote: str = "",
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

    """Auto-run a navigate action. Cross-surface via location.hash + a synthetic
    popstate (frontend.cl.jac listens); experiments workspace/stage via the
    window.__jmsNav bridge AppShell republishes each render, on a short delay so a
    fresh AppShell (when we just switched onto the experiments surface) has mounted
    and registered the bridge before we call it. Closes the drawer so the user sees
    where they landed."""
    async def runNavigate(a: dict) -> None {
        w: any = window;
        ws = str(a["workspace"]) if "workspace" in a else "";
        stage = str(a["stage"]) if "stage" in a else "";
        # Normalize the surface: weak models echo the whole enum ("experiments|
        # jms|hub") or add prose. Ignore piped/garbled values and match by
        # substring; a workspace/stage with no clean surface implies Experiments.
        sraw = str(a["surface"]) if "surface" in a else "";
        surface = "";
        if "|" not in sraw {
            sl = sraw.lower();
            if "experiment" in sl { surface = "experiments"; }
            elif "jms" in sl { surface = "jms"; }
            elif "hub" in sl { surface = "hub"; }
        }
        if (not surface) and (ws or stage) { surface = "experiments"; }
        target = surface if (surface == "experiments" or surface == "jms") else "";
        if surface {
            # Setting the hash fires a native hashchange; frontend.cl.jac listens
            # for it and swaps the surface. No synthetic event needed.
            try { w.location.hash = target; } except Exception { }
        }
        if surface == "experiments" {
            if ws or stage {
                # Poll for the __jmsNav bridge: a freshly-mounted AppShell (when we
                # just switched surfaces) only publishes it after its probe+layout
                # finish (~a few seconds), so a fixed delay would miss it. Give up
                # after ~9s so a broken bridge can't leak an interval.
                tries: any = {"n": 0};
                iv: any = None;
                iv = setInterval(lambda -> None {
                    tries["n"] = int(tries["n"]) + 1;
                    nav: any = w.__jmsNav;
                    if nav {
                        if ws { nav.goWorkspace(ws); }
                        if stage { nav.go(stage); }
                        clearInterval(float(str(iv)));
                    } elif int(tries["n"]) > 60 {
                        clearInterval(float(str(iv)));
                    }
                }, 150);
            }
        }
        actionNote = "↪ " + _actionLabel(a);
        widgetOpen = False;
    }

    """Execute a confirm-gated action (training / eval / settings) on the user's
    Confirm click. Reuses the existing server endpoints; set_setting reads the
    current workspace first and merges so unspecified fields aren't clobbered."""
    async def runConfirmed -> None {
        a: dict = pendingAction;
        if "action" not in a { return; }
        act = str(a["action"]) if "action" in a else "";
        actionNote = "running…";
        try {
            if act == "start_training" {
                nm = str(a["name"]) if ("name" in a and a["name"]) else "assistant-run";
                md = str(a["mode"]) if "mode" in a else "sft";
                mid = str(a["model_id"]) if ("model_id" in a and a["model_id"]) else modelId;
                await start_training(nm, md, mid, {}, "");
                actionNote = "✓ started " + md.upper() + " training '" + nm + "'";
            } elif act == "create_eval" {
                kd = str(a["kind"]) if "kind" in a else "";
                mid = str(a["model_id"]) if ("model_id" in a and a["model_id"]) else "";
                hd = str(a["holdout"]) if ("holdout" in a and a["holdout"]) else "function";
                lm = int(a["limit"]) if ("limit" in a and a["limit"]) else 0;
                r: any = await create_eval(kd, mid, "", "", hd, lm, 0.0);
                actionNote = ("✓ eval '" + kd + "' created") if r else "✗ eval rejected (bad kind/model)";
            } elif act == "set_setting" {
                wid = str(a["wid"]) if "wid" in a else "";
                ly: any = await ui_layout();
                cur: dict | None = None;
                for wsx in list(ly["workspaces"]) {
                    if str((wsx as dict)["id"]) == wid { cur = wsx as dict; }
                }
                if cur is None {
                    actionNote = "✗ no workspace " + wid;
                    pendingAction = {};
                    return;
                }
                nl2 = str(a["label"]) if ("label" in a and a["label"]) else str(cur["label"]);
                nac = str(a["accent"]) if ("accent" in a and a["accent"]) else str(cur["accent"]);
                ndm = str(a["default_model"]) if ("default_model" in a and a["default_model"]) else str(cur["default_model"]);
                await update_workspace(wid, nl2, nac, ndm, list(cur["files"]));
                actionNote = "✓ updated workspace " + wid;
            } else {
                actionNote = "✗ unknown action";
            }
        } except Exception as e {
            actionNote = "✗ failed: " + str(e);
        }
        pendingAction = {};
    }

    def cancelAction -> None {
        pendingAction = {};
        actionNote = "cancelled";
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
        pendingAction = {};
        actionNote = "";

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
        # Pull out any ⟦DO⟧ action block; store/display only the stripped prose.
        act2: dict = _parseAction(acc);
        disp: str = _stripAction(acc);
        work[ai] = {
            "role": "assistant", "content": disp, "stats": None,
            "modelId": modelId, "pairGroup": "", "streaming": False, "error": errtext
        };
        messages = list(work);
        streaming = False;

        if disp {
            try {
                await add_message(cid, "assistant", disp, modelId, "", "");
                await refreshHistory();
            } except Exception { }
        }
        # Dispatch the action: navigate runs immediately (reversible), everything
        # else waits behind a Confirm click (compute + heavy-job lock).
        if act2 {
            if str(act2["action"]) == "navigate" {
                await runNavigate(act2);
            } else {
                pendingAction = act2;
                actionNote = "";
            }
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
                <aside className="exp-panel g-overlay flex h-full w-[34rem] max-w-[92vw] shrink-0 flex-col !rounded-none !border-y-0 !border-r-0">
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
                        skip;
                    }}
                    {if not historyOpen and not needsKey and "action" in pendingAction {
                        <div className="border-t border-border px-4 py-3">
                            <p className="stat-line mb-2">⚑ {_actionLabel(pendingAction)}</p>
                            <div className="flex gap-2">
                                <button
                                    onClick={lambda e: MouseEvent { runConfirmed(); }}
                                    className="exp-btn exp-btn-accent"
                                >CONFIRM & RUN</button>
                                <button
                                    onClick={lambda e: MouseEvent { cancelAction(); }}
                                    className="exp-btn"
                                >CANCEL</button>
                            </div>
                        </div>
                        skip;
                    }}
                    {if not historyOpen and not needsKey and actionNote and "action" not in pendingAction {
                        <div className="border-t border-border px-4 py-2">
                            <span className="stat-line">{actionNote}</span>
                        </div>
                        skip;
                    }}
                    {if not historyOpen and not needsKey {
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
