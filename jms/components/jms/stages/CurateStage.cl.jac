"""CurateStage — the CURATE stage panel of a JMS project.

Reviews the generator's raw.jsonl rows one page at a time and records an
accept / reject / edit decision on each (server-side file overlay), then carves
the accepted+edited rows into a deterministic train/holdout split.

Header: stat tiles (GENERATED / PENDING / ACCEPTED / REJECTED / EDITED / ACC %,
plus TRAIN / HOLDOUT once a split is built). Filter chips scope the list to one
status. Each row is a status dot + _type chip + first-user-message excerpt with
an expand toggle; expanded shows the full role-labeled transcript, its chunk
provenance, and ✓ ACCEPT / ✗ REJECT / EDIT actions (EDIT swaps in a per-message
textarea → SAVE / CANCEL). A bulk bar accepts every pending row on the page and
fires a REGENERATE-REJECTED gen job (jms_gen.start_gen with regen_of); the footer
builds the split via materialize (two-click confirm when a split already exists).

`project` is the get_project() dict (pid + provider/model + gen_jobs); `onRefresh`
re-pulls it after a mutation so the stage rail's curate dot updates. Handlers are
named pick.../do.../build... — never set<HasVar>."""

sv import from ....jms_curate { curate_stats, curate_rows, decide_row, decide_page, rejected_ids, materialize }
sv import from ....jms_gen { start_gen }

glob FILTERS: list[dict] = [
    {"id": "all", "label": "ALL"},
    {"id": "pending", "label": "PENDING"},
    {"id": "accepted", "label": "ACCEPTED"},
    {"id": "rejected", "label": "REJECTED"},
    {"id": "edited", "label": "EDITED"}
];
glob PAGE_SIZE: int = 20;

def _g(d: any, k: str, fallback: str) -> str {
    if d and k in d { return str(d[k]); }
    return fallback;
}

def _toInt(s: str) -> int {
    try { return int(float(str(s).strip())); } except Exception { return 0; }
}

