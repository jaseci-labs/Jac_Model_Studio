"""EvalStage — the EVAL · CHAT stage panel of a JMS project (the final stage).

Two sub-tabs (EVAL | CHAT), both driven by the project's COMPLETED local-mlx train
runs (a run must carry a LoRA adapter on disk; spheron runs are unsupported here —
their base weights aren't local — and are noted).

EVAL: pick a completed run, a metric (judge = Claude LLM-as-judge, disabled with a
hint when no Anthropic key is configured / similarity = offline difflib), a row
limit (0 = all holdout rows), then SCORE ON HOLDOUT. The project's evals list
(eid · run · metric · status dot · n · mean · pass% · elapsed); selecting one shows
summary StatTiles + a paginated row browser (prompt excerpt, reference vs
generated stacked, score chip, rationale). Polls list_jms_evals/eval_status every
2s ONLY while `active` (this stage is the visible one) — the interval id is
effect-local so the cleanup can actually see it (Cloud.cl.jac pattern).

CHAT: pick a completed run, then a minimal in-memory chat (cleared on unmount — no
persistence, YAGNI) that streams from jms_chat_stream via the SAME raw SSE fetch
reader Chat.cl.jac uses (bearer + 401 recovery). Temperature slider + STOP.

`project` is the get_project() dict; `onRefresh` re-pulls it. Handlers are named
start.../select.../pick.../send.../stop... — never set<HasVar>."""

import from react { useEffect, useRef }
sv import from ....jms_eval { start_eval, eval_status, eval_rows, list_jms_evals, stop_eval_run }
sv import from ....jms_train { list_train_runs }
sv import from ....jms_llm { llm_status }
import from ...shared.StatTile { StatTile }
import from ....auth_session { bearerHeaders, handleUnauthorized }

def _g(d: any, k: str, fallback: str) -> str {
    if d and k in d { return str(d[k]); }
    return fallback;
}

def _toInt(s: str) -> int {
    try { return int(float(s.strip())); } except Exception { return 0; }
}

def _r2(v: any) -> str {
    try { return str(Math.round(float(str(v)) * 100.0) / 100.0); }
    except Exception { return "0"; }
}

def _pct(v: any) -> str {
    try { return str(Math.round(float(str(v)) * 1000.0) / 10.0) + "%"; }
    except Exception { return "0%"; }
}

