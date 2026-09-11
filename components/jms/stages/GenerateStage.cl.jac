"""GenerateStage — the GENERATE stage panel of a JMS project.

A PLAN | SYNTHESIZE sub-tab toggle.

PLAN: pick a provider (Claude / local MLX) + model, DRAFT PLAN (blocking ~30-60s,
spinner), then edit the returned plan — description, an example-type MIX table
(type_name / description / share_pct, add/remove rows, live share-sum with a warn
tint when ≠ 100), target rows, system prompt, grounding notes — and SAVE DRAFT /
APPROVE / REDRAFT. Prior versions list on the side; clicking one loads it (drafts
editable, approved read-only).

SYNTHESIZE: config card (provider/model, target rows defaulted from the approved
plan, max-rows hard cap ~1.2×, batch size) → PREVIEW COST → FIRE (enabled only
after a cap_ok preview and while no job runs). FIRE is two-click: the second
click's label spells out the rows and the dollar estimate it is about to spend,
so an expensive job cannot go out on one stray click (same confirm pattern as
CurateStage's split overwrite). Jobs list with a rows_done/target progress bar +
status dot + STOP; selecting a job shows its counters and live log tail.

Every number on this screen comes back from the server (estimate_gen /
list_gen_jobs / gen_status); the only derived values are integer percentages of
two returned counts and the wall-clock elapsed. Nothing is invented — in
particular there is no ETA, because the backend reports no rate.

# ponytail: progress is rows_done/target_rows only. Ceiling — no ETA, no
# rows-per-minute, no cost burn-down, because the server returns neither a rate
# nor a per-batch timeline (only `last_batch_at`, a single timestamp). Deriving a
# rate from rows_done/elapsed would read as a promise the batching cannot keep.
Polls list_gen_jobs/gen_status every 2s ONLY while `active` (this stage is the
visible one) — the interval id is effect-local so the cleanup can actually see it
(Cloud.cl.jac pattern). Any input change invalidates the preview.

`project` is the get_project() dict; `onRefresh` re-pulls it after a mutation.
Handlers are named draft.../save.../fire.../stopJob etc — never set<HasVar>."""

import from react { useEffect }
sv import from ....jms_plan { draft_plan, update_plan, approve_plan }
sv import from ....jms_llm { llm_status }
sv import from ....jms_gen { estimate_gen, start_gen, gen_status, stop_gen, list_gen_jobs }

def _g(d: any, k: str, fallback: str) -> str {
    if d and k in d { return str(d[k]); }
    return fallback;
}

def _toInt(s: str) -> int {
    try { return int(float(s.strip())); } except Exception { return 0; }
}