def:pub CurateStage(project: any = None, onRefresh: any = None) -> JsxElement {
    has stats: any = None,
        rows: list = [],
        total: int = 0,
        activeFilter: str = "all",
        page: int = 0,
        loading: bool = True,
        err: str = "",
        expandedId: str = "",
        editingId: str = "",
        editMsgs: list = [],
        regenBusy: bool = False,
        regenJid: str = "",
        matBusy: bool = False,
        matResult: any = None,
        holdoutStr: str = "10",
        confirmMat: bool = False;

    def _pid -> str {
        if project { return str(project["pid"]); }
        return "";
    }

    async def loadPage -> None {
        err = "";
        try {
            st = await curate_stats(_pid());
            stats = st;
            rr = await curate_rows(_pid(), page * PAGE_SIZE, PAGE_SIZE, activeFilter);
            rows = list(rr["rows"]);
            total = _toInt(_g(rr, "total", "0"));
        } except Exception {
            err = "load failed";
        }
        loading = False;
    }

    async can with entry {
        await loadPage();
    }

    def pickFilter(f: str) -> None {
        activeFilter = f;
        page = 0;
        expandedId = "";
        editingId = "";
        loadPage();
    }

    def prevPage -> None {
        if page > 0 {
            page = page - 1;
            expandedId = "";
            editingId = "";
            loadPage();
        }
    }

    def nextPage -> None {
        if (page + 1) * PAGE_SIZE < total {
            page = page + 1;
            expandedId = "";
            editingId = "";
            loadPage();
        }
    }

    def toggleExpand(rid: str) -> None {
        expandedId = "" if expandedId == rid else rid;
        editingId = "";
    }

    async def doDecide(rid: str, action: str) -> None {
        res: any = None;
        try { res = await decide_row(_pid(), rid, action); } except Exception { err = "action failed"; return; }
        if res and "error" in res { err = str(res["error"]); return; }
        await loadPage();
        if onRefresh is not None { await onRefresh(); }
    }

    def startEdit(row: any) -> None {
        editingId = str(row["_id"]);
        em: list = [];
        for m in list(row["messages"]) {
            em.append({"role": str(m["role"]), "content": str(m["content"])});
        }
        editMsgs = em;
    }

    def patchEditMsg(i: int, val: str) -> None {
        nm: list = [];
        idx = 0;
        for m in editMsgs {
            nr = dict(m);
            if idx == i { nr["content"] = val; }
            nm.append(nr);
            idx = idx + 1;
        }
        editMsgs = nm;
    }

    def cancelEdit -> None {
        editingId = "";
        editMsgs = [];
    }

    async def saveEdit -> None {
        rid = editingId;
        res: any = None;
        try { res = await decide_row(_pid(), rid, "edit", editMsgs); } except Exception { err = "save failed"; return; }
        if res and "error" in res { err = str(res["error"]); return; }
        editingId = "";
        editMsgs = [];
        await loadPage();
        if onRefresh is not None { await onRefresh(); }
    }

    def _pendingOnPage -> list {
        out: list = [];
        for r in rows {
            if str(r["status"]) == "pending" { out.append(str(r["_id"])); }
        }
        return out;
    }

    async def acceptAllOnPage -> None {
        ids = _pendingOnPage();
        if len(ids) == 0 { return; }
        try { await decide_page(_pid(), ids, "accept"); } except Exception { err = "bulk failed"; return; }
        await loadPage();
        if onRefresh is not None { await onRefresh(); }
    }

    def _genRunning -> bool {
        if project and "gen_jobs" in project {
            for j in list(project["gen_jobs"]) {
                if str(j["status"]) == "running" { return True; }
            }
        }
        return False;
    }

    def _rejectedCount -> int {
        return _toInt(_g(stats, "rejected", "0"));
    }

    async def regenRejected -> None {
        regenBusy = True;
        err = "";
        regenJid = "";
        ids: list = [];
        try { ids = list(await rejected_ids(_pid())); } except Exception { err = "regen failed"; regenBusy = False; return; }
        if len(ids) == 0 { regenBusy = False; return; }
        pv = _g(project, "provider", "claude");
        md = _g(project, "model", "claude-sonnet-5");
        res: any = None;
        try { res = await start_gen(_pid(), pv, md, 0, 0, 8, ids); } except Exception { err = "regen failed"; regenBusy = False; return; }
        if res and res["ok"] {
            regenJid = str(res["jid"]);
            if onRefresh is not None { await onRefresh(); }
        } else {
            err = _g(res, "error", "regen failed");
        }
        regenBusy = False;
    }

    async def buildSplit -> None {
        trainExists = _toInt(_g(stats, "train_rows", "0")) > 0;
        if trainExists and not confirmMat {
            confirmMat = True;
            return;
        }
        matBusy = True;
        err = "";
        res: any = None;
        try { res = await materialize(_pid(), _toInt(holdoutStr)); } except Exception { err = "build failed"; matBusy = False; return; }
        if res and "error" in res { err = str(res["error"]); matBusy = False; confirmMat = False; return; }
        matResult = res;
        confirmMat = False;
        await loadPage();
        if onRefresh is not None { await onRefresh(); }
        matBusy = False;
    }

    # --------------------------------------------------------------- helpers ----
    def _excerpt(row: any) -> str {
        msgs = list(row["messages"]) if row and "messages" in row else [];
        for m in msgs {
            if str(m["role"]) == "user" { return str(m["content"]); }
        }
        if len(msgs) > 0 { return str(msgs[0]["content"]); }
        return "(empty)";
    }

    def _statusColor(st: str) -> str {
        if st == "accepted" { return "var(--jms-ok)"; }
        if st == "rejected" { return "var(--jms-danger)"; }
        if st == "edited" { return "var(--jms-accent-2)"; }
        return "var(--jms-fg-dim)";
    }

    # --------------------------------------------------------------- render ----
    def _tiles -> JsxElement {
        showSplit = _toInt(_g(stats, "train_rows", "0")) > 0 or _toInt(_g(stats, "holdout_rows", "0")) > 0;
        return <div className="flex flex-wrap items-center gap-4">
            <span className="jms-stat">GENERATED {_g(stats, "total", "0")}</span>
            <span className="jms-stat">PENDING {_g(stats, "pending", "0")}</span>
            <span className="jms-stat" style={{"color": "var(--jms-ok)"}}>ACCEPTED {_g(stats, "accepted", "0")}</span>
            <span className="jms-stat" style={{"color": "var(--jms-danger)"}}>REJECTED {_g(stats, "rejected", "0")}</span>
            <span className="jms-stat" style={{"color": "var(--jms-accent-2)"}}>EDITED {_g(stats, "edited", "0")}</span>
            <span className="jms-stat">ACC {_g(stats, "acceptance_pct", "0")}%</span>
            {showSplit and <span className="jms-stat">TRAIN {_g(stats, "train_rows", "0")}</span>}
            {showSplit and <span className="jms-stat">HOLDOUT {_g(stats, "holdout_rows", "0")}</span>}
        </div>;
    }

    def _chips -> JsxElement {
        return <div className="flex flex-wrap items-center gap-1">
            {for f in FILTERS {
                <button
                    key={str(f["id"])}
                    className={"jms-btn" + (" jms-btn-accent" if activeFilter == str(f["id"]) else "")}
                    onClick={lambda e: MouseEvent { pickFilter(str(f["id"])); }}
                >{str(f["label"])}</button>
            }}
        </div>;
    }

    def _bulkBar -> JsxElement {
        nPending = len(_pendingOnPage());
        nRej = _rejectedCount();
        running = _genRunning();
        return <div className="flex flex-wrap items-center gap-2">
            <button
                className="jms-btn"
                disabled={nPending == 0}
                onClick={lambda e: MouseEvent { acceptAllOnPage(); }}
            >ACCEPT ALL ON PAGE{" (" + str(nPending) + ")" if nPending > 0 else ""}</button>
            <button
                className="jms-btn"
                disabled={nRej == 0 or running or regenBusy}
                onClick={lambda e: MouseEvent { regenRejected(); }}
            >{"REGENERATING…" if regenBusy else "REGENERATE REJECTED (" + str(nRej) + ")"}</button>
            {running and <span className="jms-mono-dim">a gen job is running — regenerate unlocks when it finishes</span>}
            {regenJid and <span className="jms-mono-dim" style={{"color": "var(--jms-ok)"}}>regen job {regenJid} started — watch the GENERATE tab</span>}
        </div>;
    }

    def _transcript(msgs: list) -> JsxElement {
        return <div className="flex flex-col gap-2">
            {for i in range(len(msgs)) {
                <div key={str(i)} className="flex flex-col gap-1">
                    <span className="jms-label">{str(msgs[i]["role"])}</span>
                    <pre
                        className="jms-mono"
                        style={{"whiteSpace": "pre-wrap", "margin": "0", "fontSize": "11px", "lineHeight": "1.5"}}
                    >{str(msgs[i]["content"])}</pre>
                </div>
            }}
        </div>;
    }

    def _editor(row: any) -> JsxElement {
        return <div className="flex flex-col gap-3">
            {for i in range(len(editMsgs)) {
                <div key={str(i)} className="flex flex-col gap-1">
                    <span className="jms-label">{str(editMsgs[i]["role"])}</span>
                    <textarea
                        className="jms-textarea"
                        value={str(editMsgs[i]["content"])}
                        onChange={lambda e: any { patchEditMsg(i, str(e.target.value)); }}
                    />
                </div>
            }}
            <div className="flex items-center gap-2">
                <button className="jms-btn jms-btn-accent" onClick={lambda e: MouseEvent { saveEdit(); }}>SAVE</button>
                <button className="jms-btn" onClick={lambda e: MouseEvent { cancelEdit(); }}>CANCEL</button>
            </div>
        </div>;
    }

    def _rowCard(row: any) -> JsxElement {
        rid = str(row["_id"]);
        st = str(row["status"]);
        msgs = list(row["messages"]) if "messages" in row else [];
        chunks = list(row["chunks"]) if "chunks" in row else [];
        open_ = expandedId == rid;
        editing = editingId == rid;
        return <div key={rid} className="jms-section flex flex-col gap-3">
            <button
                className="flex items-center gap-3 text-left"
                style={{"background": "transparent", "border": "none", "cursor": "pointer", "padding": "0"}}
                onClick={lambda e: MouseEvent { toggleExpand(rid); }}
            >
                <span className="jms-pill-dot" style={{"background": _statusColor(st), "borderColor": _statusColor(st)}} />
                <span className="jms-chip">{str(row["_type"])}</span>
                <span
                    className="jms-mono"
                    style={{"whiteSpace": "nowrap", "overflow": "hidden", "textOverflow": "ellipsis", "flex": "1", "minWidth": "0"}}
                >{_excerpt(row)}</span>
                <span className="jms-mono-dim" style={{"flexShrink": "0"}}>{"▲" if open_ else "▼"}</span>
            </button>

            {open_ and <div className="flex flex-col gap-3" style={{"borderTop": "1px solid var(--jms-border)", "paddingTop": "12px"}}>
                {editing and _editor({"row": row})}
                {not editing and _transcript({"msgs": msgs})}
                {not editing and len(chunks) > 0 and <div className="flex flex-wrap items-center gap-2">
                    <span className="jms-label">CHUNKS</span>
                    {for ci in range(len(chunks)) {
                        <span key={str(ci)} className="jms-mono-dim">{str(chunks[ci])}</span>
                    }}
                </div>}
                {not editing and <div className="flex items-center gap-2">
                    <button
                        className={"jms-btn" + (" jms-btn-accent" if st == "accepted" else "")}
                        onClick={lambda e: MouseEvent { doDecide(rid, "accept"); }}
                    >✓ ACCEPT</button>
                    <button
                        className={"jms-btn" + (" jms-btn-danger" if st == "rejected" else "")}
                        onClick={lambda e: MouseEvent { doDecide(rid, "reject"); }}
                    >✗ REJECT</button>
                    <button
                        className="jms-btn"
                        onClick={lambda e: MouseEvent { startEdit(row); }}
                    >EDIT</button>
                </div>}
            </div>}
        </div>;
    }

    def _pager -> JsxElement {
        startN = page * PAGE_SIZE + 1 if total > 0 else 0;
        endN = (page + 1) * PAGE_SIZE if (page + 1) * PAGE_SIZE < total else total;
        canPrev = page > 0;
        canNext = (page + 1) * PAGE_SIZE < total;
        return <div className="flex items-center gap-3">
            <button className="jms-btn" disabled={not canPrev} onClick={lambda e: MouseEvent { prevPage(); }}>PREV</button>
            <span className="jms-mono-dim">{str(startN)}-{str(endN)} of {str(total)}</span>
            <button className="jms-btn" disabled={not canNext} onClick={lambda e: MouseEvent { nextPage(); }}>NEXT</button>
        </div>;
    }

    def _footer -> JsxElement {
        matLabel = "BUILDING…" if matBusy else ("CLICK AGAIN TO OVERWRITE" if confirmMat else "BUILD TRAINING SPLIT");
        return <div className="jms-section flex flex-col gap-3">
            <span className="jms-section-label">TRAINING SPLIT</span>
            <div className="flex flex-wrap items-end gap-3">
                <div className="flex flex-col gap-1.5">
                    <span className="jms-label">HOLDOUT %</span>
                    <input
                        className="jms-input"
                        style={{"width": "90px"}}
                        type="number"
                        value={holdoutStr}
                        onChange={lambda e: any { holdoutStr = str(e.target.value); confirmMat = False; }}
                    />
                </div>
                <button
                    className="jms-btn jms-btn-accent"
                    disabled={matBusy}
                    onClick={lambda e: MouseEvent { buildSplit(); }}
                >{matLabel}</button>
                {matResult and <span className="jms-mono-dim" style={{"color": "var(--jms-ok)"}}>
                    train {_g(matResult, "train_rows", "0")} · holdout {_g(matResult, "holdout_rows", "0")}
                </span>}
            </div>
            {confirmMat and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>a split already exists — click again to overwrite train.jsonl + holdout.jsonl</span>}
        </div>;
    }

    return <div className="flex flex-col gap-5">
        {_tiles()}
        {_chips()}
        {_bulkBar()}
        {err and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{err}</span>}

        {loading and <span className="jms-label">LOADING…</span>}
        {not loading and total == 0 and <div className="jms-section flex items-center justify-center" style={{"minHeight": "160px"}}>
            <span className="jms-mono-dim">
                {"no generated rows yet — synthesize some in the GENERATE tab" if activeFilter == "all" else "no rows match this filter"}
            </span>
        </div>}

        {not loading and total > 0 and <div className="flex flex-col gap-3">
            {[_rowCard({"row": r}) for r in rows]}
        </div>}

        {not loading and total > 0 and _pager()}
        {_footer()}
    </div>;
}
