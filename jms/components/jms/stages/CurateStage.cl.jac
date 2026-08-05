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

KEYBOARD REVIEW (this is the stage a user spends hours in, so it is driveable
without the mouse): j/↓ and k/↑ move a cursor down/up the page, ↵ expands, a
accepts, r rejects, e opens the inline editor, u undoes. The keydown
listener is registered in a useEffect (NOT `can with exit` — that cleanup would
capture first-render state) and every handler bails when the event target is an
input/textarea/select/contentEditable or carries a Meta/Ctrl/Alt modifier, so
typing in the edit textarea or the holdout field is never hijacked.

# ponytail: the cursor is a plain int index into the current page, not a row id.
# Ceiling — it does not survive a page turn or a filter change (both reset it to
# 0), and if a decision shortens `rows` under it, it clamps to the last row rather
# than tracking "the row I was on". Correct for the actual workflow (review a page
# top-to-bottom, turn the page) and it costs no id-to-index lookup per keystroke.

UNDO (`u`) is just another decision on that same append-only overlay: it appends
action `reset`, which is the one action jms_curate._status_of does not recognise,
so the row falls through to "pending" — exactly what undo means here. It takes the
identical doDecide path as a/r, so the stat tiles, the progress bar and the stage
rail all refresh the same way. An already-pending row is skipped client-side
rather than round-tripped: the server would accept it happily, but a request that
provably changes nothing should not be sent, and the UI should not flicker as if
something happened.

