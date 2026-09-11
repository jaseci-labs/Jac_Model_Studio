"""TrainStage — the TRAIN stage panel of a JMS project.

Config card: a backend toggle (LOCAL MLX / MY CLUSTER). LOCAL picks an available
local base model from list_models; MY CLUSTER (the `"spheron"` backend token, kept
for wire compatibility) takes a free-text HF base-model id + a picker over the
user's own saved BYO-SSH clusters (list_clusters — created/tested in the
EXPERIMENTS · Cloud · CLUSTERS tab, never here) and a "runs on your own cluster
over SSH" note. Common LoRA opts (iters, batch, lr, r, alpha) with sensible
defaults. START TRAINING is disabled while a run is training or when no train
split is materialized (hint points back to CURATE).

Runs list: rid · backend chip · base-model · status dot · elapsed · adapter ✓;
selecting one opens a detail view (status line + remote phase/cost, LogView tail,
MonoChart loss curve, STOP). Polls list_train_runs / train_status every 3s ONLY
while `active` (this stage is the visible one) — the interval id is effect-local
so the cleanup can actually see it (Cloud.cl.jac pattern).

`project` is the get_project() dict; `onRefresh` re-pulls it after a mutation.
Handlers are named start.../stop.../select... — never set<HasVar>."""

import from react { useEffect }
sv import from ....jms_train { start_train, train_status, stop_train, list_train_runs }
sv import from ....models { list_models }
sv import from ....clusters { list_clusters }
import from ...shared.MonoChart { MonoChart }
import from ...shared.LogView { LogView }

def _g(d: any, k: str, fallback: str) -> str {
    if d and k in d { return str(d[k]); }
    return fallback;
}

def _toInt(s: str) -> int {
    try { return int(float(s.strip())); } except Exception { return 0; }
}

