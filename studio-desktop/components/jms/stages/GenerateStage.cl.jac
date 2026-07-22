"""GenerateStage — the GENERATE stage panel of a JMS project.

A PLAN | SYNTHESIZE sub-tab toggle. SYNTHESIZE is a quiet placeholder for now.

PLAN: pick a provider (Claude / local MLX) + model, DRAFT PLAN (blocking ~30-60s,
spinner), then edit the returned plan — description, an example-type MIX table
(type_name / description / share_pct, add/remove rows, live share-sum with a warn
tint when ≠ 100), target rows, system prompt, grounding notes — and SAVE DRAFT /
APPROVE / REDRAFT. Prior versions list on the side; clicking one loads it (drafts
editable, approved read-only).

`project` is the get_project() dict; `onRefresh` re-pulls it after a mutation.
draft_plan/update_plan/approve_plan all return the fresh plan dict, so the editor
loads from the RPC result directly (no dependence on the async prop refresh).
Handlers are named draft.../save.../approve.../patchRow etc — never set<HasVar>."""

sv import from ....jms_plan { draft_plan, update_plan, approve_plan }
sv import from ....jms_llm { llm_status }

def _g(d: any, k: str, fallback: str) -> str {
    if d and k in d { return str(d[k]); }
    return fallback;
}

def _toInt(s: str) -> int {
    try { return int(float(s.strip())); } except Exception { return 0; }
}

def:pub GenerateStage(project: any = None, onRefresh: any = None) -> JsxElement {
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
        loadedInit: bool = False;

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

    async can with entry {
        await reloadStatus();
        if not loadedInit {
            pl = _plans();
            if len(pl) > 0 { _loadPlan(pl[0], _g(pl[0], "status", "") != "draft"); }
            loadedInit = True;
        }
    }

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
            nr = dict(r);
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
                    onClick={lambda e: MouseEvent { draftNow(); }}
                >{"DRAFTING…" if drafting else "DRAFT PLAN"}</button>
            </div>
            {hint and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{hint}</span>}
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
                            value={_g(mix[i], "type_name", "")}
                            placeholder="type_name"
                            disabled={ro}
                            onChange={lambda e: any { patchRow(i, "type_name", str(e.target.value)); }}
                        />
                        <input
                            className="jms-input flex-1"
                            value={_g(mix[i], "description", "")}
                            placeholder="what this category teaches"
                            disabled={ro}
                            onChange={lambda e: any { patchRow(i, "description", str(e.target.value)); }}
                        />
                        <input
                            className="jms-input"
                            style={{"width": "72px"}}
                            type="number"
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
                    value={targetRowsStr}
                    disabled={ro}
                    onChange={lambda e: any { targetRowsStr = str(e.target.value); }}
                />
            </div>

            <div className="flex flex-col gap-1.5">
                <span className="jms-label">SYSTEM PROMPT</span>
                <textarea
                    className="jms-textarea"
                    value={sysPrompt}
                    disabled={ro}
                    onChange={lambda e: any { sysPrompt = str(e.target.value); }}
                />
            </div>

            <div className="flex flex-col gap-1.5">
                <span className="jms-label">GROUNDING NOTES</span>
                <textarea
                    className="jms-textarea"
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

        {subtab == "synthesize" and <div className="jms-section flex items-center justify-center" style={{"minHeight": "220px"}}>
            <span className="jms-label">SYNTHESIZE · lands in the next phase</span>
        </div>}
    </div>;
}
