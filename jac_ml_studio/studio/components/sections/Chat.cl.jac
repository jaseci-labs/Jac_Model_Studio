"""CHAT section — 3-pane: history sidebar | thread + composer | sampling rail.

Ports ui/components/chat-section.tsx + use-studio.ts. Chats persist to the OSP
graph (persistence.sv.jac). Completion streams from /function/chat_stream (raw
SSE fetch reader). The model picker is a pill+popover; picking a model eagerly
warms it (warm_model) with a client-side elapsed timer, and the sidebar MEM gauge
reflects the real resident model (loaded_model). COMPARE mode streams two models
sequentially (only one fits in 48GB) into a paired side-by-side row.
"""

sv import from ...models {
    list_models, system_ram, loaded_model, warm_model, ModelView
}
sv import from ...prompts { list_prompts }
sv import from ...data { add_examples }
sv import from ...persistence {
    create_chat, list_chats, delete_chat, get_messages, add_message, today_utc,
    ChatView, MsgView
}
import from ..chat.Sidebar { Sidebar }
import from ..chat.Rail { Rail }
import from ..chat.ModelPill { ModelPill }
import from ..chat.Thread { Thread }
import from ..chat.Composer { Composer }

def _r1(v: any) -> float {
    return float(int(float(str(v)) * 10.0 + 0.5)) / 10.0;
}

def _uuid() -> str {
    c: any = crypto;
    return str(c.randomUUID());
}