def:pub TrainStage(project: any = None, onRefresh: any = None, active: bool = True) -> JsxElement {
    has backend: str = "local-mlx",
        localModels: list = [],
        localModel: str = "",
        hfBase: str = "Qwen/Qwen3-0.6B",
        clusters: list = [],
        selClusterId: str = "",
        itersStr: str = "200",
        batchStr: str = "1",
        lrStr: str = "1e-5",
        loraRStr: str = "8",
        loraAlphaStr: str = "16",
        runs: list = [],
        selRid: str = "",
        selData: any = None,
        startBusy: bool = False,
        startErr: str = "";

    def _pid -> str {
        if project { return str(project["pid"]); }
        return "";
    }

    def _hasTrain -> bool {
        if project and "row_stats" in project {
            rs: any = project["row_stats"];
            if "curated" in rs { return int(str(rs["curated"])) > 0; }
        }
        return False;
    }

    def _anyRunning -> bool {
        for r in runs {
            if _g(r, "status", "") == "running" { return True; }
        }
        return False;
    }

    async def refreshRuns -> None {
        try {
            rl = await list_train_runs(_pid());
            runs = list(rl);
            if selRid {
                sd = await train_status(_pid(), selRid);
                selData = sd;
            }
        } except Exception {}
    }

    async def loadModels -> None {
        try {
            ms = await list_models();
            avail: list = [];
            for m in ms {
                if m["available"] { avail.append(m); }
            }
            localModels = avail;
            if localModel == "" and len(avail) > 0 { localModel = str(avail[0]["id"]); }
        } except Exception {}
    }

    async def loadClusters -> None {
        try {
            r = await list_clusters();
            if bool(r["ok"]) {
                clusters = list(r["clusters"]);
                if selClusterId == "" and len(clusters) > 0 {
                    selClusterId = str(clusters[0]["cluster_id"]);
                }
            }
        } except Exception {}
    }

    async can with entry {
        await loadModels();
        await loadClusters();
    }

    # Effect-local interval id + `active` gate: a `can with exit` cleanup closes over
    # the first-render (None) value of a `has` var, so it never cleared anything.
    useEffect(lambda {
        iv: any = None;
        if active {
            refreshRuns();
            iv = setInterval(lambda { refreshRuns(); }, 3000);
        }
        return lambda { if iv is not None { clearInterval(float(str(iv))); } };
    }, [active]);

    def _opts -> dict {
        iters = _toInt(itersStr);
        batch = _toInt(batchStr);
        return {
            "iters": iters, "batch_size": batch, "learning_rate": lrStr,
            "lora_r": _toInt(loraRStr), "lora_alpha": _toInt(loraAlphaStr),
            "max_steps": iters, "lr": lrStr, "per_device_batch_size": batch
        };
    }

    async def startNow -> None {
        startBusy = True;
        startErr = "";
        opts = _opts();
        baseModel = localModel if backend == "local-mlx" else hfBase;
        if backend == "spheron" {
            if selClusterId == "" {
                startErr = "add a cluster in the EXPERIMENTS Cloud CLUSTERS tab first";
                startBusy = False;
                return;
            }
            opts["cluster_id"] = selClusterId;
        }
        res: any = None;
        try {
            res = await start_train(_pid(), backend, baseModel, opts);
        } except Exception {
            startErr = "start failed";
            startBusy = False;
            return;
        }
        if res and res["ok"] {
            selRid = str(res["rid"]);
            selData = res["run"];
            await refreshRuns();
            if onRefresh is not None { await onRefresh(); }
        } else {
            startErr = _g(res, "error", "start failed");
        }
        startBusy = False;
    }

    async def stopRun(rid: str) -> None {
        try { await stop_train(_pid(), rid); } except Exception {}
        await refreshRuns();
        if onRefresh is not None { await onRefresh(); }
    }

    def selectRun(rid: str) -> None {
        selRid = rid;
        selData = None;
        refreshRuns();
    }

    def _elapsed(r: any) -> str {
        try {
            t0 = Date.parse(_g(r, "started", ""));
            fin = _g(r, "finished", "");
            t1 = Date.parse(fin) if fin else Date.now();
            s = int((t1 - t0) / 1000);
            if s < 0 { s = 0; }
            return str(s // 60) + "m" + str(s % 60) + "s";
        } except Exception {
            return "";
        }
    }

    def _fmtCost(v: any) -> str {
        try { return "$" + str(Math.round(float(str(v)) * 10000) / 10000); }
        except Exception { return "$0"; }
    }

    # --------------------------------------------------------------- render ----
    def _config -> JsxElement {
        canStart = _hasTrain() and not _anyRunning() and not startBusy;
        if backend == "local-mlx" and localModel == "" { canStart = False; }
        # Disabled-reason surfacing, the BUILD TRAINING SPLIT shape (CurateStage
        # `_footer`): one `startHint` string feeds the button's `title` (hover),
        # and `aria-describedby` points at whichever visible span already states
        # that same reason so a screen reader announces it with the disabled
        # button. The `else None` keeps the attribute off the DOM entirely when
        # there is no reason to point at (React drops null props).
        startHint = "";
        startHintId = "";
        if not _hasTrain() {
            startHint = "Materialize a training split first (CURATE stage).";
            startHintId = "jms-train-split-hint";
        } elif backend == "local-mlx" and localModel == "" {
            startHint = "No local base model available." if len(localModels) == 0
                        else "Pick a base model above.";
            if len(localModels) == 0 { startHintId = "jms-train-model-hint"; }
        } elif _anyRunning() {
            startHint = "a run is training — START unlocks when it finishes";
            startHintId = "jms-train-running-hint";
        }
        return <div className="jms-section flex flex-col gap-3">
            <span className="jms-section-label">TRAIN A LoRA ADAPTER</span>
            <div className="flex items-center gap-1">
                <button
                    className={"jms-btn" + (" jms-btn-accent" if backend == "local-mlx" else "")}
                    onClick={lambda e: MouseEvent { backend = "local-mlx"; startErr = ""; }}
                >LOCAL MLX</button>
                <button
                    className={"jms-btn" + (" jms-btn-accent" if backend == "spheron" else "")}
                    onClick={lambda e: MouseEvent { backend = "spheron"; startErr = ""; }}
                >MY CLUSTER</button>
            </div>

            {backend == "local-mlx" and <div className="flex flex-col gap-1.5">
                <span className="jms-label">BASE MODEL (local)</span>
                <select
                    className="jms-input" style={{"width": "auto", "minWidth": "220px"}}
                    aria-label="base model (local)"
                    value={localModel}
                    onChange={lambda e: any { localModel = str(e.target.value); }}
                >
                    {for m in localModels {
                        <option key={str(m["id"])} value={str(m["id"])}>{str(m["label"])} · {str(m["id"])}</option>
                    }}
                </select>
                {len(localModels) == 0 and <span id="jms-train-model-hint" className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>No local base model available.</span>}
            </div>}

            {backend == "spheron" and <div className="flex flex-col gap-2">
                <div className="flex flex-col gap-1.5">
                    <span className="jms-label">BASE MODEL (HuggingFace id)</span>
                    <input
                        className="jms-input" style={{"width": "260px"}}
                        aria-label="base model (HuggingFace id)"
                        value={hfBase}
                        onChange={lambda e: any { hfBase = str(e.target.value); }}
                    />
                </div>
                <div className="flex flex-col gap-1.5">
                    <span className="jms-label">CLUSTER</span>
                    {len(clusters) == 0 and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>no clusters — add one in EXPERIMENTS · Cloud · CLUSTERS</span>}
                    {len(clusters) > 0 and <div className="flex flex-col gap-1">
                        {for c in clusters {
                            <button
                                key={str(c["cluster_id"])}
                                className={"jms-pill" + (" jms-pill-active" if selClusterId == str(c["cluster_id"]) else "")}
                                onClick={lambda e: MouseEvent { selClusterId = str(c["cluster_id"]); }}
                            >
                                <span className="jms-pill-dot" />
                                <span>
                                    {str(c["label"])} · {str(c["user"])}@{str(c["host"])} ·
                                    {" " + ("● reachable" if bool(c["last_test_ok"]) else "○ unreachable")}
                                </span>
                            </button>
                        }}
                    </div>}
                </div>
                <span className="jms-mono-dim">runs on your own cluster over SSH</span>
            </div>}

            <div className="flex flex-wrap items-end gap-3">
                <div className="flex flex-col gap-1.5">
                    <span className="jms-label">{"ITERS" if backend == "local-mlx" else "MAX STEPS"}</span>
                    <input className="jms-input" style={{"width": "90px"}} type="number"
                        aria-label={"iters" if backend == "local-mlx" else "max steps"}
                        value={itersStr} onChange={lambda e: any { itersStr = str(e.target.value); }} />
                </div>
                <div className="flex flex-col gap-1.5">
                    <span className="jms-label">BATCH</span>
                    <input className="jms-input" style={{"width": "70px"}} type="number"
                        aria-label="batch size"
                        value={batchStr} onChange={lambda e: any { batchStr = str(e.target.value); }} />
                </div>
                <div className="flex flex-col gap-1.5">
                    <span className="jms-label">LR</span>
                    <input className="jms-input" style={{"width": "90px"}}
                        aria-label="learning rate"
                        value={lrStr} onChange={lambda e: any { lrStr = str(e.target.value); }} />
                </div>
                <div className="flex flex-col gap-1.5">
                    <span className="jms-label">LoRA r</span>
                    <input className="jms-input" style={{"width": "70px"}} type="number"
                        aria-label="LoRA r"
                        value={loraRStr} onChange={lambda e: any { loraRStr = str(e.target.value); }} />
                </div>
                <div className="flex flex-col gap-1.5">
                    <span className="jms-label">LoRA α</span>
                    <input className="jms-input" style={{"width": "70px"}} type="number"
                        aria-label="LoRA alpha"
                        value={loraAlphaStr} onChange={lambda e: any { loraAlphaStr = str(e.target.value); }} />
                </div>
                <button
                    className="jms-btn jms-btn-accent"
                    disabled={not canStart}
                    title={startHint if startHint else "train a LoRA adapter on the materialized split"}
                    aria-describedby={startHintId if startHintId else None}
                    onClick={lambda e: MouseEvent { startNow(); }}
                >{"STARTING…" if startBusy else "START TRAINING"}</button>
            </div>
            {not _hasTrain() and <span id="jms-train-split-hint" className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>Materialize a training split first (CURATE stage).</span>}
            {_anyRunning() and <span id="jms-train-running-hint" className="jms-mono-dim">a run is training — START unlocks when it finishes</span>}
            {startErr and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{startErr}</span>}
        </div>;
    }

    def _runsList -> JsxElement {
        if len(runs) == 0 { return <></>; }
        return <div className="jms-section flex flex-col gap-2">
            <span className="jms-section-label">TRAINING RUNS</span>
            {for r in runs {
                <div key={_g(r, "rid", "")} className="flex items-center gap-2">
                    <button
                        className={"jms-pill flex-1" + (" jms-pill-active" if selRid == _g(r, "rid", "") else "")}
                        onClick={lambda e: MouseEvent { selectRun(_g(r, "rid", "")); }}
                    >
                        <span className={"jms-pill-dot" + (" jms-pill-dot-done" if _g(r, "status", "") == "completed" else "")} />
                        <span>
                            {_g(r, "rid", "")} · <span className="jms-chip">{_g(r, "backend", "")}</span> ·
                            {" "}{_g(r, "base_model", "")} · {_g(r, "status", "")} · {_elapsed(r)}
                            {# adapter_ready is a real JSON bool → _g's String() yields "true",
                             # never Python's "True". Lowercase compare covers both shapes.
                             " " + ("· adapter ✓" if _g(r, "adapter_ready", "").lower() == "true" else "")}
                        </span>
                    </button>
                    {_g(r, "status", "") == "running" and <button
                        className="jms-btn jms-btn-danger"
                        onClick={lambda e: MouseEvent { stopRun(_g(r, "rid", "")); }}
                    >STOP</button>}
                </div>
            }}
        </div>;
    }

    def _detail -> JsxElement {
        if not selRid or not selData { return <></>; }
        d = selData;
        prog: any = d["progress"] if "progress" in d else {};
        cost: any = d["cost"] if "cost" in d else {};
        mets: list = list(d["metrics"]) if "metrics" in d and d["metrics"] else [];
        vals: list = list(d["val_metrics"]) if "val_metrics" in d and d["val_metrics"] else [];
        phase = _g(d, "phase", "");
        return <div className="jms-section flex flex-col gap-3">
            <span className="jms-section-label">RUN {selRid} · {_g(d, "status", "")}</span>
            <div className="flex flex-wrap items-center gap-4">
                <span className="jms-stat">BACKEND {_g(d, "backend", "")}</span>
                <span className="jms-stat">ITER {_g(prog, "last_iter", "0")}/{_g(prog, "total_iters", "0")}</span>
                {phase and <span className="jms-stat">PHASE {phase}</span>}
                {cost and "elapsed_usd" in cost and <span className="jms-stat">COST {_fmtCost(cost["elapsed_usd"])}</span>}
                {_g(d, "adapter_ready", "").lower() == "true" and <span className="jms-stat" style={{"color": "var(--jms-ok)"}}>ADAPTER ✓</span>}
            </div>
            {_g(d, "error", "") and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{_g(d, "error", "")}</span>}
            <MonoChart title="LOSS · train + val" data={mets} secondary={vals} live={_g(d, "status", "") == "running"} accent="var(--chart-1)" expY={False} />
            <LogView text={_g(d, "log_tail", "")} maxH="16rem" />
            {_g(d, "status", "") == "running" and <button
                className="jms-btn jms-btn-danger" style={{"alignSelf": "flex-start"}}
                onClick={lambda e: MouseEvent { stopRun(selRid); }}
            >STOP</button>}
        </div>;
    }

    return <div className="flex flex-col gap-5">
        {_config()}
        {_runsList()}
        {_detail()}
    </div>;
}
