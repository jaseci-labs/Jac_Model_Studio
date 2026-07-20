"""CLOUD section — Spheron GPU deployments + dispatch training jobs via cloud-init.

INSTANCES: list / refresh / destroy (Spheron has no start/stop/reboot — only
terminate, so the lifecycle UI is just DESTROY, guarded by can-terminate).
DISPATCH: search an offer, pick an SSH key, configure a training job, then
deploy a fresh instance with the rendered command baked into cloudInit.runcmd
(Spheron exposes no exec/logs API, so a dispatch IS a new deployment; poll the
deployment status and SSH in to inspect job output).
SETUP: per-user API key, SSH-key management, and account balance.
"""

import from react { useEffect }
sv import from ...spheron {
    spheron_status, spheron_credential_status, spheron_providers,
    set_spheron_key, clear_spheron_key,
    spheron_instances, spheron_instance, destroy_gpu_instance, can_terminate_gpu_instance,
    spheron_ssh_keys, add_spheron_ssh_key,
    search_gpus,
    dispatch_training_job, list_spheron_dispatches, get_spheron_dispatch, stop_spheron_dispatch
}
sv import from ...backends { list_backends }
import from ..shared.SubTabs { SubTabs }
import from ..shared.Field { Field, TextInput, Segmented }
import from ..shared.StatusGlyph { StatusGlyph }
import from ..shared.LogView { LogView }

glob TABS: list[str] = ["INSTANCES", "DISPATCH", "SETUP"];

def _availBackends(backends: list, mode: str) -> list {
    out: list = [];
    for b in backends {
        for m in list(b["methods"]) {
            if str(m) == mode {
                out.append(b);
                break;
            }
        }
    }
    return out;
}

def _optKeysFor(backends: list, backendId: str, mode: str) -> list {
    for b in backends {
        if str(b["id"]) != backendId { continue; }
        details = b.get("method_details");
        if not isinstance(details, dict) { return []; }
        md = details.get(mode);
        if not isinstance(md, dict) { return []; }
        raw = md.get("env_keys");
        if isinstance(raw, list) { return [str(k) for k in (raw as list)]; }
    }
    return [];
}

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

