"""CLOUD section — Spheron GPU deployments + supervised remote training runs.

INSTANCES: list / refresh / destroy (Spheron has no start/stop/reboot — only
terminate, so the lifecycle UI is just DESTROY, guarded by can-terminate).
RUNS: configure a remote SFT run (offer + base model + LoRA/steps opts), START
it — the server deploys a Spheron VM and spawns remote/supervisor.py detached,
which owns the run end-to-end (upload data → bootstrap → launch → monitor →
pull adapter → terminate VM). This tab polls the supervisor's status.json:
phase timeline, live train.log tail, cost line, and a loud billing alert when
the supervisor died while the VM may still be billing (REATTACH resumes it).
SETUP: per-user API key, SSH-key management, and account balance.
"""

import from react { useEffect }
sv import from ...spheron {
    spheron_status, spheron_credential_status, spheron_providers,
    set_spheron_key, clear_spheron_key,
    spheron_instances, spheron_instance, destroy_gpu_instance, can_terminate_gpu_instance,
    spheron_ssh_keys, add_spheron_ssh_key,
    search_gpus
}
sv import from ...cloudruns {
    start_remote_run, run_status, list_cloud_runs,
    stop_run, reattach_run, pull_artifacts, terminate_run_vm
}
import from ..shared.SubTabs { SubTabs }
import from ..shared.Field { Field, TextInput, Segmented }
import from ..shared.StatusGlyph { StatusGlyph }
import from ..shared.LogView { LogView }

glob TABS: list[str] = ["INSTANCES", "RUNS", "SETUP"];

# Supervisor phases → display chips (monitor shows as TRAIN).
glob PHASE_ORDER: list[str] = ["wait_vm", "provision", "launch", "monitor", "pull", "terminate"];
glob PHASE_LABELS: list[str] = ["WAIT VM", "PROVISION", "LAUNCH", "TRAIN", "PULL", "TERMINATE"];

def _instLabel(inst: any) -> str {
    did = str(inst["id"]) or "—";
    gpu = str(inst["gpu_name"]);
    state = str(inst["cur_state"]);
    return f"#{did} · {gpu} · {state}";
}