def:pub GenerateStage(project: any = None, onRefresh: any = None, active: bool = True) -> JsxElement {
    has subtab: str = "plan",
        statusData: any = None,
        provider: str = "claude",
        model: str = "claude-sonnet-5",
        drafting: bool = False,
        draftErr: str = "",
        saveBusy: bool = False,
        desc: str = "",
        mix: list = [],
        targetRowsStr: str = "0",
        sysPrompt: str = "",
        grounding: str = "",
        activeVersion: int = 0,
        activeStatus: str = "",
        readOnly: bool = False,
        loadedInit: bool = False,
        genProvider: str = "claude",
        genModel: str = "claude-sonnet-5",
        targetStr: str = "",
        maxStr: str = "",
        batchStr: str = "8",
        estData: any = None,
        estBusy: bool = False,
        genErr: str = "",
        fireBusy: bool = False,
        fireConfirm: bool = False,
        genJobs: list = [],
        selJid: str = "",
        selData: any = None;

    def _pid -> str {
        if project { return str(project["pid"]); }
        return "";
    }

    def _plans -> list {
        if project and "plans" in project { return list(project["plans"]); }
        return [];
    }

    def _providers -> list {
        if statusData and "providers" in statusData { return list(statusData["providers"]); }
        return [];
    }

    def _modelsFor(pv: str) -> list {
        for p in _providers() {
            if str(p["id"]) == pv { return list(p["models"]); }
        }
        return [];
    }

    def _configured -> bool {
        return bool(statusData and statusData["configured"]);
    }

    def _loadPlan(p: any, ro: bool) -> None {
        desc = _g(p, "description", "");
        rows: list = [];
        if p and "mix" in p {
            for it in list(p["mix"]) {
                rows.append({
                    "type_name": _g(it, "type_name", ""),
                    "description": _g(it, "description", ""),
                    "share_pct": _toInt(_g(it, "share_pct", "0"))
                });
            }
        }
        mix = rows;
        targetRowsStr = _g(p, "target_rows", "0");
        sysPrompt = _g(p, "system_prompt", "");
        grounding = _g(p, "grounding_notes", "");
        activeVersion = _toInt(_g(p, "version", "0"));
        activeStatus = _g(p, "status", "");
        readOnly = ro;
    }

    async def reloadStatus -> None {
        try { statusData = await llm_status(); } except Exception { statusData = None; }
    }

    def _approvedPlan -> any {
        for p in _plans() {
            if _g(p, "status", "") == "approved" { return p; }
        }
        return None;
    }

    async def refreshGen -> None {
        try {
            jl = await list_gen_jobs(_pid());
            genJobs = list(jl);
            if selJid {
                sd = await gen_status(_pid(), selJid);
                selData = sd;
            }
        } except Exception {}
    }

    async can with entry {
        await reloadStatus();
        if not loadedInit {
            pl = _plans();
            if len(pl) > 0 { _loadPlan(pl[0], _g(pl[0], "status", "") != "draft"); }
            ap = _approvedPlan();
            if ap is not None {
                tr = _toInt(_g(ap, "target_rows", "0"));
                if tr > 0 {
                    targetStr = str(tr);
                    maxStr = str(_toInt(str(tr * 1.2)));
                }
            }
            loadedInit = True;
        }
    }

    # Poll only while this stage is the visible one. The id MUST be effect-local:
    # a `can with exit` cleanup captures the `has` var from the first render (still
    # None) and so never clears anything — the leak this replaces.
    useEffect(lambda {
        iv: any = None;
        if active {
            refreshGen();
            iv = setInterval(lambda { refreshGen(); }, 2000);
        }
        return lambda { if iv is not None { clearInterval(float(str(iv))); } };
    }, [active]);

    def pickProvider(pv: str) -> None {
        provider = pv;
        ms = _modelsFor(pv);
        model = str(ms[0]) if len(ms) > 0 else "";
        draftErr = "";
    }

    async def draftNow -> None {
        drafting = True;
        draftErr = "";
        res: any = None;
        try {
            res = await draft_plan(_pid(), provider, model);
        } except Exception {
            draftErr = "draft failed";
            drafting = False;
            return;
        }
        if res and res["ok"] {
            _loadPlan(res["plan"], False);
            if onRefresh is not None { await onRefresh(); }
        } else {
            draftErr = _g(res, "error", "draft failed");
        }
        drafting = False;
    }

    def _planJson -> str {
        rows: list = [];
        for r in mix {
            rows.append({
                "type_name": _g(r, "type_name", ""),
                "description": _g(r, "description", ""),
                "share_pct": _toInt(_g(r, "share_pct", "0"))
            });
        }
        return JSON.stringify({
            "description": desc,
            "schema": "sft-chat",
            "mix": rows,
            "target_rows": _toInt(targetRowsStr),
            "system_prompt": sysPrompt,
            "grounding_notes": grounding
        });
    }

    async def saveDraft -> None {
        if activeVersion == 0 { return; }
        saveBusy = True;
        draftErr = "";
        res: any = None;
        try {
            res = await update_plan(_pid(), activeVersion, _planJson());
        } except Exception {
            draftErr = "save failed";
            saveBusy = False;
            return;
        }
        if res and res["ok"] { _loadPlan(res["plan"], False); }
        else { draftErr = _g(res, "error", "save failed"); }
        saveBusy = False;
        if onRefresh is not None { await onRefresh(); }
    }

    async def approveNow -> None {
        if activeVersion == 0 { return; }
        saveBusy = True;
        draftErr = "";
        res: any = None;
        try {
            res = await approve_plan(_pid(), activeVersion);
        } except Exception {
            draftErr = "approve failed";
            saveBusy = False;
            return;
        }
        if res and res["ok"] { _loadPlan(res["plan"], True); }
        else { draftErr = _g(res, "error", "approve failed"); }
        saveBusy = False;
        if onRefresh is not None { await onRefresh(); }
    }

    def addRow -> None {
        nm: list = [r for r in mix];
        nm.append({"type_name": "", "description": "", "share_pct": 0});
        mix = nm;
    }

    def dropRow(i: int) -> None {
        nm: list = [];
        idx = 0;
        for r in mix {
            if idx != i { nm.append(r); }
            idx = idx + 1;
        }
        mix = nm;
    }

    def patchRow(i: int, field: str, val: str) -> None {
        nm: list = [];
        idx = 0;
        for r in mix {
            # dict(r) compiles to Object.fromEntries(r) and a client dict literal is a
            # plain JS object (not iterable) → TypeError. Spread is the working copy form.
            nr = {**r};
            if idx == i {
                if field == "share_pct" { nr["share_pct"] = _toInt(val); }
                else { nr[field] = val; }
            }
            nm.append(nr);
            idx = idx + 1;
        }
        mix = nm;
    }

    def _shareSum -> int {
        tot = 0;
        for r in mix { tot = tot + _toInt(_g(r, "share_pct", "0")); }
        return tot;
    }

    # ---------------------------------------------------- synthesize handlers ----
    def pickGenProvider(pv: str) -> None {
        genProvider = pv;
        ms = _modelsFor(pv);
        genModel = str(ms[0]) if len(ms) > 0 else "";
        estData = None;
        fireConfirm = False;
        genErr = "";
    }

    # Any config change invalidates the last preview (FIRE re-locks until a new one)
    # AND drops an armed confirm — otherwise the second click would spend on numbers
    # the user has since edited away.
    def patchGenField(field: str, val: str) -> None {
        if field == "target" { targetStr = val; }
        if field == "max" { maxStr = val; }
        if field == "batch" { batchStr = val; }
        estData = None;
        fireConfirm = False;
    }

    async def previewCost -> None {
        estBusy = True;
        genErr = "";
        fireConfirm = False;
        try {
            e = await estimate_gen(_pid(), genProvider, genModel, _toInt(targetStr), _toInt(batchStr));
            estData = e;
        } except Exception {
            genErr = "estimate failed";
        }
        estBusy = False;
    }

    def _anyRunning -> bool {
        for j in genJobs {
            if _g(j, "status", "") == "running" { return True; }
        }
        return False;
    }

    """First click arms; second click spends. `fireConfirm` is never read back on
    the line after it is written — the arm path returns immediately."""
    def fireClick -> None {
        if not fireConfirm {
            fireConfirm = True;
            return;
        }
        fireConfirm = False;
        fireNow();
    }

    async def fireNow -> None {
        fireBusy = True;
        genErr = "";
        res: any = None;
        try {
            res = await start_gen(_pid(), genProvider, genModel, _toInt(targetStr), _toInt(maxStr), _toInt(batchStr));
        } except Exception {
            genErr = "start failed";
            fireBusy = False;
            return;
        }
        if res and res["ok"] {
            selJid = str(res["jid"]);
            estData = None;
            await refreshGen();
            if onRefresh is not None { await onRefresh(); }
        } else {
            genErr = _g(res, "error", "start failed");
        }
        fireBusy = False;
    }

    async def stopJob(jid: str) -> None {
        try { await stop_gen(_pid(), jid); } except Exception {}
        await refreshGen();
        if onRefresh is not None { await onRefresh(); }
    }

    def selectJob(jid: str) -> None {
        selJid = jid;
        selData = None;
        refreshGen();
    }

    def _fmtCost(v: any) -> str {
        try {
            return "$" + str(Math.round(float(str(v)) * 10000) / 10000);
        } except Exception {
            return "$0";
        }
    }

    def _elapsedOf(j: any) -> str {
        try {
            t0 = Date.parse(_g(j, "started", ""));
            fin = _g(j, "finished", "");
            t1 = Date.parse(fin) if fin else Date.now();
            s = int((t1 - t0) / 1000);
            if s < 0 { s = 0; }
            return str(s // 60) + "m" + str(s % 60) + "s";
        } except Exception {
            return "";
        }
    }

    """rows_done/target_rows as a clamped integer percent. Both counts are the
    server's (jms_gen._resolve_at reads them out of the worker's progress.json);
    the division is the only thing computed here."""
    def _pctOf(j: any) -> int {
        tgt = _toInt(_g(j, "target_rows", "0"));
        dn = _toInt(_g(j, "rows_done", "0"));
        if tgt <= 0 { return 0; }
        p = (dn * 100) // tgt;
        if p > 100 { p = 100; }
        if p < 0 { p = 0; }
        return p;
    }

    """Flat 3px fill bar. Props-object component (params + -> JsxElement) — call
    as _bar({"pct": n}), never positionally. `pct` is typed `any` precisely because
    of that: the checker sees the props dict, not the destructured int."""
    def _bar(pct: any) -> JsxElement {
        return <div
            role="progressbar"
            aria-label="rows generated"
            aria-valuenow={pct}
            aria-valuemin={0}
            aria-valuemax={100}
            style={{"height": "3px", "width": "100%", "background": "var(--jms-border)", "overflow": "hidden"}}
        >
            <div style={{"height": "100%", "width": str(pct) + "%", "background": "var(--jms-accent)"}} />
        </div>;
    }

    # --------------------------------------------------------------- render ----
    def _picker -> JsxElement {
        provs = _providers();
        canDraft = True;
        hint = "";
        if provider == "claude" and not _configured() {
            canDraft = False;
            hint = "Set an Anthropic key (⚙ KEYS, top bar) to draft with Claude.";
        }
        if provider == "mlx" and len(_modelsFor("mlx")) == 0 {
            canDraft = False;
            hint = "No local MLX model available — load one in the chat app first.";
        }
        # Disabled-reason surfacing, the BUILD TRAINING SPLIT shape (CurateStage
        # `_footer`): the same `hint` string is the button's `title` (hover) AND
        # the visible span, wired together by `aria-describedby` so a screen
        # reader announces the reason with the disabled button. The `else None`
        # keeps the attribute off the DOM when there is no hint to point at
        # (React drops null props).
        return <div className="jms-section flex flex-col gap-3">
            <span className="jms-section-label">DRAFT A PLAN</span>
            <div className="flex flex-wrap items-center gap-3">
                <div className="flex items-center gap-1">
                    {for p in provs {
                        <button
                            key={str(p["id"])}
                            className={"jms-btn" + (" jms-btn-accent" if provider == str(p["id"]) else "")}
                            onClick={lambda e: MouseEvent { pickProvider(str(p["id"])); }}
                        >{str(p["label"])}</button>
                    }}
                </div>
                <select
                    className="jms-input"
                    style={{"width": "auto", "minWidth": "180px"}}
                    aria-label="draft model"
                    value={model}
                    onChange={lambda e: any { model = str(e.target.value); }}
                >
                    {for mid in _modelsFor(provider) {
                        <option key={str(mid)} value={str(mid)}>{str(mid)}</option>
                    }}
                </select>
                <button
                    className="jms-btn jms-btn-accent"
                    disabled={drafting or not canDraft}
                    title={hint if hint else "draft a plan from the sources you attached"}
                    aria-describedby={"jms-gen-draft-hint" if hint else None}
                    onClick={lambda e: MouseEvent { draftNow(); }}
                >{"DRAFTING…" if drafting else "DRAFT PLAN"}</button>
            </div>
            {hint and <span id="jms-gen-draft-hint" className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{hint}</span>}
            {draftErr and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{draftErr}</span>}
            {drafting and <span className="jms-mono-dim">Grounding in your sources and asking the model — this can take 30-60s…</span>}
        </div>;
    }

    def _versions -> JsxElement {
        pl = _plans();
        if len(pl) == 0 { return <></>; }
        return <div className="jms-section flex flex-col gap-2">
            <span className="jms-section-label">VERSIONS</span>
            {for p in pl {
                <button
                    key={str(p["version"])}
                    className={"jms-pill" + (" jms-pill-active" if activeVersion == _toInt(_g(p, "version", "0")) else "")}
                    onClick={lambda e: MouseEvent { _loadPlan(p, _g(p, "status", "") != "draft"); }}
                >
                    <span className={"jms-pill-dot" + (" jms-pill-dot-done" if _g(p, "status", "") == "approved" else "")} />
                    <span>v{str(p["version"])} · {str(p["status"])} · {str(p["provider"])}</span>
                </button>
            }}
        </div>;
    }

    def _editor -> JsxElement {
        if activeVersion == 0 {
            return <div className="jms-section flex items-center justify-center" style={{"minHeight": "160px"}}>
                <span className="jms-mono-dim">No plan yet — draft one above to get started.</span>
            </div>;
        }
        ssum = _shareSum();
        ro = readOnly;
        return <div className="jms-section flex flex-col gap-4">
            <span className="jms-section-label">PLAN v{str(activeVersion)}</span>
            <div className="flex items-center gap-2">
                <span className={"jms-chip"} style={{"color": ("var(--jms-ok)" if activeStatus == "approved" else "var(--jms-accent)")}}>
                    {activeStatus}
                </span>
                {ro and <span className="jms-mono-dim">approved — read only</span>}
            </div>

            <div className="flex flex-col gap-1.5">
                <span className="jms-label">DESCRIPTION</span>
                <textarea
                    className="jms-textarea"
                    aria-label="plan description"
                    value={desc}
                    disabled={ro}
                    onChange={lambda e: any { desc = str(e.target.value); }}
                />
            </div>

            <div className="flex flex-col gap-2">
                <div className="flex items-center justify-between">
                    <span className="jms-label">EXAMPLE MIX</span>
                    <span className="jms-mono-dim" style={{"color": ("var(--jms-fg-dim)" if ssum == 100 else "var(--jms-danger)")}}>
                        Σ {str(ssum)}%{"" if ssum == 100 else " (≠100)"}
                    </span>
                </div>
                {for i in range(len(mix)) {
                    <div key={str(i)} className="flex items-start gap-2">
                        <input
                            className="jms-input"
                            style={{"width": "150px"}}
                            aria-label="example type name"
                            value={_g(mix[i], "type_name", "")}
                            placeholder="type_name"
                            disabled={ro}
                            onChange={lambda e: any { patchRow(i, "type_name", str(e.target.value)); }}
                        />
                        <input
                            className="jms-input flex-1"
                            aria-label="example type description"
                            value={_g(mix[i], "description", "")}
                            placeholder="what this category teaches"
                            disabled={ro}
                            onChange={lambda e: any { patchRow(i, "description", str(e.target.value)); }}
                        />
                        <input
                            className="jms-input"
                            style={{"width": "72px"}}
                            type="number"
                            aria-label="example type share percent"
                            value={_g(mix[i], "share_pct", "0")}
                            disabled={ro}
                            onChange={lambda e: any { patchRow(i, "share_pct", str(e.target.value)); }}
                        />
                        {not ro and <button
                            className="jms-btn jms-btn-danger"
                            onClick={lambda e: MouseEvent { dropRow(i); }}
                        >✕</button>}
                    </div>
                }}
                {not ro and <button
                    className="jms-btn"
                    style={{"alignSelf": "flex-start"}}
                    onClick={lambda e: MouseEvent { addRow(); }}
                >+ ADD ROW</button>}
            </div>

            <div className="flex flex-col gap-1.5">
                <span className="jms-label">TARGET ROWS</span>
                <input
                    className="jms-input"
                    style={{"width": "140px"}}
                    type="number"
                    aria-label="target rows"
                    value={targetRowsStr}
                    disabled={ro}
                    onChange={lambda e: any { targetRowsStr = str(e.target.value); }}
                />
            </div>

            <div className="flex flex-col gap-1.5">
                <span className="jms-label">SYSTEM PROMPT</span>
                <textarea
                    className="jms-textarea"
                    aria-label="system prompt"
                    value={sysPrompt}
                    disabled={ro}
                    onChange={lambda e: any { sysPrompt = str(e.target.value); }}
                />
            </div>

            <div className="flex flex-col gap-1.5">
                <span className="jms-label">GROUNDING NOTES</span>
                <textarea
                    className="jms-textarea"
                    aria-label="grounding notes"
                    value={grounding}
                    disabled={ro}
                    onChange={lambda e: any { grounding = str(e.target.value); }}
                />
            </div>

            {not ro and <div className="flex items-center gap-2">
                <button
                    className="jms-btn"
                    disabled={saveBusy}
                    onClick={lambda e: MouseEvent { saveDraft(); }}
                >{"SAVING…" if saveBusy else "SAVE DRAFT"}</button>
                <button
                    className="jms-btn jms-btn-accent"
                    disabled={saveBusy}
                    onClick={lambda e: MouseEvent { approveNow(); }}
                >APPROVE</button>
                <button
                    className="jms-btn"
                    disabled={drafting}
                    onClick={lambda e: MouseEvent { draftNow(); }}
                >REDRAFT</button>
            </div>}
        </div>;
    }

    def _synthConfig -> JsxElement {
        provs = _providers();
        hasApproved = _approvedPlan() is not None;
        canFire = hasApproved and estData is not None and bool(estData["cap_ok"]) and not _anyRunning() and not fireBusy;
        hint = "";
        if not hasApproved { hint = "Approve a plan in the PLAN tab first."; }
        elif genProvider == "claude" and not _configured() { hint = "Set an Anthropic key (⚙ KEYS, top bar) to generate with Claude."; }
        elif genProvider == "mlx" and len(_modelsFor("mlx")) == 0 { hint = "No local MLX model available — load one in the chat app first."; }
        tgtN = _toInt(targetStr);
        maxN = _toInt(maxStr);
        # A max BELOW target is silently self-defeating: the worker stops at max, so
        # the run costs money and still under-delivers. Warn before, not after.
        capWarn = maxN > 0 and maxN < tgtN;
        fireLabel = "FIRE";
        if fireBusy { fireLabel = "FIRING…"; }
        elif fireConfirm and canFire and estData is not None {
            fireLabel = "CLICK AGAIN TO SPEND ~" + _fmtCost(estData["est_cost_usd"]) + " · " + str(tgtN) + " ROWS";
        }
        return <div className="jms-section flex flex-col gap-3">
            <span className="jms-section-label">SYNTHESIZE ROWS</span>
            <div className="flex flex-wrap items-center gap-3">
                <div className="flex items-center gap-1">
                    {for p in provs {
                        <button
                            key={str(p["id"])}
                            className={"jms-btn" + (" jms-btn-accent" if genProvider == str(p["id"]) else "")}
                            onClick={lambda e: MouseEvent { pickGenProvider(str(p["id"])); }}
                        >{str(p["label"])}</button>
                    }}
                </div>
                <select
                    className="jms-input"
                    style={{"width": "auto", "minWidth": "180px"}}
                    aria-label="synthesis model"
                    value={genModel}
                    onChange={lambda e: any { genModel = str(e.target.value); estData = None; fireConfirm = False; }}
                >
                    {for mid in _modelsFor(genProvider) {
                        <option key={str(mid)} value={str(mid)}>{str(mid)}</option>
                    }}
                </select>
            </div>
            <div className="flex flex-wrap items-end gap-3">
                <div className="flex flex-col gap-1.5">
                    <span className="jms-label">TARGET ROWS</span>
                    <input
                        className="jms-input" style={{"width": "110px"}} type="number"
                        aria-label="target rows"
                        value={targetStr}
                        onChange={lambda e: any { patchGenField("target", str(e.target.value)); }}
                    />
                </div>
                <div className="flex flex-col gap-1.5">
                    <span className="jms-label">MAX ROWS (CAP)</span>
                    <input
                        className="jms-input" style={{"width": "110px"}} type="number"
                        aria-label="max rows cap"
                        value={maxStr}
                        onChange={lambda e: any { patchGenField("max", str(e.target.value)); }}
                    />
                </div>
                <div className="flex flex-col gap-1.5">
                    <span className="jms-label">BATCH</span>
                    <input
                        className="jms-input" style={{"width": "80px"}} type="number"
                        aria-label="batch size"
                        value={batchStr}
                        onChange={lambda e: any { patchGenField("batch", str(e.target.value)); }}
                    />
                </div>
                <button
                    className="jms-btn"
                    disabled={estBusy}
                    onClick={lambda e: MouseEvent { previewCost(); }}
                >{"ESTIMATING…" if estBusy else "PREVIEW COST"}</button>
                <button
                    className={"jms-btn jms-btn-accent" + (" jms-btn-danger" if fireConfirm else "")}
                    disabled={not canFire}
                    onClick={lambda e: MouseEvent { fireClick(); }}
                >{fireLabel}</button>
            </div>

            <span className="jms-mono-dim">
                TARGET is how many rows the worker aims for; MAX ROWS is the hard stop it will not
                pass. Batches of {batchStr} rows go out per request — one request costs roughly the
                same whatever the batch, so a bigger batch means fewer, cheaper requests.
                Product cap: 5000 rows per job.
            </span>
            {capWarn and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>
                MAX ROWS ({str(maxN)}) is below TARGET ({str(tgtN)}) — this run will stop at {str(maxN)} rows and still bill for what it spent.
            </span>}

            {estData and <div className="flex flex-col gap-2" style={{"borderTop": "1px solid var(--jms-border)", "paddingTop": "12px"}}>
                <div className="flex flex-wrap items-baseline gap-3">
                    <span className="jms-label">ESTIMATED COST</span>
                    <span className="jms-mono" style={{"fontSize": "22px", "lineHeight": "1"}}>{_fmtCost(estData["est_cost_usd"])}</span>
                    <span className="jms-mono-dim">for {_g(estData, "rows", "0")} rows in {_g(estData, "batches", "0")} requests</span>
                </div>
                <div className="flex flex-wrap items-center gap-4">
                    <span className="jms-stat">~IN {_g(estData, "est_input_tokens", "0")} tok</span>
                    <span className="jms-stat">~OUT {_g(estData, "est_output_tokens", "0")} tok</span>
                </div>
                <span className="jms-mono-dim">
                    Back-of-envelope only: token counts are the server's per-batch model, priced at the
                    model's published $/Mtok. Local MLX models price at $0. The real bill follows the
                    actual prompts — treat this as an order of magnitude, not a quote.
                </span>
                {not bool(estData["cap_ok"]) and <span className="jms-stat" style={{"color": "var(--jms-danger)"}}>OVER THE 5000-ROW CAP — lower TARGET ROWS</span>}
            </div>}
            {(estData is None and hasApproved and not hint) and <span className="jms-mono-dim">
                PREVIEW COST first — FIRE stays locked until you have seen what this run costs, and any
                edit above clears the estimate.
            </span>}

            {_anyRunning() and <span className="jms-mono-dim">a job is running — FIRE unlocks when it finishes</span>}
            {hint and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{hint}</span>}
            {genErr and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{genErr}</span>}
        </div>;
    }

    def _synthJobs -> JsxElement {
        if len(genJobs) == 0 { return <></>; }
        return <div className="jms-section flex flex-col gap-3">
            <span className="jms-section-label">GENERATION JOBS</span>
            {for j in genJobs {
                <div key={_g(j, "jid", "")} className="flex flex-col gap-1">
                    <div className="flex items-center gap-2">
                        <button
                            className={"jms-pill flex-1" + (" jms-pill-active" if selJid == _g(j, "jid", "") else "")}
                            onClick={lambda e: MouseEvent { selectJob(_g(j, "jid", "")); }}
                        >
                            <span className={"jms-pill-dot" + (" jms-pill-dot-done" if _g(j, "status", "") == "completed" else "")} />
                            <span>
                                {_g(j, "jid", "")} · {_g(j, "provider", "")}/{_g(j, "model", "")} ·
                                {" "}{_g(j, "rows_done", "0")}/{_g(j, "target_rows", "0")} rows ({str(_pctOf(j))}%) ·
                                {" "}{_g(j, "status", "")} · {_elapsedOf(j)} · {_fmtCost(j["est_cost_usd"])}
                            </span>
                        </button>
                        {_g(j, "status", "") == "running" and <button
                            className="jms-btn jms-btn-danger"
                            onClick={lambda e: MouseEvent { stopJob(_g(j, "jid", "")); }}
                        >STOP</button>}
                    </div>
                    {_bar({"pct": _pctOf(j)})}
                    {(_g(j, "status", "") == "running" and _g(j, "last_batch_at", "")) and <span className="jms-mono-dim">
                        last batch landed {_g(j, "last_batch_at", "")} · {_g(j, "batches", "0")} batches done · cost so far {_fmtCost(j["est_cost_usd"])}
                    </span>}
                    {_g(j, "error", "") and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{_g(j, "error", "")}</span>}
                </div>
            }}
        </div>;
    }

    def _synthLog -> JsxElement {
        if not selJid or selData is None { return <></>; }
        return <div className="jms-section flex flex-col gap-2">
            <span className="jms-section-label">JOB {selJid} · {_g(selData, "status", "")}</span>
            <div className="flex flex-wrap items-center gap-4">
                <span className="jms-stat">ROWS {_g(selData, "rows_done", "0")}/{_g(selData, "target_rows", "0")} · {str(_pctOf(selData))}%</span>
                <span className="jms-stat">CAP {_g(selData, "max_rows", "0")}</span>
                <span className="jms-stat">BATCHES {_g(selData, "batches", "0")}</span>
                <span className="jms-stat">PLAN v{_g(selData, "plan_version", "0")}</span>
                <span className="jms-stat">ELAPSED {_elapsedOf(selData)}</span>
                <span className="jms-stat">COST {_fmtCost(selData["est_cost_usd"])}</span>
            </div>
            {_bar({"pct": _pctOf(selData)})}
            {_g(selData, "error", "") and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{_g(selData, "error", "")}</span>}
            <pre
                className="jms-mono-dim"
                style={{"whiteSpace": "pre-wrap", "maxHeight": "260px", "overflow": "auto", "fontSize": "11px", "margin": "0"}}
            >{_g(selData, "log_tail", "")}</pre>
        </div>;
    }

    return <div className="flex flex-col gap-5">
        <div className="flex items-center gap-1">
            <button
                className={"jms-btn" + (" jms-btn-accent" if subtab == "plan" else "")}
                onClick={lambda e: MouseEvent { subtab = "plan"; }}
            >PLAN</button>
            <button
                className={"jms-btn" + (" jms-btn-accent" if subtab == "synthesize" else "")}
                onClick={lambda e: MouseEvent { subtab = "synthesize"; }}
            >SYNTHESIZE</button>
        </div>

        {subtab == "plan" and <div className="flex flex-col gap-5">
            {_picker()}
            <div className="flex gap-5">
                <div className="min-w-0 flex-1">{_editor()}</div>
                <div style={{"width": "200px", "flexShrink": "0"}}>{_versions()}</div>
            </div>
        </div>}

        {subtab == "synthesize" and <div className="flex flex-col gap-5">
            {_synthConfig()}
            {_synthJobs()}
            {_synthLog()}
        </div>}
    </div>;
}