`project` is the get_project() dict (pid + provider/model + gen_jobs); `onRefresh`
re-pulls it after a mutation so the stage rail's curate dot updates. Handlers are
named pick.../do.../build.../move... — never set<HasVar>."""

import from react { useEffect }
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
        confirmMat: bool = False,
        cursor: int = 0;

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
        cursor = 0;
        loadPage();
    }

    def prevPage -> None {
        if page > 0 {
            page = page - 1;
            expandedId = "";
            editingId = "";
            cursor = 0;
            loadPage();
        }
    }

    def nextPage -> None {
        if (page + 1) * PAGE_SIZE < total {
            page = page + 1;
            expandedId = "";
            editingId = "";
            cursor = 0;
            loadPage();
        }
    }

    """Clamp *i* into the current page and scroll that card into view. The target
    index is passed in rather than read back off `cursor` — a state write is async,
    so reading `cursor` on the next line would still be the OLD row."""
    def moveCursor(i: int) -> None {
        n = len(rows);
        if n == 0 { return; }
        ni = i;
        if ni < 0 { ni = 0; }
        if ni > n - 1 { ni = n - 1; }
        cursor = ni;
        doc: any = document;
        el: any = doc.getElementById("curate-row-" + str(ni));
        if el { el.scrollIntoView({"block": "nearest"}); }
    }

    """`cursor` clamped to what is actually on the page right now (a decision under
    the PENDING filter shortens `rows` out from under it)."""
    def _cur -> int {
        n = len(rows);
        if n == 0 { return 0; }
        if cursor > n - 1 { return n - 1; }
        if cursor < 0 { return 0; }
        return cursor;
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
            # dict(m) compiles to Object.fromEntries(m) and a client dict literal is a
            # plain JS object (not iterable) → TypeError. Spread is the working copy form.
            nr = {**m};
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

    """Rows that would actually land in a split: accepted + edited. `edited` counts
    because materialize treats it as accepted-with-edit."""
    def _curatedCount -> int {
        return _toInt(_g(stats, "accepted", "0")) + _toInt(_g(stats, "edited", "0"));
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
        # Same shape as SourcesStage.addSrc's "path required": refuse client-side
        # so a build that can only produce an empty split never leaves the browser.
        # jms_curate.materialize refuses it server-side too — this is the no-wasted-
        # call half.
        if _curatedCount() == 0 {
            err = "no curated rows to split — accept or edit some rows first";
            matResult = None;
            confirmMat = False;
            return;
        }
        trainExists = _toInt(_g(stats, "train_rows", "0")) > 0;
        if trainExists and not confirmMat {
            confirmMat = True;
            return;
        }
        matBusy = True;
        err = "";
        res: any = None;
        try { res = await materialize(_pid(), _toInt(holdoutStr)); } except Exception { err = "build failed"; matBusy = False; return; }
        # Clear the previous run's "train N · holdout M" line: leaving it up next to
        # a refusal reads as if the build half-succeeded.
        if res and "error" in res {
            err = str(res["error"]);
            matResult = None;
            matBusy = False;
            confirmMat = False;
            return;
        }
        matResult = res;
        confirmMat = False;
        await loadPage();
        if onRefresh is not None { await onRefresh(); }
        matBusy = False;
    }

    # ------------------------------------------------------------- keyboard ----
    # Document-level keydown. Deliberately a useEffect and not `can with exit`:
    # that compiles to useEffect(..., []) and its cleanup would close over the
    # FIRST render's handler, so the listener could never be removed. The handler
    # ref is effect-LOCAL and the cleanup removes the exact same one it added.
    # Deps re-register it whenever the data it reads changes (a stale closure here
    # would accept the wrong row).
    useEffect(lambda {
        doc: any = document;
        onKey = lambda e: any {
            tgt: any = e.target;
            tag = str(tgt.tagName or "").lower() if tgt else "";
            # Never hijack a key the user is typing into a control.
            if tag == "input" or tag == "textarea" or tag == "select" { return; }
            if tgt and tgt.isContentEditable { return; }
            if e.metaKey or e.ctrlKey or e.altKey { return; }
            n = len(rows);
            if n == 0 { return; }
            k = str(e.key);
            cur = _cur();
            if k == "j" or k == "ArrowDown" { e.preventDefault(); moveCursor(cur + 1); return; }
            if k == "k" or k == "ArrowUp" { e.preventDefault(); moveCursor(cur - 1); return; }
            # An open editor owns the page: every remaining key (expand, accept,
            # reject, re-edit) would throw away unsaved textarea content. j/k above
            # still move, so the list stays navigable; CANCEL/SAVE releases the rest.
            if editingId { return; }
            row = rows[cur];
            rid = str(row["_id"]);
            # Enter is how a focused <button>/<a> is activated. Swallowing it there
            # would break keyboard operation of every control on the page, so the
            # expand shortcut yields when a real control has focus.
            if k == "Enter" {
                if tag == "button" or tag == "a" { return; }
                e.preventDefault();
                toggleExpand(rid);
                return;
            }
            if k == "a" { e.preventDefault(); doDecide(rid, "accept"); return; }
            if k == "r" { e.preventDefault(); doDecide(rid, "reject"); return; }
            if k == "e" { e.preventDefault(); expandedId = rid; startEdit(row); return; }
            if k == "u" {
                # Nothing to undo on a row that carries no decision — skip the call
                # instead of round-tripping a no-op and re-rendering the page.
                if str(row["status"]) == "pending" { return; }
                e.preventDefault();
                doDecide(rid, "reset");
                return;
            }
        };
        doc.addEventListener("keydown", onKey);
        return lambda { doc.removeEventListener("keydown", onKey); };
    }, [rows, cursor, editingId]);

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

    """"N of M reviewed" + a flat bar. Reviewed = accepted+rejected+edited, i.e.
    every row carrying a decision; the numbers come straight from curate_stats."""
    def _progress -> JsxElement {
        tot = _toInt(_g(stats, "total", "0"));
        done = _toInt(_g(stats, "accepted", "0")) + _toInt(_g(stats, "rejected", "0")) + _toInt(_g(stats, "edited", "0"));
        pct = (done * 100) // tot if tot > 0 else 0;
        if pct > 100 { pct = 100; }
        return <div className="flex flex-col gap-1.5">
            <div className="flex flex-wrap items-baseline justify-between gap-2">
                <span className="jms-label">REVIEW PROGRESS</span>
                <span className="jms-mono-dim">
                    {str(done)} of {str(tot)} reviewed · {str(pct)}%{" · " + _g(stats, "pending", "0") + " left" if tot > 0 else ""}
                </span>
            </div>
            <div
                role="progressbar"
                aria-label="rows reviewed"
                aria-valuenow={pct}
                aria-valuemin={0}
                aria-valuemax={100}
                style={{"height": "3px", "width": "100%", "background": "var(--jms-border)", "overflow": "hidden"}}
            >
                <div style={{"height": "100%", "width": str(pct) + "%", "background": "var(--jms-accent)"}} />
            </div>
        </div>;
    }

    """Compact keybinding legend. Only rendered when there are rows to drive."""
    def _keyHint -> JsxElement {
        return <div className="flex flex-wrap items-center gap-x-3 gap-y-1 jms-mono-dim">
            <span><span className="jms-kbd">j</span>/<span className="jms-kbd">k</span> move</span>
            <span><span className="jms-kbd">a</span> accept</span>
            <span><span className="jms-kbd">r</span> reject</span>
            <span><span className="jms-kbd">e</span> edit</span>
            <span><span className="jms-kbd">u</span> undo</span>
            <span><span className="jms-kbd">↵</span> expand</span>
            <span className="opacity-70">keys pause while you type</span>
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
        # Disabled-reason surfacing, the same shape as BUILD TRAINING SPLIT
        # below: the reason is the button's `title` (hover), and where a visible
        # span already states it, `aria-describedby` ties the two together for
        # screen readers. `else None` keeps the attribute off the DOM when there
        # is nothing to point at (React drops null props).
        acceptHint = "No pending rows on this page — nothing left to accept here." if nPending == 0 else "";
        regenHint = "";
        regenHintId = "";
        if regenBusy {
            regenHint = "Queuing a regeneration job…";
        } elif nRej == 0 {
            regenHint = "No rejected rows — reject a row first to regenerate it.";
        } elif running {
            regenHint = "a gen job is running — regenerate unlocks when it finishes";
            regenHintId = "jms-curate-regen-hint";
        }
        return <div className="flex flex-wrap items-center gap-2">
            <button
                className="jms-btn"
                disabled={nPending == 0}
                title={acceptHint if acceptHint else "accept every pending row on this page"}
                onClick={lambda e: MouseEvent { acceptAllOnPage(); }}
            >ACCEPT ALL ON PAGE{" (" + str(nPending) + ")" if nPending > 0 else ""}</button>
            <button
                className="jms-btn"
                disabled={nRej == 0 or running or regenBusy}
                title={regenHint if regenHint else "re-synthesize the rejected rows"}
                aria-describedby={regenHintId if regenHintId else None}
                onClick={lambda e: MouseEvent { regenRejected(); }}
            >{"REGENERATING…" if regenBusy else "REGENERATE REJECTED (" + str(nRej) + ")"}</button>
            {running and <span id="jms-curate-regen-hint" className="jms-mono-dim">a gen job is running — regenerate unlocks when it finishes</span>}
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
                        aria-label={"edit " + str(editMsgs[i]["role"]) + " message"}
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

    def _rowCard(row: any, i: int = 0) -> JsxElement {
        rid = str(row["_id"]);
        st = str(row["status"]);
        msgs = list(row["messages"]) if "messages" in row else [];
        chunks = list(row["chunks"]) if "chunks" in row else [];
        open_ = expandedId == rid;
        editing = editingId == rid;
        # Keyboard cursor: an inset accent rule, not a border swap — .jms-section
        # already owns its border and changing it would shift the card by a pixel.
        onCursor = i == _cur();
        return <div
            key={rid}
            id={"curate-row-" + str(i)}
            className="jms-section flex flex-col gap-3"
            style={{"boxShadow": "inset 2px 0 0 var(--jms-accent)"} if onCursor else {}}
        >
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
        # Disabled-with-the-reason-stated, the same guard shape GenerateStage uses
        # for DRAFT PLAN (canDraft + hint): with nothing accepted or edited there is
        # no split to build, so say so instead of shipping a `train 0 · holdout 0`.
        nCur = _curatedCount();
        nPend = _toInt(_g(stats, "pending", "0"));
        matHint = "";
        # `stats` is None until the first load lands — do not flash "nothing to
        # split" at a user whose counts simply have not arrived yet.
        if nCur == 0 and not loading {
            if _toInt(_g(stats, "total", "0")) == 0 {
                matHint = "Nothing to split — generate some rows in the GENERATE tab first.";
            } elif nPend > 0 {
                matHint = "Nothing curated yet — accept or edit some of the " + str(nPend) + " pending rows first.";
            } else {
                matHint = "Every row is rejected — accept or edit at least one row to build a split.";
            }
        }
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
                        aria-label="holdout percent"
                        value={holdoutStr}
                        onChange={lambda e: any { holdoutStr = str(e.target.value); confirmMat = False; }}
                    />
                </div>
                <button
                    className="jms-btn jms-btn-accent"
                    disabled={bool(matBusy or loading or nCur == 0)}
                    title={matHint if matHint else "carve the accepted + edited rows into train.jsonl / holdout.jsonl"}
                    aria-describedby={"jms-curate-split-hint" if matHint else None}
                    onClick={lambda e: MouseEvent { buildSplit(); }}
                >{matLabel}</button>
                {matResult and <span className="jms-mono-dim" style={{"color": "var(--jms-ok)"}}>
                    train {_g(matResult, "train_rows", "0")} · holdout {_g(matResult, "holdout_rows", "0")}
                </span>}
            </div>
            {matHint and <span id="jms-curate-split-hint" className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{matHint}</span>}
            {confirmMat and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>a split already exists — click again to overwrite train.jsonl + holdout.jsonl</span>}
        </div>;
    }

    return <div className="flex flex-col gap-5">
        {_tiles()}
        {_progress()}
        {_chips()}
        {_bulkBar()}
        {err and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{err}</span>}

        {loading and <span className="jms-label">LOADING…</span>}
        {not loading and total == 0 and <div className="jms-section flex items-center justify-center" style={{"minHeight": "160px"}}>
            <span className="jms-mono-dim">
                {"no generated rows yet — synthesize some in the GENERATE tab" if activeFilter == "all" else "no rows match this filter"}
            </span>
        </div>}

        {not loading and total > 0 and _keyHint()}

        {not loading and total > 0 and <div className="flex flex-col gap-3">
            {[_rowCard({"row": rows[ri], "i": ri}) for ri in range(len(rows))]}
        </div>}

        {not loading and total > 0 and _pager()}
        {_footer()}
    </div>;
}
