"""CLOUD section — BYO GPU clusters + supervised remote training runs.

CLUSTERS: bring your own box. Step 1 generates an ed25519 keypair on THIS
machine (only the public half ever leaves it) — paste that public key into
whichever GPU console you like (Spheron, RunPod, Lambda, or a bare-metal box's
~/.ssh/authorized_keys). Step 2 pastes back the ssh link the vendor handed you;
JMS parses it, probes it once and saves it as a reusable cluster. A cluster that
does not answer yet is SAVED ANYWAY and shown as unreachable — a fresh VM is
usually still booting — RETEST re-probes it later. No API key, no billing, no
vendor SDK anywhere in the loop: the box is the user's own hardware.
RUNS: configure a remote SFT run (saved cluster + base model + LoRA/steps opts),
START it — the server resolves the cluster into an ssh command, writes
runspec.json and spawns remote/supervisor.py detached, which owns the run
end-to-end (upload data → bootstrap → launch → monitor → pull adapter). This tab
polls the supervisor's status.json: phase timeline, live train.log tail, and a
loud alert when the supervisor lost contact while the job may still be running
on the user's box (REATTACH resumes it).
"""

import from react { useEffect }
sv import from ...clusters {
    generate_ssh_key, list_ssh_keys, delete_ssh_key,
    add_cluster, list_clusters, retest_cluster, rename_cluster, remove_cluster
}
sv import from ...cloudruns {
    start_remote_run, run_status, list_cloud_runs,
    stop_run, reattach_run, pull_artifacts
}
import from ...hooks.useConfirmReset { useConfirmReset }
import from ..shared.SubTabs { SubTabs }
import from ..shared.Field { Field, TextInput, Segmented }
import from ..shared.StatusGlyph { StatusGlyph }
import from ..shared.LogView { LogView }

glob TABS: list[str] = ["CLUSTERS", "RUNS"];

# CLUSTERS is a two-step wizard: make a key, then connect a box with it.
glob STEPS: list[str] = ["SSH KEY", "CONNECT"];

# Supervisor phases → display chips (monitor shows as TRAIN).
glob PHASE_ORDER: list[str] = ["wait_vm", "provision", "launch", "monitor", "pull", "terminate"];
glob PHASE_LABELS: list[str] = ["WAIT BOX", "PROVISION", "LAUNCH", "TRAIN", "PULL", "RELEASE"];

def _clusterAddr(c: any) -> str {
    u = str(c["user"]);
    h = str(c["host"]);
    p = str(c["port"]);
    return f"{u}@{h}:{p}";
}

"""ISO timestamp → just the date part (created_at / last_test_at are display-only)."""
def _day(ts: str) -> str {
    s = str(ts);
    return s.split("T")[0] if s else "—";
}

"""Index of the run's current phase in PHASE_ORDER (terminal/finalize → past
the end so every chip renders done; unknown/starting → -1)."""
def _phaseIdx(run: any) -> int {
    status = str(run["status"]);
    phase = str(run["phase"]);
    if status == "done" or phase == "finalize" { return len(PHASE_ORDER); }
    idx = 0;
    for p in PHASE_ORDER {
        if p == phase { return idx; }
        idx += 1;
    }
    return -1;
}

def _costLine(run: any) -> str {
    cost: dict = {**run["cost"]};
    rate = float(str(cost["hourly_rate"])) if "hourly_rate" in cost else 0.0;
    usd = float(str(cost["elapsed_usd"])) if "elapsed_usd" in cost else 0.0;
    return f"${rate}/hr · elapsed ${usd}";
}