def:pub EvalStage(project: any = None, onRefresh: any = None, active: bool = True) -> JsxElement {
    has subtab: str = "eval",
        runs: list = [],
        keyConfigured: bool = False,
        evalRunRid: str = "",
        metric: str = "judge",
        limitStr: str = "0",
        evals: list = [],
        selEid: str = "",
        selData: any = None,
        rows: list = [],
        rowsOffset: int = 0,
        rowsTotal: int = 0,
        expanded: int = -1,
        startBusy: bool = False,
        startErr: str = "",
        startNote: str = "",
        chatRunRid: str = "",
        chatMessages: list = [],
        chatDraft: str = "",
        chatStreaming: bool = False,
        chatStopReq: bool = False,
        chatTemp: float = 0.2;

    # The SSE reader lives in a ref, not in `has` state: an unmount cleanup closes
    # over the FIRST render's value of a state var (always None) and so could never
    # cancel the stream. A ref is the same object on every render.
    chatReaderRef: any = useRef(None);

    def _pid -> str {
        if project { return str(project["pid"]); }
        return "";
    }

    # Completed, chattable/evaluable runs: local-mlx only. The server re-validates
    # the adapter is on disk, so the client filter stays coarse (backend + status).
    def _completedRuns -> list {
        out: list = [];
        for r in runs {
            if _g(r, "backend", "") == "local-mlx" and _g(r, "status", "") == "completed" {
                out.append(r);
            }
        }
        return out;
    }

    def _anySpheron -> bool {
        for r in runs {
            if _g(r, "backend", "") == "spheron" { return True; }
        }
        return False;
    }

    def _anyRunningEval -> bool {
        for e in evals {
            if _g(e, "status", "") == "running" { return True; }
        }
        return False;
    }

    async def refreshRuns -> None {
        try {
            rl = await list_train_runs(_pid());
            runs = list(rl);
            cr = _completedRuns();
            if evalRunRid == "" and len(cr) > 0 { evalRunRid = _g(cr[0], "rid", ""); }
            if chatRunRid == "" and len(cr) > 0 { chatRunRid = _g(cr[0], "rid", ""); }
        } except Exception {}
    }

    async def refreshEvals -> None {
        try {
            el = await list_jms_evals(_pid());
            evals = list(el);
            if selEid {
                sd = await eval_status(_pid(), selEid);
                selData = sd;
            }
        } except Exception {}
    }

    async def reloadKey -> None {
        try {
            st = await llm_status();
            keyConfigured = bool(st and st["configured"]);
        } except Exception { keyConfigured = False; }
    }

    def _cancelReader -> None {
        r: any = chatReaderRef.current;
        chatReaderRef.current = None;
        if r {
            try { r.cancel(); } except Exception {}
        }
    }

    async can with entry {
        await reloadKey();
        await refreshRuns();
    }

    # Effect-local interval id + `active` gate: a `can with exit` cleanup closes over
    # the first-render (None) value of a `has` var, so it never cleared anything.
    useEffect(lambda {
        iv: any = None;
        if active {
            refreshEvals();
            iv = setInterval(lambda { refreshEvals(); }, 2000);
        }
        return lambda { if iv is not None { clearInterval(float(str(iv))); } };
    }, [active]);

    # Unmount-only: kill any in-flight chat stream (reads the ref, so it actually sees it).
    useEffect(lambda { return lambda { _cancelReader(); }; }, []);

    # -------------------------------------------------------------- eval ------
    async def loadRows(eid: str, off: int) -> None {
        try {
            res = await eval_rows(_pid(), eid, off, 20);
            rows = list(res["rows"]);
            rowsTotal = int(str(res["total"]));
            rowsOffset = off;
            expanded = -1;
        } except Exception {}
    }

    async def selectEval(eid: str) -> None {
        selEid = eid;
        selData = None;
        await refreshEvals();
        await loadRows(eid, 0);
    }

    async def startEvalNow -> None {
        startBusy = True;
        startErr = "";
        startNote = "";
        res: any = None;
        try {
            res = await start_eval(_pid(), evalRunRid, metric, _toInt(limitStr));
        } except Exception {
            startErr = "start failed";
            startBusy = False;
            return;
        }
        if res and res["ok"] {
            startNote = _g(res, "note", "");
            selEid = str(res["eid"]);
            selData = res["run"];
            await refreshEvals();
            if onRefresh is not None { await onRefresh(); }
        } else {
            startErr = _g(res, "error", "start failed");
        }
        startBusy = False;
    }

    async def stopEvalNow(eid: str) -> None {
        try { await stop_eval_run(_pid(), eid); } except Exception {}
        await refreshEvals();
    }

    def toggleRow(idx: int) -> None {
        expanded = -1 if expanded == idx else idx;
    }

    def _elapsed(e: any) -> str {
        try {
            t0 = Date.parse(_g(e, "started", ""));
            fin = _g(e, "finished", "");
            t1 = Date.parse(fin) if fin else Date.now();
            s = int((t1 - t0) / 1000);
            if s < 0 { s = 0; }
            return str(s // 60) + "m" + str(s % 60) + "s";
        } except Exception {
            return "";
        }
    }

    # -------------------------------------------------------------- chat ------
    async def sendChat(text: str) -> None {
        prompt = text.strip();
        if not prompt or chatStreaming or not chatRunRid { return; }
        chatDraft = "";
        chatStreaming = True;
        chatStopReq = False;
        work: list = [];
        for mm in chatMessages { work.append(mm); }
        work.append({"role": "user", "content": prompt, "streaming": False, "error": ""});
        hist: list = [];
        for mm in work {
            if not mm["error"] { hist.append({"role": str(mm["role"]), "content": str(mm["content"])}); }
        }
        work.append({"role": "assistant", "content": "", "streaming": True, "error": ""});
        ai = len(work) - 1;
        chatMessages = list(work);
        acc = "";
        errtext = "";
        try {
            hdrs: dict = bearerHeaders();
            body: str = JSON.stringify({
                "pid": _pid(), "rid": chatRunRid, "messages": hist,
                "temperature": chatTemp, "top_p": 0.9, "max_tokens": 1024
            });
            resp: any = await fetch("/function/jms_chat_stream", {"method": "POST", "headers": hdrs, "body": body});
            if int(str(resp.status)) == 401 {
                restored: bool = await handleUnauthorized();
                if restored {
                    hdrs = bearerHeaders();
                    resp = await fetch("/function/jms_chat_stream", {"method": "POST", "headers": hdrs, "body": body});
                }
            }
            if int(str(resp.status)) == 401 {
                errtext = "session expired — sign in again";
                work[ai] = {"role": "assistant", "content": acc, "streaming": False, "error": errtext};
                chatMessages = list(work);
                chatStreaming = False;
                return;
            }
            reader: any = resp.body.getReader();
            chatReaderRef.current = reader;
            dec: any = new(TextDecoder);
            nl = String.fromCharCode(10);
            sep = nl + nl;
            buf = "";
            streamEnded = False;
            while True {
                chunk: any = await reader.read();
                if chunk.done { break; }
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
                                work[ai] = {"role": "assistant", "content": acc, "streaming": True, "error": ""};
                                chatMessages = list(work);
                            } elif msg.kind == "error" {
                                errtext = str(msg.text);
                            }
                        } except Exception {}
                    }
                    i += 1;
                }
                if streamEnded {
                    try { await reader.cancel(); } except Exception {}
                    break;
                }
            }
        } except Exception {
            errtext = "stream failed";
        }
        chatReaderRef.current = None;
        work[ai] = {"role": "assistant", "content": acc, "streaming": False, "error": errtext};
        chatMessages = list(work);
        chatStreaming = False;
    }

    async def stopChat -> None {
        chatStopReq = True;
        r: any = chatReaderRef.current;
        if r {
            try { await r.cancel(); } except Exception {}
        }
    }

    def clearChat -> None {
        chatMessages = [];
        chatDraft = "";
    }

    # --------------------------------------------------------------- render ---
    # Run pickers are inlined (not a param'd JsxElement helper) — a positional
    # call of a param'd JsxElement def is the documented client-compile gotcha.
    def _evalConfig -> JsxElement {
        cr = _completedRuns();
        canStart = len(cr) > 0 and evalRunRid != "" and not startBusy and not _anyRunningEval();
        return <div className="jms-section flex flex-col gap-3">
            <span className="jms-section-label">SCORE A RUN ON ITS HOLDOUT</span>
            <div className="flex flex-col gap-1.5">
                <span className="jms-label">COMPLETED RUN</span>
                {len(cr) == 0 and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>No completed local-mlx run with an adapter yet — train one in the TRAIN stage.</span>}
                {len(cr) > 0 and <select
                    className="jms-input" style={{"width": "auto", "minWidth": "260px"}}
                    aria-label="completed run to evaluate"
                    value={evalRunRid}
                    onChange={lambda e: any { evalRunRid = str(e.target.value); }}
                >
                    {for r in cr {
                        <option key={_g(r, "rid", "")} value={_g(r, "rid", "")}>{_g(r, "rid", "")} · {_g(r, "base_model", "")}</option>
                    }}
                </select>}
                {_anySpheron() and <span className="jms-mono-dim">spheron runs aren't chattable/evaluable here — their base weights aren't local</span>}
            </div>
            <div className="flex flex-wrap items-end gap-3">
                <div className="flex flex-col gap-1.5">
                    <span className="jms-label">METRIC</span>
                    <div className="flex items-center gap-1">
                        <button
                            className={"jms-btn" + (" jms-btn-accent" if metric == "judge" else "")}
                            disabled={not keyConfigured}
                            onClick={lambda e: MouseEvent { metric = "judge"; }}
                        >JUDGE</button>
                        <button
                            className={"jms-btn" + (" jms-btn-accent" if metric == "similarity" else "")}
                            onClick={lambda e: MouseEvent { metric = "similarity"; }}
                        >SIMILARITY</button>
                    </div>
                </div>
                <div className="flex flex-col gap-1.5">
                    <span className="jms-label">ROW LIMIT (0 = all)</span>
                    <input className="jms-input" style={{"width": "110px"}} type="number"
                        aria-label="row limit (0 = all)"
                        value={limitStr} onChange={lambda e: any { limitStr = str(e.target.value); }} />
                </div>
                <button
                    className="jms-btn jms-btn-accent"
                    disabled={not canStart}
                    onClick={lambda e: MouseEvent { startEvalNow(); }}
                >{"SCORING…" if startBusy else "SCORE ON HOLDOUT"}</button>
            </div>
            {not keyConfigured and <span className="jms-mono-dim">judge needs an Anthropic key (⚙ KEYS, top bar) — similarity runs offline</span>}
            {_anyRunningEval() and <span className="jms-mono-dim">an eval is running — SCORE unlocks when it finishes</span>}
            {startNote and <span className="jms-mono-dim" style={{"color": "var(--jms-accent)"}}>{startNote}</span>}
            {startErr and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{startErr}</span>}
        </div>;
    }

    def _evalsList -> JsxElement {
        if len(evals) == 0 { return <></>; }
        return <div className="jms-section flex flex-col gap-2">
            <span className="jms-section-label">EVALUATIONS</span>
            {for e in evals {
                <div key={_g(e, "eid", "")} className="flex items-center gap-2">
                    <button
                        className={"jms-pill flex-1" + (" jms-pill-active" if selEid == _g(e, "eid", "") else "")}
                        onClick={lambda ev: MouseEvent { selectEval(_g(e, "eid", "")); }}
                    >
                        <span className={"jms-pill-dot" + (" jms-pill-dot-done" if _g(e, "status", "") == "completed" else "")} />
                        <span>
                            {_g(e, "eid", "")} · run {_g(e, "run_rid", "")} · <span className="jms-chip">{_g(e, "metric", "")}</span> ·
                            {" "}{_g(e, "status", "")} · n={_g(e, "n", "0")} · μ {_r2(_g(e, "mean_score", "0"))}/5 ·
                            {" "}pass {_pct(_g(e, "pass_rate", "0"))} · {_elapsed(e)}
                        </span>
                    </button>
                    {_g(e, "status", "") == "running" and <button
                        className="jms-btn jms-btn-danger"
                        onClick={lambda ev: MouseEvent { stopEvalNow(_g(e, "eid", "")); }}
                    >STOP</button>}
                </div>
            }}
        </div>;
    }

    def _evalDetail -> JsxElement {
        if not selEid or selData is None { return <></>; }
        d = selData;
        canPrev = rowsOffset > 0;
        canNext = rowsOffset + len(rows) < rowsTotal;
        return <div className="jms-section flex flex-col gap-3">
            <span className="jms-section-label">EVAL {selEid} · {_g(d, "status", "")} · {_g(d, "metric", "")}</span>
            {_g(d, "error", "") and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{_g(d, "error", "")}</span>}
            <div className="grid grid-cols-3 gap-2">
                <StatTile label="MEAN SCORE" value={_r2(_g(d, "mean_score", "0")) + " /5"} sub="1-5 scale" dim={False} />
                <StatTile label="PASS RATE" value={_pct(_g(d, "pass_rate", "0"))} sub={"score >= 4"} dim={False} />
                <StatTile label="ROWS" value={_g(d, "n", "0")} sub="holdout scored" dim={False} />
            </div>
            {len(rows) > 0 and <div className="flex flex-col gap-2">
                <span className="jms-label">ROWS</span>
                {for row in rows {
                    <div key={_g(row, "idx", "")} className="flex flex-col gap-1 rounded border border-border p-2">
                        <button
                            className="flex cursor-pointer items-center gap-2 text-left"
                            style={{"background": "transparent", "border": "none", "padding": "0", "width": "100%"}}
                            aria-expanded={expanded == _toInt(_g(row, "idx", "0"))}
                            aria-label={"toggle eval row " + _g(row, "idx", "")}
                            onClick={lambda e: MouseEvent { toggleRow(_toInt(_g(row, "idx", "0"))); }}
                        >
                            <span className="jms-chip">#{_g(row, "idx", "")}</span>
                            <span className="jms-chip" style={{"color": "var(--jms-accent)"}}>score {_g(row, "score", "0")}/5</span>
                            <span className="jms-mono-dim truncate flex-1">{_g(row, "prompt_excerpt", "")}</span>
                        </button>
                        {expanded == _toInt(_g(row, "idx", "0")) and <div className="flex flex-col gap-2">
                            {_g(row, "rationale", "") and <div className="jms-mono-dim" style={{"fontSize": "11px"}}>▸ {_g(row, "rationale", "")}</div>}
                            <div className="flex flex-col gap-1">
                                <span className="jms-label">PROMPT</span>
                                <pre className="jms-mono-dim" style={{"whiteSpace": "pre-wrap", "fontSize": "11px", "margin": "0"}}>{_g(row, "prompt_excerpt", "")}</pre>
                            </div>
                            <div className="flex flex-col gap-1">
                                <span className="jms-label" style={{"color": "var(--jms-ok)"}}>REFERENCE</span>
                                <pre className="jms-mono-dim" style={{"whiteSpace": "pre-wrap", "maxHeight": "200px", "overflow": "auto", "fontSize": "11px", "margin": "0"}}>{_g(row, "reference", "")}</pre>
                            </div>
                            <div className="flex flex-col gap-1">
                                <span className="jms-label" style={{"color": "var(--jms-accent)"}}>GENERATED</span>
                                <pre className="jms-mono-dim" style={{"whiteSpace": "pre-wrap", "maxHeight": "200px", "overflow": "auto", "fontSize": "11px", "margin": "0"}}>{_g(row, "generated", "")}</pre>
                            </div>
                        </div>}
                    </div>
                }}
                {rowsTotal > 0 and <div className="flex items-center justify-center gap-3 jms-mono-dim">
                    <button disabled={not canPrev} onClick={lambda e: MouseEvent { loadRows(selEid, rowsOffset - 20); }} style={{"opacity": ("0.3" if not canPrev else "1")}}>← PREV</button>
                    <span>{str(rowsOffset + 1)} to {str(rowsOffset + len(rows))} of {str(rowsTotal)}</span>
                    <button disabled={not canNext} onClick={lambda e: MouseEvent { loadRows(selEid, rowsOffset + 20); }} style={{"opacity": ("0.3" if not canNext else "1")}}>NEXT →</button>
                </div>}
            </div>}
        </div>;
    }

    # ---------------------------------------------------------------- chat UI -
    def _chatPanel -> JsxElement {
        cr = _completedRuns();
        canSend = chatRunRid != "" and not chatStreaming;
        return <div className="jms-section flex flex-col gap-3" style={{"minHeight": "420px"}}>
            <span className="jms-section-label">CHAT WITH A TRAINED ADAPTER</span>
            <div className="flex flex-wrap items-end gap-3">
                <div className="flex flex-col gap-1.5">
                    <span className="jms-label">COMPLETED RUN</span>
                    {len(cr) == 0 and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>No completed local-mlx run yet.</span>}
                    {len(cr) > 0 and <select
                        className="jms-input" style={{"width": "auto", "minWidth": "260px"}}
                        aria-label="completed run to chat with"
                        value={chatRunRid}
                        onChange={lambda e: any { chatRunRid = str(e.target.value); clearChat(); }}
                    >
                        {for r in cr {
                            <option key={_g(r, "rid", "")} value={_g(r, "rid", "")}>{_g(r, "rid", "")} · {_g(r, "base_model", "")}</option>
                        }}
                    </select>}
                </div>
                <div className="flex flex-col gap-1.5">
                    <span className="jms-label">TEMPERATURE {_r2(chatTemp)}</span>
                    <input type="range" min="0" max="1" step="0.05"
                        aria-label="temperature"
                        value={str(chatTemp)}
                        onChange={lambda e: any { chatTemp = float(str(e.target.value)); }}
                        style={{"width": "160px"}} />
                </div>
                {len(chatMessages) > 0 and <button className="jms-btn" onClick={lambda e: MouseEvent { clearChat(); }}>CLEAR</button>}
            </div>
            <div className="flex flex-col gap-2 overflow-y-auto" style={{"maxHeight": "300px", "minHeight": "120px"}}>
                {len(chatMessages) == 0 and <span className="jms-mono-dim">no messages yet — say hello to your adapter</span>}
                {for (mi, m) in enumerate(chatMessages) {
                    <div key={str(mi)} className={"flex " + ("justify-end" if str(m["role"]) == "user" else "justify-start")}>
                        <div
                            className={"max-w-[85%] whitespace-pre-wrap rounded-lg px-3 py-2 " + ("jms-chip" if str(m["role"]) == "user" else "jms-mono-dim")}
                            style={{"fontSize": "12px", "border": "1px solid var(--jms-border)"}}
                        >
                            {str(m["content"])}
                            {bool(m["streaming"]) and (not str(m["content"])) and <span className="jms-mono-dim">…</span>}
                            {bool(m["error"]) and <span style={{"color": "var(--jms-danger)"}}>{" "}{str(m["error"])}</span>}
                        </div>
                    </div>
                }}
            </div>
            <div className="flex items-end gap-2">
                <textarea
                    className="jms-textarea flex-1"
                    aria-label="chat message"
                    value={chatDraft}
                    placeholder="Ask the adapter…"
                    onChange={lambda e: any { chatDraft = str(e.target.value); }}
                    onKeyDown={lambda e: KeyboardEvent {
                        if e.key == "Enter" and not e.shiftKey {
                            e.preventDefault();
                            sendChat(chatDraft);
                        }
                    }}
                />
                {chatStreaming and <button className="jms-btn jms-btn-danger" onClick={lambda e: MouseEvent { stopChat(); }}>■ STOP</button>}
                {not chatStreaming and <button className="jms-btn jms-btn-accent" disabled={not canSend} onClick={lambda e: MouseEvent { sendChat(chatDraft); }}>⏎ SEND</button>}
            </div>
            {len(cr) == 0 and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>Train a local-mlx adapter first (TRAIN stage) to chat with it.</span>}
        </div>;
    }

    return <div className="flex flex-col gap-5">
        <div className="flex items-center gap-1">
            <button
                className={"jms-btn" + (" jms-btn-accent" if subtab == "eval" else "")}
                onClick={lambda e: MouseEvent { subtab = "eval"; }}
            >EVAL</button>
            <button
                className={"jms-btn" + (" jms-btn-accent" if subtab == "chat" else "")}
                onClick={lambda e: MouseEvent { subtab = "chat"; }}
            >CHAT</button>
        </div>

        {subtab == "eval" and <div className="flex flex-col gap-5">
            {_evalConfig()}
            {_evalsList()}
            {_evalDetail()}
        </div>}

        {subtab == "chat" and <div className="flex flex-col gap-5">
            {_chatPanel()}
        </div>}
    </div>;
}