def _offerLabel(o: any) -> str {
    gpu = str(o["gpu_name"]);
    prov = str(o["provider"]);
    region = str(o["region"]);
    price = float(str(o["dph_total"]));
    itype = str(o["instance_type"]);
    return f"{gpu} · {prov} · {region} · ${price}/hr · {itype}";
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
    has tab: str = "instances";
    has cred: any = None;
    has account: any = None;
    has providers: list = [];
    has instances: list = [];
    has selInstance: str = "";
    has instDetail: any = None;
    has canTerm: any = None;
    # Offer search (RUNS deploys a fresh instance from a chosen offer).
    has offerQuery: str = "rtx-4090";
    has offerType: str = "DEDICATED";
    has offers: list = [];
    has selOfferId: str = "";
    has sshKeys: list = [];
    has selSshKeyId: str = "";
    # SSH-key upload form.
    has newKeyName: str = "";
    has newKeyBody: str = "";
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
    has confirmTerm: bool = False;
    has apiKey: str = "";
    has error: str = "";
    has busy: bool = False;

    async def _loadCred() -> None {
        try {
            cred = await spheron_credential_status();
        } except Exception {}
    }
    async def _loadAccount() -> None {
        try {
            account = await spheron_status();
        } except Exception {}
    }
    async def _loadProviders() -> None {
        try {
            r = await spheron_providers();
            if bool(r["ok"]) { providers = list(r["providers"]); }
        } except Exception {}
    }
    async def _loadInstances() -> None {
        try {
            r = await spheron_instances();
            if bool(r["ok"]) {
                instances = list(r["instances"]);
                if selInstance == "" and len(instances) > 0 {
                    selInstance = str(instances[0]["id"]);
                }
            }
        } except Exception {}
    }
    async def _loadSshKeys() -> None {
        try {
            r = await spheron_ssh_keys();
            if bool(r["ok"]) {
                sshKeys = list(r["keys"]);
                if selSshKeyId == "" and len(sshKeys) > 0 {
                    selSshKeyId = str(sshKeys[0]["id"]);
                }
            }
        } except Exception {}
    }
    async def _loadRuns() -> None {
        try {
            r = await list_cloud_runs();
            runs = list(r["runs"]);
            if selRunId == "" and len(runs) > 0 {
                selRunId = str(runs[0]["run_id"]);
            }
        } except Exception {}
    }
    async def _pollRun() -> None {
        if selRunId == "" { return; }
        try {
            r = await run_status(selRunId);
            if bool(r["ok"]) { runDetail = r["run"]; }
        } except Exception {}
    }
    async def _pollInstance() -> None {
        if selInstance == "" { return; }
        try {
            r = await spheron_instance(selInstance);
            if bool(r["ok"]) { instDetail = r["instance"]; }
        } except Exception {}
        try {
            ct = await can_terminate_gpu_instance(selInstance);
            canTerm = ct if bool(ct["ok"]) else None;
        } except Exception {
            canTerm = None;
        }
    }
    async def _runSearch() -> None {
        busy = True;
        error = "";
        try {
            r = await search_gpus(search=offerQuery, instance_type=offerType, limit=12);
            if bool(r["ok"]) {
                offers = list(r["offers"]);
                if selOfferId == "" and len(offers) > 0 {
                    selOfferId = str(offers[0]["id"]);
                }
            } else {
                error = str(r["error"]);
            }
        } except Exception {
            error = "search failed";
        }
        busy = False;
    }

    useEffect(lambda {
        if active {
            _loadCred(); _loadAccount(); _loadProviders(); _loadSshKeys();
        }
    }, [active]);

    useEffect(lambda {
        iv: any = None;
        if active and tab == "instances" {
            _loadInstances();
            iv = setInterval(lambda { _loadInstances(); }, 8000);
        }
        return lambda { if iv is not None { clearInterval(float(str(iv))); } };
    }, [active, tab]);

    useEffect(lambda {
        iv: any = None;
        if active and tab == "instances" and selInstance != "" {
            _pollInstance();
            iv = setInterval(lambda { _pollInstance(); }, 5000);
        }
        return lambda { if iv is not None { clearInterval(float(str(iv))); } };
    }, [active, tab, selInstance]);

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

    def onTab(t: str) -> None { tab = t.lower(); }
    def pickInstance(did: str) -> None { selInstance = did; instDetail = None; canTerm = None; }
    def pickOffer(oid: str) -> None { selOfferId = oid; }
    def pickSshKey(kid: str) -> None { selSshKeyId = kid; }
    def pickRun(rid: str) -> None { selRunId = rid; runDetail = None; confirmTerm = False; }
    def updateOpt(key: str, value: str) -> None {
        updated: dict = {**cloudOpts};
        updated[key] = value;
        cloudOpts = updated;
    }

    def _selectedOffer() -> dict {
        for o in offers {
            if str(o["id"]) == selOfferId { return {**o}; }
        }
        return {};
    }

    async def doSaveKey() -> None {
        if not apiKey.strip() { error = "enter an API key"; return; }
        busy = True;
        error = "";
        try {
            await set_spheron_key(apiKey.strip());
            apiKey = "";
            await _loadCred();
            await _loadAccount();
        } except Exception {
            error = "key save failed";
        }
        busy = False;
    }
    async def doClearKey() -> None {
        busy = True;
        try {
            await clear_spheron_key();
            await _loadCred();
            await _loadAccount();
        } except Exception {}
        busy = False;
    }
    async def doAddSshKey() -> None {
        if not newKeyName.strip() or not newKeyBody.strip() {
            error = "name and public key required";
            return;
        }
        busy = True;
        error = "";
        try {
            r = await add_spheron_ssh_key(newKeyName.strip(), newKeyBody.strip());
            if bool(r["ok"]) {
                newKeyName = "";
                newKeyBody = "";
                await _loadSshKeys();
            } else {
                error = str(r["error"]);
            }
        } except Exception {
            error = "ssh key add failed";
        }
        busy = False;
    }
    async def doDestroy() -> None {
        if selInstance == "" { return; }
        busy = True;
        error = "";
        try {
            r = await destroy_gpu_instance(selInstance);
            if not bool(r["ok"]) { error = str(r["error"]); }
            await _loadInstances();
            await _pollInstance();
        } except Exception {
            error = "destroy failed";
        }
        busy = False;
    }
    async def doStartRun() -> None {
        if selOfferId == "" { error = "search and pick an offer first"; return; }
        if selSshKeyId == "" { error = "add/select an SSH key in SETUP first"; return; }
        offer = _selectedOffer();
        if len(offer) == 0 { error = "offer not found"; return; }
        os_options = list(offer["os_options"]) if "os_options" in offer else [];
        operating_system = str(os_options[0]) if len(os_options) > 0 else "ubuntu22.04";
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
                "offer": {
                    "offer_id": str(offer["id"]),
                    "gpu_type": str(offer["gpu_type"]),
                    "gpu_count": int(str(offer["num_gpus"])),
                    "region": str(offer["region"]),
                    "os": operating_system,
                    "instance_type": str(offer["instance_type"]),
                    "hourly_rate": float(str(offer["dph_total"])),
                    "provider": str(offer["provider"])
                },
                "ssh_key_id": selSshKeyId,
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
    async def doStopRun() -> None {
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
    async def doReattach() -> None {
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
    async def doPull() -> None {
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
    async def doTerminateVm() -> None {
        if selRunId == "" { return; }
        if not confirmTerm { confirmTerm = True; return; }
        confirmTerm = False;
        busy = True;
        error = "";
        try {
            r = await terminate_run_vm(selRunId);
            if bool(r["ok"]) {
                runDetail = r["run"];
                await _loadRuns();
            } else {
                error = str(r["error"]);
            }
        } except Exception {
            error = "terminate failed";
        }
        busy = False;
    }

    def _setup() -> JsxElement {
        configured = bool(cred) and bool(cred["configured"]);
        source = str(cred["source"]) if cred else "none";
        acctOk = bool(account) and bool(account["ok"]);
        btn = "exp-btn ";
        return <div className="flex flex-col gap-4 p-4">
            <div className="relative exp-panel p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">CREDENTIALS</span>
                <div className="flex flex-wrap items-center gap-3">
                    <StatusGlyph status={"running" if acctOk else "idle"} showLabel={True} />
                    <span className="font-mono text-[11px] text-muted-foreground">source · {source}</span>
                    {acctOk and bool(account) and <span className="font-mono text-[11px] text-muted-foreground">
                        balance ${str(account["balance"])} · {str(account["team_name"])}
                    </span>}
                </div>
                {len(providers) > 0 and <p className="stat-line mt-2 text-muted-foreground">providers · {", ".join([str(p) for p in providers])}</p>}
                {not configured and <p className="stat-line mt-2 text-muted-foreground">set SPHERON_API_KEY in the environment or paste a per-user key below</p>}
            </div>

            <div className="relative exp-panel p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">API KEY</span>
                <Field label="SPHERON API KEY">
                    <TextInput value={apiKey} onSet={lambda (v: str) { apiKey = v; }} placeholder="paste key (never echoed back)" mono={True} />
                </Field>
                <div className="mt-3 flex gap-2">
                    <button onClick={lambda (e: MouseEvent) { doSaveKey(); }} disabled={busy} className={btn + "text-foreground"}>SAVE KEY</button>
                    <button onClick={lambda (e: MouseEvent) { doClearKey(); }} disabled={busy} className={btn + "text-muted-foreground"}>CLEAR USER KEY</button>
                </div>
            </div>

            <div className="relative exp-panel p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">SSH KEYS</span>
                <p className="stat-line text-muted-foreground">required to deploy — add your public key once, then reuse it</p>
                <div className="mt-2 flex flex-col gap-1">
                    {len(sshKeys) == 0 and <span className="stat-line text-muted-foreground/80">no keys uploaded</span>}
                    {for k in sshKeys {
                        kid = str(k["id"]);
                        <button
                            key={kid}
                            onClick={lambda (e: MouseEvent) { pickSshKey(kid); }}
                            className={"exp-hoverable rounded-lg border px-3 py-1 text-left font-mono text-xs transition-colors " + (
                                "border-accent bg-accent/15 text-foreground" if selSshKeyId == kid
                                else "border-border text-muted-foreground hover:border-input"
                            )}
                        >
                            {str(k["name"])} · {str(k["fingerprint"])}
                        </button>
                    }}
                </div>
                <div className="mt-3 flex flex-col gap-2">
                    <Field label="NAME">
                        <TextInput value={newKeyName} onSet={lambda (v: str) { newKeyName = v; }} placeholder="studio-key" mono={True} />
                    </Field>
                    <Field label="PUBLIC KEY">
                        <TextInput value={newKeyBody} onSet={lambda (v: str) { newKeyBody = v; }} placeholder="ssh-ed25519 AAAA... user@host" mono={True} />
                    </Field>
                    <button onClick={lambda (e: MouseEvent) { doAddSshKey(); }} disabled={busy} className={btn + "text-foreground"}>ADD KEY</button>
                </div>
            </div>
            {error and <p className="stat-line text-muted-foreground">{error}</p>}
        </div>;
    }

    def _instances() -> JsxElement {
        btn = "exp-btn ";
        termBlocked = bool(canTerm) and not bool(canTerm["can_terminate"]);
        return <div className="flex items-start gap-4 p-4 pt-5">
            <div className="relative flex min-w-0 flex-1 flex-col gap-3 exp-panel p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">YOUR DEPLOYMENTS</span>
                {len(instances) == 0 and <span className="stat-line text-muted-foreground/80">no deployments · start a run from the RUNS tab</span>}
                <div className="flex flex-col gap-1">
                    {for inst in instances {
                        did = str(inst["id"]);
                        <button
                            key={did}
                            onClick={lambda (e: MouseEvent) { pickInstance(did); }}
                            className={"exp-hoverable rounded-lg border px-3 py-2 text-left font-mono text-xs transition-colors " + (
                                "border-accent bg-accent/15 text-foreground" if selInstance == did
                                else "border-border text-muted-foreground hover:border-input"
                            )}
                        >
                            {_instLabel(inst)}
                        </button>
                    }}
                </div>
            </div>

            <div className="relative flex min-w-0 flex-1 flex-col gap-3 exp-panel p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">DEPLOYMENT DETAIL</span>
                {selInstance == "" and <span className="stat-line text-muted-foreground/80">select a deployment</span>}
                {selInstance != "" and bool(instDetail) and <>
                    <StatusGlyph status={str(instDetail["cur_state"])} showLabel={True} />
                    <span className="font-mono text-[11px] text-muted-foreground">os · {str(instDetail["image"])}</span>
                    <span className="font-mono text-[11px] text-muted-foreground">hourly · ${str(instDetail["dph_total"])}</span>
                    {str(instDetail["ssh_addr"]) and <span className="font-mono text-[11px] text-muted-foreground break-all">ssh · {str(instDetail["ssh_addr"])}</span>}
                    {termBlocked and bool(canTerm) and <span className="font-mono text-[11px] text-muted-foreground">min runtime · {str(canTerm["time_remaining"])}s remaining</span>}
                    <div className="mt-2 flex flex-wrap gap-2">
                        <button onClick={lambda (e: MouseEvent) { doDestroy(); }} disabled={busy or termBlocked} className={btn + "text-muted-foreground"}>✕ TERMINATE</button>
                    </div>
                </>}
            </div>
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
                    cls += "border-red-800 bg-[#1a0505] text-red-400" if failed
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
        if status == "running" { dotCls += "bg-emerald-500"; }
        elif status == "done" { dotCls += "bg-foreground"; }
        elif status == "detached" or status == "failed" { dotCls += "bg-red-500"; }
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
                {alert and <span className="rounded border border-red-800 bg-[#1a0505] px-1.5 font-mono text-[9px] text-red-400">BILLING?</span>}
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
        prog: dict = {**run["progress"]};
        step = str(prog["step"]) if "step" in prog else "0";
        maxSteps = str(prog["max_steps"]) if "max_steps" in prog else "0";
        loss = str(prog["loss"]) if "loss" in prog and prog["loss"] is not None else "—";
        evalLoss = str(prog["eval_loss"]) if "eval_loss" in prog and prog["eval_loss"] is not None else "—";
        art: dict = {**run["artifacts"]};
        pulled = bool(art["pulled"]) if "pulled" in art else False;
        adapterDir = str(art["adapter_dir"]) if "adapter_dir" in art else "";
        isTerminal = status == "done" or status == "failed" or status == "stopped";
        return <>
            {alert and <div className="rounded-md border border-red-800 bg-[#1a0505] p-3">
                <p className="font-mono text-[11px] font-bold text-red-400">DETACHED — VM MAY STILL BE BILLING</p>
                <p className="stat-line mt-1 text-red-500">supervisor died with the run non-terminal · reattach to resume, or terminate the VM</p>
                <button onClick={lambda (e: MouseEvent) { doReattach(); }} disabled={busy} className={btn + "mt-2 border-red-800 text-red-300"}>↻ REATTACH</button>
            </div>}
            <div className="flex items-center gap-3">
                <StatusGlyph status={"failed" if status == "detached" else status} showLabel={True} />
                <span className="font-mono text-[11px] text-muted-foreground">{str(run["name"])} · {str(run["mode"])} · dep {str(run["deployment_id"])}</span>
            </div>
            {_phaseChips({"run": run})}
            <span className="font-mono text-[11px] text-muted-foreground">{_costLine(run)}{" · vm terminated" if bool(run["vm_terminated"]) else ""}</span>
            <span className="font-mono text-[11px] text-muted-foreground">step {step}/{maxSteps} · loss {loss} · eval {evalLoss}</span>
            {str(run["message"]) and <span className="font-mono text-[11px] text-muted-foreground">{str(run["message"])}</span>}
            {str(run["error"]) and <span className="font-mono text-[11px] text-red-400">{str(run["error"])}</span>}
            <LogView text={str(run["log_tail"]) or "no train.log yet"} maxH="14rem" />
            <div className="flex flex-wrap gap-2">
                <button onClick={lambda (e: MouseEvent) { doStopRun(); }} disabled={busy or isTerminal or detached} className={btn + "text-muted-foreground"}>■ STOP</button>
                <button onClick={lambda (e: MouseEvent) { doTerminateVm(); }} disabled={busy or bool(run["vm_terminated"])} className={btn + ("border-red-800 text-red-300" if confirmTerm else "text-muted-foreground")}>
                    {"⚠ CONFIRM TERMINATE VM?" if confirmTerm else "✕ TERMINATE VM"}
                </button>
                {isTerminal and not pulled and <button onClick={lambda (e: MouseEvent) { doPull(); }} disabled={busy} className={btn + "text-foreground"}>⇩ PULL ARTIFACTS</button>}
            </div>
            {pulled and adapterDir and <span className="font-mono text-[11px] text-muted-foreground break-all">adapter · {adapterDir}</span>}
        </>;
    }

    def _runs() -> JsxElement {
        btn = "exp-btn ";
        selOffer = _selectedOffer();
        return <div className="flex flex-col gap-4 p-4">
            <div className="flex items-start gap-4">
                <div className="relative flex min-w-0 flex-1 flex-col gap-3 exp-panel p-4 pt-5">
                    <span className="micro-label absolute -top-2 left-3 bg-background px-2">RUN.CONFIG</span>

                    <Field label="OFFER SEARCH">
                        <div className="flex gap-2">
                            <TextInput value={offerQuery} onSet={lambda (v: str) { offerQuery = v; }} placeholder="rtx-4090" mono={True} />
                            <Segmented options={["DEDICATED", "SPOT", "CLUSTER"]} value={offerType} onSet={lambda (v: str) { offerType = v; }} />
                            <button onClick={lambda (e: MouseEvent) { _runSearch(); }} disabled={busy} className={btn + "text-foreground"}>SEARCH</button>
                        </div>
                    </Field>

                    {len(offers) > 0 and <Field label="OFFER">
                        <div className="flex flex-col gap-1">
                            {for o in offers {
                                oid = str(o["id"]);
                                <button
                                    key={oid}
                                    onClick={lambda (e: MouseEvent) { pickOffer(oid); }}
                                    className={"exp-hoverable rounded-lg border px-3 py-1 font-mono text-xs transition-colors " + (
                                        "border-accent bg-accent/15 text-foreground" if selOfferId == oid
                                        else "border-input text-muted-foreground hover:text-foreground/80"
                                    )}
                                >
                                    {_offerLabel(o)}
                                </button>
                            }}
                        </div>
                    </Field>}
                    {len(offers) == 0 and <p className="stat-line text-muted-foreground/80">search to load offers, then pick one</p>}

                    <Field label="SSH KEY">
                        <div className="flex flex-col gap-1">
                            {len(sshKeys) == 0 and <span className="stat-line text-muted-foreground/80">no keys — add one in SETUP</span>}
                            {for k in sshKeys {
                                kid = str(k["id"]);
                                <button
                                    key={kid}
                                    onClick={lambda (e: MouseEvent) { pickSshKey(kid); }}
                                    className={"exp-hoverable rounded-lg border px-3 py-1 font-mono text-xs transition-colors " + (
                                        "border-accent bg-accent/15 text-foreground" if selSshKeyId == kid
                                        else "border-input text-muted-foreground hover:text-foreground/80"
                                    )}
                                >
                                    {str(k["name"])}
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

                    <p className="stat-line text-muted-foreground">dataset · mlx train/valid splits from [cloudrun] workspace config (uploaded to the VM as data/*.jsonl)</p>

                    <div className="grid grid-cols-3 gap-2">
                        {for key in ["lora_r", "lora_alpha", "lora_dropout", "max_steps", "lr", "per_device_batch_size", "grad_accum", "max_seq_len", "eval_every"] {
                            <Field key={str(key)} label={str(key).upper()}>
                                <TextInput value={str(cloudOpts[key]) if key in cloudOpts else ""} onSet={lambda (v: str) { updateOpt(str(key), v); }} placeholder={str(key)} mono={True} />
                            </Field>
                        }}
                    </div>

                    <div className="flex items-center gap-4">
                        <Field label="AUTO-TERMINATE VM">
                            <button
                                onClick={lambda (e: MouseEvent) { autoTerm = not autoTerm; }}
                                className={"exp-hoverable rounded-lg border px-3 py-1 font-mono text-[10px] transition-colors " + (
                                    "border-emerald-700 bg-[#0a1a0f] text-emerald-400" if autoTerm
                                    else "border-red-800 bg-[#1a0505] text-red-400"
                                )}
                            >
                                {"ON (terminate on finish)" if autoTerm else "OFF — VM stays up + billing"}
                            </button>
                        </Field>
                        <Field label="MAX WALL CLOCK (MIN)">
                            <TextInput value={maxWall} onSet={lambda (v: str) { maxWall = v; }} placeholder="720" mono={True} />
                        </Field>
                    </div>

                    {len(selOffer) > 0 and <p className="stat-line text-muted-foreground">deploys {_offerLabel(selOffer)} · supervisor uploads data + train_sft.py, monitors, pulls adapter</p>}

                    <div className="flex gap-2">
                        <button onClick={lambda (e: MouseEvent) { doStartRun(); }} disabled={busy or selOfferId == "" or selSshKeyId == ""} className={btn + "text-foreground"}>▶ START REMOTE SFT</button>
                    </div>
                    {error and <p className="stat-line text-muted-foreground">{error}</p>}
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
            <span className="micro-label text-muted-foreground/80">SPHERON</span>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto">
            {tab == "instances" and _instances()}
            {tab == "runs" and _runs()}
            {tab == "setup" and _setup()}
        </div>
    </div>;
}