def:pub Cloud(active: bool) -> JsxElement {
    has tab: str = "clusters";
    # CLUSTERS tab — wizard step + key/cluster inventories.
    has step: str = "SSH KEY";
    has sshKeys: list = [];
    has newKeyLabel: str = "";
    # Last generate_ssh_key() result — its public_key is shown in a copy box
    # until dismissed. Public material only; the private half never leaves disk.
    has freshKey: any = None;
    has copiedId: str = "";
    has confirmDeleteKey: str = "";
    has clusterList: list = [];
    has newClusterLabel: str = "";
    has linkText: str = "";
    has newClusterKeyId: str = "";
    # add_cluster() result: ok=True with test_ok=False is "saved, not up yet".
    has addResult: any = None;
    has confirmRemoveCluster: str = "";
    has renameId: str = "";
    has renameText: str = "";
    # RUNS tab — a run targets one saved cluster.
    has selClusterId: str = "";
    # Cloud-run config form (sft only for now — see cloudruns.start_remote_run).
    has formName: str = "qwen-cloud";
    has formModelId: str = "Qwen/Qwen3-Coder-30B-A3B-Instruct";
    has cloudOpts: dict = {
        "lora_r": "16", "lora_alpha": "32", "lora_dropout": "0.05",
        "max_steps": "200", "lr": "1e-4",
        "per_device_batch_size": "1", "grad_accum": "4",
        "max_seq_len": "2048", "eval_every": "50"
    };
    has autoTerm: bool = True;
    has maxWall: str = "720";
    # Runs list + selection.
    has runs: list = [];
    has selRunId: str = "";
    has runDetail: any = None;
    has error: str = "";
    has busy: bool = False;

    # NB: every loader auto-selects off a LOCAL binding of the fetched list, not
    # off the `has` field it just assigned. A `has` write is a React setState —
    # the field still holds the previous render's value for the rest of this
    # function, so `sshKeys`/`clusterList`/`runs` read back stale here. The old
    # INSTANCES/RUNS code read the field and only ever auto-selected on the NEXT
    # poll tick; CLUSTERS does not poll at all, so it would never have selected.
    async def _loadKeys() {
        try {
            r = await list_ssh_keys();
            if bool(r["ok"]) {
                ks = list(r["keys"]);
                sshKeys = ks;
                # Re-seed the CONNECT picker when it is unset OR still points at
                # a key that has since been deleted (add_cluster would reject it
                # with a bare "unknown ssh key").
                live = [str(k["key_id"]) for k in ks];
                if newClusterKeyId not in live {
                    newClusterKeyId = str(ks[0]["key_id"]) if len(ks) > 0 else "";
                }
            }
        } except Exception {}
    }
    async def _loadClusters() {
        try {
            r = await list_clusters();
            if bool(r["ok"]) {
                cs = list(r["clusters"]);
                clusterList = cs;
                live = [str(c["cluster_id"]) for c in cs];
                if selClusterId not in live {
                    selClusterId = str(cs[0]["cluster_id"]) if len(cs) > 0 else "";
                }
            }
        } except Exception {}
    }
    async def _loadRuns() {
        try {
            r = await list_cloud_runs();
            rs = list(r["runs"]);
            runs = rs;
            if selRunId == "" and len(rs) > 0 {
                selRunId = str(rs[0]["run_id"]);
            }
        } except Exception {}
    }
    async def _pollRun() {
        if selRunId == "" { return; }
        try {
            r = await run_status(selRunId);
            if bool(r["ok"]) { runDetail = r["run"]; }
        } except Exception {}
    }

    # CLUSTERS is not a live view — nothing here changes without a user action,
    # so it refreshes on tab-enter and after every mutation instead of polling.
    # The cluster list is also loaded for RUNS, which needs the target picker.
    useEffect(lambda {
        if active {
            _loadClusters();
            if tab == "clusters" { _loadKeys(); }
        }
    }, [active, tab]);

    useEffect(lambda {
        iv: any = None;
        if active and tab == "runs" {
            _loadRuns();
            iv = setInterval(lambda { _loadRuns(); }, 3000);
        }
        return lambda { if iv is not None { clearInterval(float(str(iv))); } };
    }, [active, tab]);

    useEffect(lambda {
        iv: any = None;
        if active and tab == "runs" and selRunId != "" {
            _pollRun();
            iv = setInterval(lambda { _pollRun(); }, 3000);
        }
        return lambda { if iv is not None { clearInterval(float(str(iv))); } };
    }, [active, tab, selRunId]);

    # Armed destructive confirms ("⚠ CONFIRM DELETE KEY?" / "⚠ CONFIRM REMOVE?")
    # disarm themselves on Escape, on a pointer-down outside the button, or after
    # 4s — see hooks/useConfirmReset. Without it a button stayed armed forever and
    # a later stray click on the same spot silently destroyed a key / cluster.
    # Both states hold the armed ID (not a bool), so arming a DIFFERENT row
    # re-fires the effect and restarts that row's timer; "" means nothing armed.
    # (bare `lambda {}`, not `lambda -> None {}` as in the sibling call sites, so
    # this file stays at its zero-new-diagnostic W3037 baseline.)
    useConfirmReset(confirmDeleteKey, lambda { confirmDeleteKey = ""; });
    useConfirmReset(confirmRemoveCluster, lambda { confirmRemoveCluster = ""; });

    def onTab(t: str) { tab = t.lower(); }
    def pickCluster(cid: str) { selClusterId = cid; }
    def pickRun(rid: str) { selRunId = rid; runDetail = None; }
    def updateOpt(key: str, value: str) {
        updated: dict = {**cloudOpts};
        updated[key] = value;
        cloudOpts = updated;
    }
    def copyText(text: str, marker: str) {
        nav: any = navigator;
        nav.clipboard.writeText(text);
        copiedId = marker;
        setTimeout(lambda { copiedId = ""; }, 1400);
    }

    def _selectedCluster() -> dict {
        for c in clusterList {
            if str(c["cluster_id"]) == selClusterId { return {**c}; }
        }
        return {};
    }

    def _clusterById(cid: str) -> dict {
        for c in clusterList {
            if str(c["cluster_id"]) == cid { return {**c}; }
        }
        return {};
    }

    async def doGenerateKey() {
        busy = True;
        error = "";
        try {
            r = await generate_ssh_key(newKeyLabel.strip());
            if bool(r["ok"]) {
                freshKey = r;
                newKeyLabel = "";
                await _loadKeys();
            } else {
                error = str(r["error"]);
            }
        } except Exception {
            error = "key generation failed";
        }
        busy = False;
    }
    async def doDeleteKey(kid: str) {
        if kid == "" { return; }
        if confirmDeleteKey != kid { confirmDeleteKey = kid; return; }
        confirmDeleteKey = "";
        busy = True;
        error = "";
        try {
            r = await delete_ssh_key(kid);
            if not bool(r["ok"]) { error = str(r["error"]); }
            await _loadKeys();
        } except Exception {
            error = "key delete failed";
        }
        busy = False;
    }
    async def doAddCluster() {
        if not newClusterLabel.strip() { error = "name this cluster first"; return; }
        if not linkText.strip() { error = "paste the ssh link your vendor gave you"; return; }
        if newClusterKeyId == "" { error = "generate an SSH key first"; return; }
        busy = True;
        error = "";
        addResult = None;
        try {
            r = await add_cluster(newClusterLabel.strip(), linkText.strip(), newClusterKeyId);
            if bool(r["ok"]) {
                # ok + test_ok=False is the NORMAL "saved but still booting"
                # outcome — surfaced as an inline status, never as an error.
                addResult = r;
                newClusterLabel = "";
                linkText = "";
                await _loadClusters();
            } else {
                error = str(r["error"]);
            }
        } except Exception {
            error = "could not save that cluster";
        }
        busy = False;
    }
    async def doRetest(cid: str) {
        if cid == "" { return; }
        busy = True;
        error = "";
        try {
            r = await retest_cluster(cid);
            if not bool(r["ok"]) { error = str(r["error"]); }
            await _loadClusters();
        } except Exception {
            error = "retest failed";
        }
        busy = False;
    }
    async def doRename(cid: str) {
        if cid == "" { return; }
        if not renameText.strip() { error = "name cannot be empty"; return; }
        busy = True;
        error = "";
        try {
            r = await rename_cluster(cid, renameText.strip());
            if bool(r["ok"]) {
                renameId = "";
                renameText = "";
                await _loadClusters();
            } else {
                error = str(r["error"]);
            }
        } except Exception {
            error = "rename failed";
        }
        busy = False;
    }
    async def doRemoveCluster(cid: str) {
        if cid == "" { return; }
        if confirmRemoveCluster != cid { confirmRemoveCluster = cid; return; }
        confirmRemoveCluster = "";
        busy = True;
        error = "";
        try {
            r = await remove_cluster(cid);
            if not bool(r["ok"]) { error = str(r["error"]); }
            # _loadClusters re-seeds selClusterId whenever it no longer names a
            # live cluster, so removing the selected one needs nothing extra.
            await _loadClusters();
        } except Exception {
            error = "remove failed";
        }
        busy = False;
    }
    async def doStartRun() {
        if selClusterId == "" { error = "no clusters yet — add one in the CLUSTERS tab"; return; }
        opts: dict = {};
        for k in cloudOpts.keys() {
            v = str(cloudOpts[k]).strip();
            if v { opts[str(k)] = v; }
        }
        busy = True;
        error = "";
        try {
            r = await start_remote_run({
                "name": formName,
                "mode": "sft",
                "base_model": formModelId,
                "cluster_id": selClusterId,
                "opts": opts,
                "policy": {
                    "auto_terminate": "on_success" if autoTerm else "never",
                    "max_wall_clock_min": maxWall
                }
            });
            if bool(r["ok"]) {
                runDetail = r["run"];
                selRunId = str(r["run"]["run_id"]);
                await _loadRuns();
            } else {
                error = str(r["error"]);
            }
        } except Exception {
            error = "start failed";
        }
        busy = False;
    }
    async def doStopRun() {
        if selRunId == "" { return; }
        busy = True;
        try {
            r = await stop_run(selRunId);
            if bool(r["ok"]) {
                runDetail = r["run"];
                await _loadRuns();
            } else {
                error = str(r["error"]);
            }
        } except Exception {
            error = "stop failed";
        }
        busy = False;
    }
    async def doReattach() {
        if selRunId == "" { return; }
        busy = True;
        error = "";
        try {
            r = await reattach_run(selRunId);
            if bool(r["ok"]) {
                runDetail = r["run"];
                await _loadRuns();
            } else {
                error = str(r["error"]);
            }
        } except Exception {
            error = "reattach failed";
        }
        busy = False;
    }
    async def doPull() {
        if selRunId == "" { return; }
        busy = True;
        error = "";
        try {
            r = await pull_artifacts(selRunId);
            if bool(r["ok"]) { runDetail = r["run"]; }
            else { error = str(r["error"]); }
        } except Exception {
            error = "pull failed";
        }
        busy = False;
    }

    # NOTE: nested JSX-returning defs compile to props components — call them
    # with a dict ({"k": key}), the same way _runRow/_phaseChips are called.
    def _keyCard(k: any) -> JsxElement {
        btn = "exp-btn ";
        kid = str(k["key_id"]);
        armed = confirmDeleteKey == kid;
        pub = str(k["public_key"]);
        return <div key={kid} className="flex flex-col gap-1.5 rounded-lg border border-border px-3 py-2">
            <div className="flex flex-wrap items-baseline gap-2">
                <span className="font-mono text-xs text-foreground">{str(k["label"])}</span>
                <span className="font-mono text-[10px] text-muted-foreground break-all">{str(k["fingerprint"])}</span>
                <span className="font-mono text-[10px] text-muted-foreground/80">{_day(str(k["created_at"]))}</span>
            </div>
            <div className="flex flex-wrap gap-2">
                <button
                    onClick={lambda (e: MouseEvent) { copyText(pub, kid); }}
                    aria-label={"Copy public key for " + str(k["label"])}
                    className={btn + "text-foreground"}>
                    {"✓ COPIED" if copiedId == kid else "⧉ COPY PUBLIC KEY"}
                </button>
                <button
                    onClick={lambda (e: MouseEvent) { doDeleteKey(kid); }}
                    disabled={busy}
                    data-confirm-armed={"1" if armed else None}
                    aria-label={"Confirm delete key " + str(k["label"]) if armed else "Delete key " + str(k["label"])}
                    className={btn + ("border-danger text-danger" if armed else "text-muted-foreground")}>
                    {"⚠ CONFIRM DELETE KEY?" if armed else "✕ DELETE"}
                </button>
            </div>
        </div>;
    }

    def _clusterCard(c: any) -> JsxElement {
        btn = "exp-btn ";
        cid = str(c["cluster_id"]);
        armed = confirmRemoveCluster == cid;
        reachable = bool(c["last_test_ok"]);
        editing = renameId == cid;
        keyLabel = str(c["key_label"]) or "key deleted";
        return <div key={cid} className="flex flex-col gap-1.5 rounded-lg border border-border px-3 py-2">
            <div className="flex flex-wrap items-baseline gap-2">
                <span className="font-mono text-xs text-foreground">{str(c["label"])}</span>
                <span className={"font-mono text-[10px] " + (
                    "text-ok" if reachable else "text-muted-foreground"
                )}>
                    {"● reachable" if reachable else "○ unreachable"}
                </span>
                <span className="font-mono text-[10px] text-muted-foreground break-all">{_clusterAddr(c)}</span>
                <span className="font-mono text-[10px] text-muted-foreground/80">key · {keyLabel}</span>
            </div>
            {str(c["last_test_msg"]) and <span className="stat-line text-muted-foreground/80">
                {str(c["last_test_msg"])} · tested {_day(str(c["last_test_at"]))}
            </span>}
            {editing and <div className="flex items-end gap-2">
                <Field label="NEW NAME">
                    <TextInput value={renameText} onSet={lambda (v: str) { renameText = v; }} placeholder="my-4090-box" mono={True} />
                </Field>
                <button onClick={lambda (e: MouseEvent) { doRename(cid); }} disabled={busy} className={btn + "text-foreground"}>SAVE</button>
                <button onClick={lambda (e: MouseEvent) { renameId = ""; renameText = ""; }} className={btn + "text-muted-foreground"}>CANCEL</button>
            </div>}
            <div className="flex flex-wrap gap-2">
                <button onClick={lambda (e: MouseEvent) { doRetest(cid); }} disabled={busy}
                    aria-label={"Retest connection to " + str(c["label"])}
                    className={btn + "text-foreground"}>↻ RETEST</button>
                {not editing and <button
                    onClick={lambda (e: MouseEvent) { renameId = cid; renameText = str(c["label"]); }}
                    aria-label={"Rename " + str(c["label"])}
                    className={btn + "text-muted-foreground"}>✎ RENAME</button>}
                <button
                    onClick={lambda (e: MouseEvent) { doRemoveCluster(cid); }}
                    disabled={busy}
                    data-confirm-armed={"1" if armed else None}
                    aria-label={"Confirm remove cluster " + str(c["label"]) if armed else "Remove cluster " + str(c["label"])}
                    className={btn + ("border-danger text-danger" if armed else "text-muted-foreground")}>
                    {"⚠ CONFIRM REMOVE?" if armed else "✕ REMOVE"}
                </button>
            </div>
        </div>;
    }

    def _stepKey() -> JsxElement {
        btn = "exp-btn ";
        return <div className="relative exp-panel p-4 pt-5">
            <span className="micro-label absolute -top-2 left-3 bg-background px-2">STEP 1 · SSH KEY</span>
            <p className="stat-line text-muted-foreground">
                generated here, on your machine — only the PUBLIC half ever leaves it. make a new one anytime.
            </p>
            <div className="mt-3 flex items-end gap-2">
                <Field label="KEY NAME (NO SPACES)">
                    <TextInput value={newKeyLabel} onSet={lambda (v: str) { newKeyLabel = v; }} placeholder="my-gpu-box" mono={True} />
                </Field>
                <button onClick={lambda (e: MouseEvent) { doGenerateKey(); }} disabled={busy} className={btn + "text-foreground"}>+ GENERATE NEW KEY</button>
            </div>

            {bool(freshKey) and <div className="mt-3 rounded-md border border-accent bg-accent/10 p-3">
                <p className="font-mono text-[11px] font-bold text-foreground">PUBLIC KEY · {str(freshKey["label"])}</p>
                <p className="stat-line mt-1 text-muted-foreground">
                    paste this into your GPU vendor's console (Spheron, RunPod, Lambda, your own box's ~/.ssh/authorized_keys — anywhere) when you create the instance
                </p>
                <pre className="exp-panel mt-2 overflow-x-auto p-2 font-mono text-[10px] leading-relaxed text-foreground break-all whitespace-pre-wrap">{str(freshKey["public_key"])}</pre>
                <div className="mt-2 flex flex-wrap gap-2">
                    <button
                        onClick={lambda (e: MouseEvent) { copyText(str(freshKey["public_key"]), "fresh"); }}
                        aria-label="Copy the freshly generated public key"
                        className={btn + "text-foreground"}>
                        {"✓ COPIED" if copiedId == "fresh" else "⧉ COPY PUBLIC KEY"}
                    </button>
                    <button onClick={lambda (e: MouseEvent) { freshKey = None; step = "CONNECT"; }} className={btn + "text-muted-foreground"}>NEXT · CONNECT A BOX →</button>
                </div>
            </div>}

            <div className="mt-3 flex flex-col gap-2">
                {len(sshKeys) == 0 and <span className="stat-line text-muted-foreground/80">no keys yet · generate one above</span>}
                {[_keyCard({"k": k}) for k in sshKeys if k]}
            </div>
        </div>;
    }

    def _stepConnect() -> JsxElement {
        btn = "exp-btn ";
        return <div className="relative exp-panel p-4 pt-5">
            <span className="micro-label absolute -top-2 left-3 bg-background px-2">STEP 2 · CONNECT</span>
            <p className="stat-line text-muted-foreground">
                once the box is up with your public key installed, paste the ssh link the vendor gave you
            </p>
            <div className="mt-3 flex flex-col gap-2">
                <Field label="CLUSTER NAME (NO SPACES)">
                    <TextInput value={newClusterLabel} onSet={lambda (v: str) { newClusterLabel = v; }} placeholder="my-4090-box" mono={True} />
                </Field>
                <Field label="SSH LINK / COMMAND" htmlFor="cloud-link">
                    <textarea
                        id="cloud-link"
                        rows={2}
                        aria-label="ssh link or command from your GPU vendor"
                        value={linkText}
                        onChange={lambda (e: ChangeEvent) { linkText = str(e.target.value); }}
                        placeholder="ssh root@203.0.113.10 -p 2222"
                        className="exp-input resize-none font-mono"
                    ></textarea>
                </Field>
                <Field label="SSH KEY" htmlFor="cloud-key">
                    <select
                        id="cloud-key"
                        aria-label="ssh key installed on this box"
                        value={newClusterKeyId}
                        onChange={lambda (e: ChangeEvent) { newClusterKeyId = str(e.target.value); }}
                        className="exp-input font-mono"
                    >
                        {for k in sshKeys {
                            <option key={str(k["key_id"])} value={str(k["key_id"])}>{str(k["label"])}</option>
                        }}
                    </select>
                </Field>
                {len(sshKeys) == 0 and <span className="stat-line text-muted-foreground/80">no keys yet — generate one in STEP 1 first</span>}
                <button
                    onClick={lambda (e: MouseEvent) { doAddCluster(); }}
                    disabled={busy or len(sshKeys) == 0}
                    className={btn + "self-start text-foreground"}>TEST &amp; SAVE</button>
            </div>
            {bool(addResult) and <p className="stat-line mt-2" style={{
                "color": "var(--ok)" if bool(addResult["test_ok"]) else "var(--text-muted)"
            }}>
                {"✓ saved · reachable" if bool(addResult["test_ok"]) else "saved — " + str(addResult["test_message"]) + " · RETEST it below once the box finishes booting"}
            </p>}
        </div>;
    }

    def _clusters() -> JsxElement {
        return <div className="flex flex-col gap-4 p-4">
            <Segmented options={STEPS} value={step} onSet={lambda (v: str) { step = v; addResult = None; }} />
            {step == "SSH KEY" and _stepKey()}
            {step == "CONNECT" and _stepConnect()}

            <div className="relative exp-panel p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">SAVED CLUSTERS</span>
                {len(clusterList) == 0 and <span className="stat-line text-muted-foreground/80">no clusters yet · finish both steps above</span>}
                <div className="mt-2 flex flex-col gap-2">
                    {[_clusterCard({"c": c}) for c in clusterList if c]}
                </div>
            </div>
            {error and <p className="stat-line" style={{"color": "var(--danger)"}}>{error}</p>}
        </div>;
    }

    def _phaseChips(run: any) -> JsxElement {
        cur = _phaseIdx(run);
        failed = str(run["status"]) == "failed";
        return <div className="flex flex-wrap items-center gap-1">
            {for (i, lbl) in enumerate(PHASE_LABELS) {
                cls = "rounded border px-1.5 py-0.5 font-mono text-[9px] ";
                if i < cur {
                    cls += "border-input bg-secondary text-muted-foreground";
                } elif i == cur {
                    cls += "border-danger bg-danger/10 text-danger" if failed
                        else "border-accent bg-accent/15 text-foreground";
                } else {
                    cls += "border-border text-muted-foreground/60";
                }
                <span key={str(lbl)} className={cls}>{str(lbl)}</span>
            }}
        </div>;
    }

    def _runRow(run: any) -> JsxElement {
        if not run { return <></>; }
        rid = str(run["run_id"]);
        status = str(run["status"]);
        alert = bool(run["billing_alert"]);
        dotCls = "inline-block h-2 w-2 rounded-full ";
        if status == "running" { dotCls += "bg-ok"; }
        elif status == "done" { dotCls += "bg-foreground"; }
        elif status == "detached" or status == "failed" { dotCls += "bg-danger"; }
        else { dotCls += "bg-muted-foreground"; }
        return <button
            key={rid}
            onClick={lambda (e: MouseEvent) { pickRun(rid); }}
            className={"flex flex-col gap-1 exp-hoverable rounded-lg border px-3 py-2 text-left transition-colors " + (
                "border-accent bg-accent/15" if selRunId == rid
                else "border-border hover:border-input"
            )}
        >
            <div className="flex items-center gap-2">
                <span className={dotCls}></span>
                <span className="font-mono text-xs text-foreground">{str(run["name"])}</span>
                <span className="font-mono text-[10px] text-muted-foreground">{status}</span>
                {alert and <span className="rounded border border-danger bg-danger/10 px-1.5 font-mono text-[9px] text-danger">NO CONTACT</span>}
            </div>
            {_phaseChips({"run": run})}
            <span className="font-mono text-[10px] text-muted-foreground">{_costLine(run)}</span>
        </button>;
    }

    def _runDetailPane() -> JsxElement {
        btn = "exp-btn ";
        if not runDetail {
            return <span className="stat-line text-muted-foreground/80">select a run</span>;
        }
        run: any = runDetail;
        status = str(run["status"]);
        detached = bool(run["detached"]);
        alert = bool(run["billing_alert"]);
        onCluster = _clusterById(str(run["cluster_id"]));
        # `"label" in onCluster`, NOT `len(onCluster) > 0`: a Jac dict compiles to a
        # plain JS object and `len()` compiles to `.length`, which is `undefined` on
        # one — so the length test is silently always-false and this fell back to the
        # raw cluster_id hash forever. Key-membership is the dict-safe spelling (same
        # as the `"step" in prog` tests just below).
        clusterName = str(onCluster["label"]) if "label" in onCluster else (str(run["cluster_id"]) or "—");
        prog: dict = {**run["progress"]};
        step_n = str(prog["step"]) if "step" in prog else "0";
        maxSteps = str(prog["max_steps"]) if "max_steps" in prog else "0";
        loss = str(prog["loss"]) if "loss" in prog and prog["loss"] is not None else "—";
        evalLoss = str(prog["eval_loss"]) if "eval_loss" in prog and prog["eval_loss"] is not None else "—";
        art: dict = {**run["artifacts"]};
        pulled = bool(art["pulled"]) if "pulled" in art else False;
        adapterDir = str(art["adapter_dir"]) if "adapter_dir" in art else "";
        isTerminal = status == "done" or status == "failed" or status == "stopped";
        return <>
            {alert and <div className="rounded-md border border-danger bg-danger/10 p-3">
                <p className="font-mono text-[11px] font-bold text-danger">DETACHED — SUPERVISOR LOST CONTACT</p>
                <p className="stat-line mt-1" style={{"color": "var(--danger)"}}>the job may still be running on your cluster · reattach to resume supervising it, or stop it once reattached</p>
                <button onClick={lambda (e: MouseEvent) { doReattach(); }} disabled={busy} className={btn + "mt-2 border-danger text-danger"}>↻ REATTACH</button>
            </div>}
            <div className="flex items-center gap-3">
                <StatusGlyph status={"failed" if status == "detached" else status} showLabel={True} />
                <span className="font-mono text-[11px] text-muted-foreground">{str(run["name"])} · {str(run["mode"])} · on {clusterName}</span>
            </div>
            {_phaseChips({"run": run})}
            <span className="font-mono text-[11px] text-muted-foreground">{_costLine(run)}</span>
            <span className="font-mono text-[11px] text-muted-foreground">step {step_n}/{maxSteps} · loss {loss} · eval {evalLoss}</span>
            {str(run["message"]) and <span className="font-mono text-[11px] text-muted-foreground">{str(run["message"])}</span>}
            {str(run["error"]) and <span className="font-mono text-[11px] text-danger">{str(run["error"])}</span>}
            <LogView text={str(run["log_tail"]) or "no train.log yet"} maxH="14rem" />
            <div className="flex flex-wrap gap-2">
                <button onClick={lambda (e: MouseEvent) { doStopRun(); }} disabled={busy or isTerminal or detached} className={btn + "text-muted-foreground"}>■ STOP</button>
                {isTerminal and not pulled and <button onClick={lambda (e: MouseEvent) { doPull(); }} disabled={busy} className={btn + "text-foreground"}>⇩ PULL ARTIFACTS</button>}
            </div>
            {pulled and adapterDir and <span className="font-mono text-[11px] text-muted-foreground break-all">adapter · {adapterDir}</span>}
        </>;
    }

    def _runs() -> JsxElement {
        btn = "exp-btn ";
        selCluster = _selectedCluster();
        # Key-membership, not `len(selCluster) > 0` — see the note in _runDetailPane:
        # `len()` on a dict compiles to `.length` and is always undefined, which kept
        # the "runs on <cluster>" confirmation line permanently hidden.
        hasSelCluster = "label" in selCluster;
        return <div className="flex flex-col gap-4 p-4">
            <div className="flex items-start gap-4">
                <div className="relative flex min-w-0 flex-1 flex-col gap-3 exp-panel p-4 pt-5">
                    <span className="micro-label absolute -top-2 left-3 bg-background px-2">RUN.CONFIG</span>

                    <Field label="CLUSTER">
                        <div className="flex flex-col gap-1">
                            {len(clusterList) == 0 and <span className="stat-line text-muted-foreground/80">no clusters yet — add one in the CLUSTERS tab</span>}
                            {for c in clusterList {
                                cid = str(c["cluster_id"]);
                                <button
                                    key={cid}
                                    onClick={lambda (e: MouseEvent) { pickCluster(cid); }}
                                    className={"exp-hoverable rounded-lg border px-3 py-1 text-left font-mono text-xs transition-colors " + (
                                        "border-accent bg-accent/15 text-foreground" if selClusterId == cid
                                        else "border-input text-muted-foreground hover:text-foreground/80"
                                    )}
                                >
                                    {("● " if bool(c["last_test_ok"]) else "○ ") + str(c["label"])} · {_clusterAddr(c)}
                                </button>
                            }}
                        </div>
                    </Field>

                    <Field label="SHORT NAME">
                        <TextInput value={formName} onSet={lambda (v: str) { formName = v; }} placeholder="qwen-cloud" mono={True} />
                    </Field>

                    <Field label="BASE MODEL (HF ID)">
                        <TextInput value={formModelId} onSet={lambda (v: str) { formModelId = v; }} placeholder="org/model" mono={True} />
                    </Field>

                    <p className="stat-line text-muted-foreground">dataset · mlx train/valid splits from [cloudrun] workspace config (uploaded to the cluster as data/*.jsonl)</p>

                    <div className="grid grid-cols-3 gap-2">
                        {for key in ["lora_r", "lora_alpha", "lora_dropout", "max_steps", "lr", "per_device_batch_size", "grad_accum", "max_seq_len", "eval_every"] {
                            <Field key={str(key)} label={str(key).upper()}>
                                <TextInput value={str(cloudOpts[key]) if key in cloudOpts else ""} onSet={lambda (v: str) { updateOpt(str(key), v); }} placeholder={str(key)} mono={True} />
                            </Field>
                        }}
                    </div>

                    <div className="flex items-center gap-4">
                        <Field label="AUTO-RELEASE ON FINISH">
                            <button
                                onClick={lambda (e: MouseEvent) { autoTerm = not autoTerm; }}
                                className={"exp-hoverable rounded-lg border px-3 py-1 font-mono text-[10px] transition-colors " + (
                                    "border-ok bg-ok/10 text-ok" if autoTerm
                                    else "border-input text-muted-foreground"
                                )}
                            >
                                {"ON (release the box on finish)" if autoTerm else "OFF — leave the box as it is"}
                            </button>
                        </Field>
                        <Field label="MAX WALL CLOCK (MIN)">
                            <TextInput value={maxWall} onSet={lambda (v: str) { maxWall = v; }} placeholder="720" mono={True} />
                        </Field>
                    </div>

                    {hasSelCluster and <p className="stat-line text-muted-foreground">runs on {str(selCluster["label"])} ({_clusterAddr(selCluster)}) · supervisor uploads data + train_sft.py, monitors, pulls adapter</p>}

                    <div className="flex gap-2">
                        <button onClick={lambda (e: MouseEvent) { doStartRun(); }} disabled={busy or selClusterId == ""} className={btn + "text-foreground"}>▶ START REMOTE SFT</button>
                    </div>
                    {error and <p className="stat-line" style={{"color": "var(--danger)"}}>{error}</p>}
                </div>

                <div className="relative flex min-w-0 flex-1 flex-col gap-3 exp-panel p-4 pt-5">
                    <span className="micro-label absolute -top-2 left-3 bg-background px-2">RUN.STATUS</span>
                    {_runDetailPane()}
                </div>
            </div>

            <div className="relative exp-panel p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">CLOUD RUNS</span>
                {len(runs) == 0 and <span className="stat-line text-muted-foreground/80">no cloud runs yet</span>}
                <div className="flex flex-col gap-2">
                    {[_runRow({"run": rr}) for rr in runs if rr]}
                </div>
            </div>
        </div>;
    }

    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="flex items-center justify-between border-b border-border px-4 py-2.5">
            <SubTabs tabs={TABS} active={tab.upper()} onTab={onTab} />
            <span className="micro-label text-muted-foreground/80">BYO CLUSTER</span>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto">
            {tab == "clusters" and _clusters()}
            {tab == "runs" and _runs()}
        </div>
    </div>;
}