def:pub Cloud(active: bool) -> JsxElement {
    has tab: str = "instances";
    has cred: any = None;
    has account: any = None;
    has providers: list = [];
    has instances: list = [];
    has selInstance: str = "";
    has instDetail: any = None;
    has canTerm: any = None;
    has backends: list = [];
    has dispatches: list = [];
    has selDispatch: str = "";
    has dispatchDetail: any = None;
    # Offer search (DISPATCH deploys a fresh instance from a chosen offer).
    has offerQuery: str = "rtx-4090";
    has offerType: str = "DEDICATED";
    has offers: list = [];
    has selOfferId: str = "";
    has sshKeys: list = [];
    has selSshKeyId: str = "";
    # SSH-key upload form.
    has newKeyName: str = "";
    has newKeyBody: str = "";
    # Dispatch job form.
    has formName: str = "qwen-cloud";
    has formMode: str = "sft";
    has formModelId: str = "Qwen/Qwen3-Coder-30B-A3B-Instruct";
    has formBackend: str = "spheron_gpu";
    has opts: dict = {
        "EVAL_EVERY": "60", "SUBSET": "50",
        "DPO_ITERS": "200", "DPO_LR": "1e-6"
    };
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
    async def _loadBackends() -> None {
        try {
            r = await list_backends();
            backends = list(r["backends"]);
            for b in backends {
                if str(b["id"]) == "spheron_gpu" {
                    formBackend = "spheron_gpu";
                    break;
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
    async def _loadDispatches() -> None {
        try {
            r = await list_spheron_dispatches();
            dispatches = list(r["dispatches"]);
            if selDispatch == "" and len(dispatches) > 0 {
                selDispatch = str(dispatches[0]["id"]);
            }
        } except Exception {}
    }
    async def _pollDispatch() -> None {
        if selDispatch == "" { return; }
        try {
            r = await get_spheron_dispatch(selDispatch);
            if bool(r["ok"]) { dispatchDetail = r["dispatch"]; }
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
            _loadCred(); _loadAccount(); _loadBackends(); _loadProviders(); _loadSshKeys();
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
        if active and tab == "dispatch" {
            _loadDispatches();
            iv = setInterval(lambda { _loadDispatches(); }, 4000);
        }
        return lambda { if iv is not None { clearInterval(float(str(iv))); } };
    }, [active, tab]);

    useEffect(lambda {
        iv: any = None;
        if active and tab == "dispatch" and selDispatch != "" {
            _pollDispatch();
            iv = setInterval(lambda { _pollDispatch(); }, 3000);
        }
        return lambda { if iv is not None { clearInterval(float(str(iv))); } };
    }, [active, tab, selDispatch]);

    useEffect(lambda {
        avail = _availBackends(backends, formMode);
        if len(avail) == 0 { return; }
        ok = False;
        for b in avail {
            if str(b["id"]) == formBackend { ok = True; break; }
        }
        if not ok { formBackend = str(avail[0]["id"]); }
    }, [formMode, backends]);

    def onTab(t: str) -> None { tab = t.lower(); }
    def pickInstance(did: str) -> None { selInstance = did; instDetail = None; canTerm = None; }
    def pickDispatch(did: str) -> None { selDispatch = did; dispatchDetail = None; }
    def pickOffer(oid: str) -> None { selOfferId = oid; }
    def pickSshKey(kid: str) -> None { selSshKeyId = kid; }
    def updateOpt(key: str, value: str) -> None { opts = {**opts, key: value}; }

    def _selectedOffer() -> dict {
        for o in offers {
            if str(o["id"]) == selOfferId { return dict(o); }
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
    async def doDispatch() -> None {
        if selOfferId == "" { error = "search and pick an offer first"; return; }
        if selSshKeyId == "" { error = "add/select an SSH key in SETUP first"; return; }
        keys = _optKeysFor(backends, formBackend, formMode);
        filtered: dict = {};
        for k in keys {
            if k in opts { filtered[k] = str(opts[k]); }
        }
        mid = formModelId if formMode == "sft" else "";
        offer = _selectedOffer();
        if len(offer) == 0 { error = "offer not found"; return; }
        os_options = list(offer["os_options"]) if "os_options" in offer else [];
        operating_system = str(os_options[0]) if len(os_options) > 0 else "ubuntu-22.04";
        busy = True;
        error = "";
        try {
            r = await dispatch_training_job(
                offer_id=str(offer["id"]),
                gpu_type=str(offer["gpu_type"]),
                gpu_count=int(str(offer["num_gpus"])),
                region=str(offer["region"]),
                operating_system=operating_system,
                instance_type=str(offer["instance_type"]),
                hourly_rate=float(str(offer["dph_total"])),
                name=formName, mode=formMode,
                ssh_key_id=selSshKeyId,
                model_id=mid, opts=filtered, backend=formBackend,
                provider=str(offer["provider"])
            );
            if bool(r["ok"]) {
                dispatchDetail = r["dispatch"];
                selDispatch = str(r["dispatch"]["id"]);
                await _loadDispatches();
            } else {
                error = str(r["error"]);
            }
        } except Exception {
            error = "dispatch failed";
        }
        busy = False;
    }
    async def doStopDispatch() -> None {
        if selDispatch == "" { return; }
        busy = True;
        try {
            r = await stop_spheron_dispatch(selDispatch);
            if bool(r["ok"]) {
                dispatchDetail = r["dispatch"];
                await _loadDispatches();
            } else {
                error = str(r["error"]);
            }
        } except Exception {
            error = "stop failed";
        }
        busy = False;
    }

    def _setup() -> JsxElement {
        configured = cred is not None and bool(cred["configured"]);
        source = str(cred["source"]) if cred is not None else "none";
        acctOk = account is not None and bool(account["ok"]);
        btn = "rounded-lg border border-neutral-600 px-3 py-1 font-mono text-[10px] transition-colors hover:border-neutral-400 disabled:opacity-30 ";
        return <div className="flex flex-col gap-4 p-4">
            <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">CREDENTIALS</span>
                <div className="flex flex-wrap items-center gap-3">
                    <StatusGlyph status={"running" if acctOk else "idle"} showLabel={True} />
                    <span className="font-mono text-[11px] text-neutral-500">source · {source}</span>
                    {acctOk and account is not None and <span className="font-mono text-[11px] text-neutral-500">
                        balance ${str(account["balance"])} · {str(account["team_name"])}
                    </span>}
                </div>
                {len(providers) > 0 and <p className="stat-line mt-2 text-neutral-500">providers · {", ".join([str(p) for p in providers])}</p>}
                {not configured and <p className="stat-line mt-2 text-neutral-500">set SPHERON_API_KEY in the environment or paste a per-user key below</p>}
            </div>

            <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">API KEY</span>
                <Field label="SPHERON API KEY">
                    <TextInput value={apiKey} onSet={lambda v: str { apiKey = v; }} placeholder="paste key (never echoed back)" mono={True} />
                </Field>
                <div className="mt-3 flex gap-2">
                    <button onClick={lambda e: MouseEvent { doSaveKey(); }} disabled={busy} className={btn + "text-neutral-100"}>SAVE KEY</button>
                    <button onClick={lambda e: MouseEvent { doClearKey(); }} disabled={busy} className={btn + "text-neutral-400"}>CLEAR USER KEY</button>
                </div>
            </div>

            <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">SSH KEYS</span>
                <p className="stat-line text-neutral-500">required to deploy — add your public key once, then reuse it</p>
                <div className="mt-2 flex flex-col gap-1">
                    {len(sshKeys) == 0 and <span className="stat-line text-neutral-600">no keys uploaded</span>}
                    {for k in sshKeys {
                        kid = str(k["id"]);
                        <button
                            key={kid}
                            onClick={lambda e: MouseEvent { pickSshKey(kid); }}
                            className={"rounded-md border px-3 py-1 text-left font-mono text-xs transition-colors " + (
                                "border-neutral-500 bg-[#1a1a1a] text-neutral-100" if selSshKeyId == kid
                                else "border-neutral-800 text-neutral-400 hover:border-neutral-600"
                            )}
                        >
                            {str(k["name"])} · {str(k["fingerprint"])}
                        </button>
                    }}
                </div>
                <div className="mt-3 flex flex-col gap-2">
                    <Field label="NAME">
                        <TextInput value={newKeyName} onSet={lambda v: str { newKeyName = v; }} placeholder="studio-key" mono={True} />
                    </Field>
                    <Field label="PUBLIC KEY">
                        <TextInput value={newKeyBody} onSet={lambda v: str { newKeyBody = v; }} placeholder="ssh-ed25519 AAAA... user@host" mono={True} />
                    </Field>
                    <button onClick={lambda e: MouseEvent { doAddSshKey(); }} disabled={busy} className={btn + "text-neutral-100"}>ADD KEY</button>
                </div>
            </div>
            {error and <p className="stat-line text-neutral-400">{error}</p>}
        </div>;
    }

    def _instances() -> JsxElement {
        btn = "rounded-lg border border-neutral-600 px-3 py-1 font-mono text-[10px] transition-colors hover:border-neutral-400 disabled:opacity-30 ";
        termBlocked = canTerm is not None and not bool(canTerm["can_terminate"]);
        return <div className="flex items-start gap-4 p-4 pt-5">
            <div className="relative flex min-w-0 flex-1 flex-col gap-3 rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">YOUR DEPLOYMENTS</span>
                {len(instances) == 0 and <span className="stat-line text-neutral-600">no deployments · deploy one from the DISPATCH tab</span>}
                <div className="flex flex-col gap-1">
                    {for inst in instances {
                        did = str(inst["id"]);
                        <button
                            key={did}
                            onClick={lambda e: MouseEvent { pickInstance(did); }}
                            className={"rounded-md border px-3 py-2 text-left font-mono text-xs transition-colors " + (
                                "border-neutral-500 bg-[#1a1a1a] text-neutral-100" if selInstance == did
                                else "border-neutral-800 text-neutral-400 hover:border-neutral-600"
                            )}
                        >
                            {_instLabel(inst)}
                        </button>
                    }}
                </div>
            </div>

            <div className="relative flex min-w-0 flex-1 flex-col gap-3 rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">DEPLOYMENT DETAIL</span>
                {selInstance == "" and <span className="stat-line text-neutral-600">select a deployment</span>}
                {selInstance != "" and instDetail is not None and <>
                    <StatusGlyph status={str(instDetail["cur_state"])} showLabel={True} />
                    <span className="font-mono text-[11px] text-neutral-500">os · {str(instDetail["image"])}</span>
                    <span className="font-mono text-[11px] text-neutral-500">hourly · ${str(instDetail["dph_total"])}</span>
                    {str(instDetail["ssh_addr"]) and <span className="font-mono text-[11px] text-neutral-500 break-all">ssh · {str(instDetail["ssh_addr"])}</span>}
                    {termBlocked and canTerm is not None and <span className="font-mono text-[11px] text-neutral-500">min runtime · {str(canTerm["time_remaining"])}s remaining</span>}
                    <div className="mt-2 flex flex-wrap gap-2">
                        <button onClick={lambda e: MouseEvent { doDestroy(); }} disabled={busy or termBlocked} className={btn + "text-neutral-400"}>✕ TERMINATE</button>
                    </div>
                </>}
            </div>
        </div>;
    }

    def _dispatch() -> JsxElement {
        optKeys = _optKeysFor(backends, formBackend, formMode);
        availBackends = _availBackends(backends, formMode);
        btn = "rounded-lg border border-neutral-600 px-3 py-1 font-mono text-[10px] transition-colors hover:border-neutral-400 disabled:opacity-30 ";
        isRunning = dispatchDetail is not None and str(dispatchDetail["status"]) == "running";
        selOffer = _selectedOffer();
        return <div className="flex flex-col gap-4 p-4">
            <div className="flex items-start gap-4">
                <div className="relative flex min-w-0 flex-1 flex-col gap-3 rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
                    <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">DISPATCH.CONFIG</span>

                    <Field label="OFFER SEARCH">
                        <div className="flex gap-2">
                            <TextInput value={offerQuery} onSet={lambda v: str { offerQuery = v; }} placeholder="rtx-4090" mono={True} />
                            <Segmented options={["DEDICATED", "SPOT", "CLUSTER"]} value={offerType} onSet={lambda v: str { offerType = v; }} />
                            <button onClick={lambda e: MouseEvent { _runSearch(); }} disabled={busy} className={btn + "text-neutral-100"}>SEARCH</button>
                        </div>
                    </Field>

                    {len(offers) > 0 and <Field label="OFFER">
                        <div className="flex flex-col gap-1">
                            {for o in offers {
                                oid = str(o["id"]);
                                <button
                                    key={oid}
                                    onClick={lambda e: MouseEvent { pickOffer(oid); }}
                                    className={"rounded-md border px-3 py-1 font-mono text-xs transition-colors " + (
                                        "border-neutral-500 bg-[#1a1a1a] text-neutral-100" if selOfferId == oid
                                        else "border-neutral-700 text-neutral-500 hover:text-neutral-300"
                                    )}
                                >
                                    {_offerLabel(o)}
                                </button>
                            }}
                        </div>
                    </Field>}

                    {len(offers) == 0 and <p className="stat-line text-neutral-600">search to load offers, then pick one</p>}

                    <Field label="SSH KEY">
                        <div className="flex flex-col gap-1">
                            {len(sshKeys) == 0 and <span className="stat-line text-neutral-600">no keys — add one in SETUP</span>}
                            {for k in sshKeys {
                                kid = str(k["id"]);
                                <button
                                    key={kid}
                                    onClick={lambda e: MouseEvent { pickSshKey(kid); }}
                                    className={"rounded-md border px-3 py-1 font-mono text-xs transition-colors " + (
                                        "border-neutral-500 bg-[#1a1a1a] text-neutral-100" if selSshKeyId == kid
                                        else "border-neutral-700 text-neutral-500 hover:text-neutral-300"
                                    )}
                                >
                                    {str(k["name"])}
                                </button>
                            }}
                        </div>
                    </Field>

                    {len(availBackends) > 0 and <Field label="BACKEND">
                        <div className="flex flex-wrap gap-1">
                            {for b in availBackends {
                                bid = str(b["id"]);
                                <button
                                    key={bid}
                                    onClick={lambda e: MouseEvent { formBackend = bid; }}
                                    className={"rounded-md border px-3 py-1 text-xs transition-colors " + (
                                        "border-neutral-500 bg-[#1a1a1a] text-neutral-100" if formBackend == bid
                                        else "border-neutral-700 text-neutral-500 hover:text-neutral-300"
                                    )}
                                >
                                    {str(b["label"])}
                                </button>
                            }}
                        </div>
                    </Field>}

                    {formMode == "sft" and <Field label="BASE MODEL (HF ID)">
                        <TextInput value={formModelId} onSet={lambda v: str { formModelId = v; }} placeholder="org/model" mono={True} />
                    </Field>}

                    <Field label="SHORT NAME">
                        <TextInput value={formName} onSet={lambda v: str { formName = v; }} placeholder="qwen-cloud" mono={True} />
                    </Field>

                    <Field label="MODE">
                        <Segmented options={["sft", "dpo"]} value={formMode} onSet={lambda v: str { formMode = v; }} />
                    </Field>

                    {for key in optKeys {
                        <Field key={key} label={str(key)}>
                            <TextInput value={str(opts[key]) if key in opts else ""} onSet={lambda v: str { updateOpt(str(key), v); }} placeholder={str(key)} mono={True} />
                        </Field>
                    }}

                    {len(selOffer) > 0 and <p className="stat-line text-neutral-500">deploys {_offerLabel(selOffer)} via cloud-init runcmd</p>}
                    <p className="stat-line text-neutral-500">renders via backends.render → cloudInit.runcmd on a fresh instance</p>

                    <div className="flex gap-2">
                        <button onClick={lambda e: MouseEvent { doDispatch(); }} disabled={busy or selOfferId == "" or selSshKeyId == ""} className={btn + "text-neutral-100"}>▶ DISPATCH {formMode.upper()}</button>
                        <button onClick={lambda e: MouseEvent { doStopDispatch(); }} disabled={busy or not isRunning} className={btn + "text-neutral-400"}>■ TERMINATE DEPLOYMENT</button>
                    </div>
                    {error and <p className="stat-line text-neutral-400">{error}</p>}
                </div>

                <div className="relative flex min-w-0 flex-1 flex-col gap-3 rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
                    <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">DISPATCH.STATUS</span>
                    {dispatchDetail is None and <span className="stat-line text-neutral-600">dispatch a job to see status</span>}
                    {dispatchDetail is not None and <>
                        <StatusGlyph status={str(dispatchDetail["status"])} showLabel={True} />
                        <span className="font-mono text-[11px] text-neutral-500">deployment {str(dispatchDetail["deployment_id"])} · {str(dispatchDetail["name"])} · {str(dispatchDetail["mode"])}</span>
                        {str(dispatchDetail["message"]) and <span className="font-mono text-[11px] text-neutral-500">{str(dispatchDetail["message"])}</span>}
                        <span className="font-mono text-[11px] text-neutral-600">no log tail via API — SSH in to inspect job output</span>
                        <LogView text={str(dispatchDetail["inner_cmd"])} maxH="10rem" />
                    </>}
                </div>
            </div>

            <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-4 pt-5">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">DISPATCH HISTORY</span>
                {len(dispatches) == 0 and <span className="stat-line text-neutral-600">no dispatches yet</span>}
                <div className="flex flex-wrap gap-2">
                    {for d in dispatches {
                        did = str(d["id"]);
                        <button
                            key={did}
                            onClick={lambda e: MouseEvent { pickDispatch(did); }}
                            className={"rounded-md border px-3 py-1 font-mono text-[10px] transition-colors " + (
                                "border-neutral-500 bg-[#1a1a1a] text-neutral-100" if selDispatch == did
                                else "border-neutral-700 text-neutral-500 hover:text-neutral-300"
                            )}
                        >
                            {str(d["name"])}·{str(d["mode"])} · {str(d["status"])}
                        </button>
                    }}
                </div>
            </div>
        </div>;
    }

    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="flex items-center justify-between border-b border-neutral-800 px-4 py-2.5">
            <SubTabs tabs={TABS} active={tab.upper()} onTab={onTab} />
            <span className="micro-label text-neutral-600">SPHERON</span>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto">
            {tab == "instances" and _instances()}
            {tab == "dispatch" and _dispatch()}
            {tab == "setup" and _setup()}
        </div>
    </div>;
}