def:pub Chat -> JsxElement {
    has models: list[ModelView] = [],
        chats: list = [],
        chatId: str = "",
        messages: list[dict] = [],
        modelId: str = "",
        compareId: str = "",
        draft: str = "",
        streaming: bool = False,
        temperature: float = 0.2,
        topP: float = 0.9,
        maxTokens: int = 1024,
        ramGb: float = 0.0,
        residentGb: float = 0.0,
        loadedId: str = "",
        loadingId: str = "",
        loadElapsed: int = 0,
        loadError: str = "",
        todayIso: str = "",
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
        todayIso = await today_utc();
        cs = await list_chats();
        chats = cs;
        pr = await list_prompts();
        prompts = list(pr["categories"]);
        await refreshLoaded();
    }

    async def refreshLoaded -> None {
        li = await loaded_model();
        loadedId = str(li["id"]);
        residentGb = float(str(li["resident_gb"]));
    }

    def labelMap -> dict {
        out: dict = {};
        for m in models {
            out[str(m.id)] = str(m.label);
        }
        return out;
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
            st: any = JSON.parse(r.stats_json) if r.stats_json else None;
            ms.append({
                "role": r.role, "content": r.content, "stats": st,
                "modelId": r.model_id, "pairGroup": r.pair_group,
                "streaming": False, "error": ""
            });
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

    # Eagerly warm a model so the next send streams immediately; pill shows elapsed.
    async def loadModel(id: str) -> None {
        if streaming {
            return;
        }
        modelId = id;
        if id == compareId {
            compareId = "";
        }
        loadError = "";
        loadingId = id;
        loadElapsed = 0;
        dt: any = Date;
        t0: float = float(str(dt.now()));
        tid: any = setInterval(lambda -> None {
            cur: any = Date;
            loadElapsed = int((float(str(cur.now())) - t0) / 1000.0);
        }, 500);
        r = await warm_model(id);
        clearInterval(int(str(tid)));
        loadingId = "";
        loadElapsed = 0;
        if r["error"] {
            loadError = str(r["error"]);
        }
        await refreshLoaded();
    }

    # Stream one model's completion into a fresh assistant bubble appended to `work`.
    async def runLeg(
        work: list[dict], histBase: list[dict], prompt: str,
        legModel: str, cid: str, pg: str
    ) -> None {
        hist: list[dict] = [];
        for h in histBase {
            if not h["pair"] or h["model"] == legModel {
                hist.append({"role": h["role"], "content": h["content"]});
            }
        }
        hist.append({"role": "user", "content": prompt});

        work.append({
            "role": "assistant", "content": "", "stats": None,
            "modelId": legModel, "pairGroup": pg, "streaming": True, "error": ""
        });
        ai = len(work) - 1;
        messages = list(work);

        acc = "";
        donestats: any = None;
        errtext = "";
        try {
            resp: any = await fetch(
                "/function/chat_stream",
                {
                    "method": "POST",
                    "headers": {"Content-Type": "application/json"},
                    "body": JSON.stringify({
                        "messages": hist, "model_id": legModel,
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
                            if msg.kind == "token" {
                                acc = str(msg.text);
                                work[ai] = {
                                    "role": "assistant", "content": acc, "stats": None,
                                    "modelId": legModel, "pairGroup": pg,
                                    "streaming": True, "error": ""
                                };
                                messages = list(work);
                            } elif msg.kind == "done" {
                                donestats = {
                                    "tps": _r1(msg.tps), "tokens": msg.tokens,
                                    "gen_s": _r1(msg.gen_s), "load_s": msg.load_s
                                };
                                work[ai] = {
                                    "role": "assistant", "content": acc, "stats": donestats,
                                    "modelId": legModel, "pairGroup": pg,
                                    "streaming": False, "error": ""
                                };
                                messages = list(work);
                                lastStats = donestats;
                            } elif msg.kind == "error" {
                                errtext = str(msg.text);
                            }
                        } except Exception { }
                    }
                    i += 1;
                }
            }
        } except Exception as e {
            errtext = "stream failed";
        }
        if errtext {
            work[ai] = {
                "role": "assistant", "content": acc, "stats": None,
                "modelId": legModel, "pairGroup": pg, "streaming": False, "error": errtext
            };
            messages = list(work);
        } elif acc {
            sj = JSON.stringify(donestats) if donestats else "";
            await add_message(cid, "assistant", acc, legModel, sj, pg);
        }
    }

    async def send(text: str) -> None {
        prompt = text.strip();
        if not prompt or streaming or not modelId {
            return;
        }
        draft = "";
        streaming = True;
        cid = chatId;
        if not cid {
            c = await create_chat(prompt[:40]);
            cid = c.id;
            chatId = cid;
        }
        cmp = compareId;
        pg = _uuid() if cmp else "";

        histBase: list[dict] = [];
        work: list[dict] = [];
        for mm in messages {
            work.append(mm);
            if not mm["error"] {
                histBase.append({
                    "role": str(mm["role"]), "content": str(mm["content"]),
                    "pair": str(mm["pairGroup"]), "model": str(mm["modelId"])
                });
            }
        }
        work.append({
            "role": "user", "content": prompt, "stats": None,
            "modelId": "", "pairGroup": "", "streaming": False, "error": ""
        });
        messages = list(work);
        await add_message(cid, "user", prompt, "", "", "");

        await runLeg(work, histBase, prompt, modelId, cid, pg);
        if cmp {
            await runLeg(work, histBase, prompt, cmp, cid, pg);
        }

        cs = await list_chats();
        chats = cs;
        streaming = False;
        await refreshLoaded();
    }

# Capture a user→assistant turn as an SFT example (sft.jsonl) via the Data backend.
    async def saveExample(userText: str, asstText: str) -> None {
        if not userText or not asstText {
            return;
        }
        rec = JSON.stringify({"messages": [
            {"role": "user", "content": userText},
            {"role": "assistant", "content": asstText}
        ]});
        await add_examples(target="sft", jsonl=rec);
    }

    def pickChip(catId: str) -> None {
        for cat in prompts {
            if str(cat["id"]) == catId {
                prs = list(cat["prompts"]);
                if len(prs) > 0 {
                    draft = str(prs[0]);
                }
                break;
            }
        }
    }

    return <div className="flex h-full min-w-0 flex-1 overflow-hidden">
        <Sidebar
            chats={chats} activeId={chatId} ramGb={ramGb} residentGb={residentGb}
            todayIso={todayIso} busy={streaming}
            onNew={newChat} onOpen={openChat} onDelete={removeChat}
        />
        <main className="flex min-w-0 flex-1 flex-col">
            <ModelPill
                models={models} modelId={modelId} compareId={compareId}
                loadedId={loadedId} loadingId={loadingId} loadElapsed={loadElapsed}
                loadError={loadError}
                onPick={loadModel}
                onPickCompare={lambda id: str { compareId = id; }}
            />
            <Thread messages={messages} labels={labelMap()} onSave={saveExample} />
            <Composer
                value={draft} busy={streaming} categories={prompts}
                onSet={lambda v: str { draft = v; }}
                onSend={send}
                onChip={pickChip}
            />
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
