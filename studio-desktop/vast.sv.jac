"""studio - Vast.ai GPU cloud integration (vastai SDK).

Wraps the full instance lifecycle from the Vast.ai Python SDK quickstart:
verify auth, search offers, create instance, poll status, ssh/scp urls, logs,
exec, and start/stop/reboot/destroy. The `vastai` import is lazy (inside
bodies) so a server boot with no key configured stays import-light, matching
inference.sv.jac's mlx pattern. The SDK also auto-reads
~/.config/vastai/vast_api_key when VAST_API_KEY is unset, so local CLI users
get transparent auth.

Checker notes (jaclang 0.16.1): `vastai` is an untyped PyPI package, so the
client and every SDK return arrive as `any`. We normalize into fresh dict
literals (whose value side is untyped and so accepts `any`) rather than typed
View objects — same trick inference.loaded_info() / models.warm_model() use to
side-step the E1001 any-boundary rule. Every endpoint guards its SDK call and
returns {ok:bool, error:str,...}; ok=True means the SDK call succeeded.
"""

import os;
import datetime;
import json;
import re;
import shlex;
import audit;
import crypto;
import jobs;
import backends;
import workspace;
import from pathlib { Path }
import from uuid { uuid4 }

"""Per-user Vast.ai credential. Lives on the caller's OWN root, so each tenant's
key (and the instances it controls / the spend it accrues) is private to them.
Falls back to the shared VAST_API_KEY env var when no user key is set, so a
single-admin deploy still works without every user bringing a key."""
node VastCred {
    has api_key: str = "",   # encrypted at rest via crypto.encrypt (see crypto.sv.jac)
        label: str = "",
        set_at: str = "";
}

"""Tracks instances this user created (required when falling back to a shared key)."""
node VastInstance {
    has instance_id: int = 0,
        offer_id: int = 0,
        dph_total: float = 0.0,
        disk_gb: float = 0.0,
        image: str = "",
        created_at: str = "",
        destroyed_at: str = "";
}

"""A training job dispatched to a Vast instance via vast execute."""
node VastDispatch {
    has did: str = "",
        instance_id: int = 0,
        name: str = "",
        mode: str = "",
        backend: str = "",
        inner_cmd: str = "",
        remote_pid: int = 0,
        status: str = "running",
        started: str = "",
        finished: str = "",
        message: str = "";
}

def _max_concurrent() -> int {
    try {
        return int(str(os.environ.get("VAST_MAX_CONCURRENT", "2")));
    } except Exception {
        return 2;
    }
}

def _daily_budget_usd() -> float {
    try {
        return float(str(os.environ.get("VAST_DAILY_BUDGET_USD", "50")));
    } except Exception {
        return 50.0;
    }
}

def _max_dph() -> float {
    try {
        return float(str(os.environ.get("VAST_MAX_DPH", "3.0")));
    } except Exception {
        return 3.0;
    }
}

def _active_instances() -> list {
    out: list = [];
    for v in [root -->][?:VastInstance] {
        if not v.destroyed_at { out.append(v); }
    }
    return out;
}

"""Rough daily spend estimate: sum(dph * 24) for active instances created today."""
def _today_spend_estimate() -> float {
    today = datetime.datetime.now(datetime.UTC).date().isoformat();
    total = 0.0;
    for v in _active_instances() {
        if str(v.created_at).startswith(today) {
            total += float(v.dph_total) * 24.0;
        }
    }
    return total;
}

def _guard_create(dph_total: float) -> str {
    if dph_total > _max_dph() {
        return f"dph_total {dph_total} exceeds max {_max_dph()}";
    }
    if len(_active_instances()) >= _max_concurrent() {
        return "concurrent instance cap reached";
    }
    est = _today_spend_estimate() + dph_total * 24.0;
    if est > _daily_budget_usd() {
        return f"daily budget exceeded (est ${est:.2f})";
    }
    return "";
}

"""When using a shared key, only instances recorded on the caller's root are operable."""
def _owns_instance(id: int) -> bool {
    if _key_source() == "user" { return True; }
    for v in [root -->][?:VastInstance] {
        if v.instance_id == id and not v.destroyed_at { return True; }
    }
    return False;
}

def _mark_destroyed(id: int) -> None {
    for v in [root -->][?:VastInstance] {
        if v.instance_id == id {
            v.destroyed_at = _now();
        }
    }
}

def _now() -> str {
    return datetime.datetime.now(datetime.UTC).replace(tzinfo=None).isoformat() + "Z";
}

"""The caller's stored VastCred, or None. Caller's root only (multi-tenant)."""
def _user_cred() -> VastCred | None {
    cr = [root -->][?:VastCred];
    return cr[0] if len(cr) > 0 else None;
}

"""Resolve the API key: caller's stored key wins, else shared env, else None
(then the SDK falls back to its keyfile). The stored key is decrypted here —
the only point it exists in plaintext, inside the request that spends on it."""
def _api_key() -> any {
    c = _user_cred();
    if c is not None and c.api_key { return crypto.decrypt(c.api_key); }
    k = os.environ.get("VAST_API_KEY", "");
    if k { return k; }
    return None;
}

"""Which source the resolved key comes from — drives the credential badge."""
def _key_source() -> str {
    c = _user_cred();
    if c is not None and c.api_key { return "user"; }
    if os.environ.get("VAST_API_KEY", "") { return "shared"; }
    if Path.home().joinpath(".config/vastai/vast_api_key").is_file() { return "shared"; }
    return "none";
}

"""Build a VastAI client. raw=True keeps responses as plain JSON dicts/strings
(no rich-formatted output) — the most predictable shape for field extraction."""
def _client() -> any {
    import vastai;
    return vastai.VastAI(api_key=_api_key(), raw=True);
}

"""True if the caller has a user key, OR VAST_API_KEY is set, OR the SDK's
default key file exists — drives the 'connected' badge without a network call."""
def _configured() -> bool {
    c = _user_cred();
    if c is not None and c.api_key { return True; }
    if os.environ.get("VAST_API_KEY", "") { return True; }
    return Path.home().joinpath(".config/vastai/vast_api_key").is_file();
}

"""Safe dict getter: o[k] if present else default. Keeps any-typed SDK dicts
from throwing on missing keys (offer/instance schemas vary across SDK versions)."""
def _f(o: any, k: str, fallback: any = None) -> any {
    try {
        return o[k];
    } except Exception {
        return fallback;
    }
}

"""Normalize a raw instance dict (from show_instance/show_instances) into a
stable client-facing shape."""
def _instance_view(o: any) -> dict {
    return {
        "id": _f(o, "id", 0),
        "label": _f(o, "label", ""),
        "image": _f(o, "image", ""),
        "cur_state": _f(o, "cur_state", ""),
        "status_msg": _f(o, "status_msg", _f(o, "status", "")),
        "gpu_name": _f(o, "gpu_name", ""),
        "num_gpus": _f(o, "num_gpus", 0),
        "dph_total": _f(o, "dph_total", 0.0),
        "ssh_addr": _f(o, "ssh_addr", ""),
        "ports": _f(o, "ports", ""),
        "machine_id": _f(o, "machine_id", "")
    };
}

"""Store or replace the caller's Vast.ai API key on their own root. Subsequent
vast_* calls then attribute spend to the caller's OWN Vast account. Never echoes
the key back. Returns {ok, source, error}."""
def set_vast_key(api_key: str, label: str = "") -> dict {
    k = api_key.strip();
    if not k { return {"ok": False, "source": _key_source(), "error": "empty key"}; }
    enc = crypto.encrypt(k);
    existing = _user_cred();
    if existing is not None {
        existing.api_key = enc;
        existing.label = label;
        existing.set_at = _now();
    } else {
        root ++> VastCred(api_key=enc, label=label, set_at=_now());
    }
    return {"ok": True, "source": "user", "error": ""};
}

"""Delete the caller's stored key (falls back to the shared env key)."""
def clear_vast_key() -> dict {
    c = _user_cred();
    if c is not None { del c; }
    return {"ok": True, "source": _key_source(), "error": ""};
}

"""Credential status for the Vast badge — never returns the key itself.
{has_user_key, label, source: user|shared|none, configured}."""
def vast_credential_status() -> dict {
    c = _user_cred();
    return {
        "has_user_key": c is not None and bool(c.api_key),
        "label": c.label if c is not None else "",
        "source": _key_source(),
        "configured": _configured()
    };
}

"""Verify the API key + account (one cheap GET). Returns
{ok, configured, user_id, email, credit, ssh_key, error}. ok=True means the
key authenticated against Vast.ai. This is the connection-health endpoint."""
def vast_status() -> dict {
    if not _configured() {
        return {
            "ok": False, "configured": False,
            "user_id": "", "email": "", "credit": 0.0, "ssh_key": "",
            "error": "VAST_API_KEY not set and no ~/.config/vastai/vast_api_key"
        };
    }
    try {
        c: any = _client();
        u: any = c.show_user();
        return {
            "ok": True, "configured": True,
            "user_id": _f(u, "id", ""),
            "email": _f(u, "email", ""),
            "credit": _f(u, "credit", 0.0),
            "ssh_key": _f(u, "ssh_key", ""),
            "error": ""
        };
    } except Exception as e {
        return {
            "ok": False, "configured": True,
            "user_id": "", "email": "", "credit": 0.0, "ssh_key": "",
            "error": str(e)
        };
    }
}

"""Search rentable GPU offers. `query` is the vast filter string
(e.g. "gpu_name=RTX_4090 num_gpus=1 verified=true rentable=true");
`order` sorts (default "dlperf_usd-" = best DL-perf/$ first);
`rent_type` is "on-demand" or "interruptible"; `limit` caps the count (0=all).
Returns {ok, count, offers:[...], error}. Each offer is normalized to
{id, gpu_name, num_gpus, dph_total, dlperf_usd, cpu_cores, cpu_ram, gpu_ram,
space, geolocation, verified, rentable, score}."""
def search_gpus(
    query: str = "rentable=true verified=true",
    order: str = "dlperf_usd-",
    rent_type: str = "on-demand",
    limit: int = 0
) -> dict {
    try {
        c: any = _client();
        lim: any = limit if limit > 0 else None;
        rows: any = c.search_offers(query=query, type=rent_type, order=order, limit=lim);
        out: list[dict] = [];
        for o in rows {
            out.append({
                "id": _f(o, "id", 0),
                "gpu_name": _f(o, "gpu_name", ""),
                "num_gpus": _f(o, "num_gpus", 0),
                "dph_total": _f(o, "dph_total", 0.0),
                "dlperf_usd": _f(o, "dlperf_usd", 0.0),
                "cpu_cores": _f(o, "cpu_cores", 0),
                "cpu_ram": _f(o, "cpu_ram", 0.0),
                "gpu_ram": _f(o, "gpu_ram", 0.0),
                "space": _f(o, "space", 0.0),
                "geolocation": _f(o, "geolocation", ""),
                "verified": _f(o, "verified", False),
                "rentable": _f(o, "rentable", False),
                "score": _f(o, "score", 0.0)
            });
        }
        return {"ok": True, "count": len(out), "offers": out, "error": ""};
    } except Exception as e {
        return {"ok": False, "count": 0, "offers": [], "error": str(e)};
    }
}

"""Rent an offer (create_instance). `offer_id` comes from search_gpus; `image`
is the docker image to launch; `disk_gb` is storage; `onstart_cmd` runs at boot;
ssh=True + direct=True enable direct SSH (lower latency than proxy). Returns
{ok, instance_id, raw, error} — instance_id is the new_contract id."""
def create_gpu_instance(
    offer_id: int,
    image: str = "pytorch/pytorch:latest-cuda11.8-cudnn8-devel",
    disk_gb: float = 20.0,
    onstart_cmd: str = "",
    dph_total: float = 0.0
) -> dict {
    # Reserve BEFORE the SDK call: _active_instances()/_today_spend_estimate()
    # count any VastInstance with an empty destroyed_at, so the reservation node
    # (instance_id=0 until the contract lands) is included in a concurrent
    # request's guard. This shrinks the check-then-act window from the whole
    # multi-second SDK round-trip down to two adjacent graph ops. A concurrent
    # create is denied on the reservation it can see rather than racing past a
    # stale spend estimate. The reservation is deleted if the SDK call fails.
    guard_err = _guard_create(dph_total);
    if guard_err {
        audit.log("vast_create_denied", {"offer_id": offer_id, "reason": guard_err});
        return {"ok": False, "instance_id": 0, "raw": {}, "error": guard_err};
    }
    resv = root ++> VastInstance(
        instance_id=0, offer_id=offer_id, dph_total=dph_total,
        disk_gb=disk_gb, image=image, created_at=_now()
    );
    try {
        c: any = _client();
        res: any = c.create_instance(
            id=offer_id, image=image, disk=disk_gb,
            onstart_cmd=onstart_cmd, ssh=True, direct=True
        );
        iid = int(str(_f(res, "new_contract", _f(res, "instance_id", 0))));
        resv.instance_id = iid;
        audit.log("vast_create", {
            "instance_id": iid, "offer_id": offer_id,
            "dph_total": dph_total, "disk_gb": disk_gb
        });
        return {"ok": True, "instance_id": iid, "raw": res, "error": ""};
    } except Exception as e {
        del resv;   # release the reservation so it stops counting against the budget
        audit.log("vast_create_failed", {"offer_id": offer_id, "error": str(e)});
        return {"ok": False, "instance_id": 0, "raw": {}, "error": str(e)};
    }
}

"""All your instances (running + stopped). Returns {ok, instances:[...], error}.
Each instance is normalized via _instance_view."""
def vast_instances() -> dict {
    try {
        c: any = _client();
        rows: any = c.show_instances();
        out: list[dict] = [];
        for o in rows {
            iid = int(str(_f(o, "id", 0)));
            if _key_source() != "user" and not _owns_instance(iid) { continue; }
            out.append(_instance_view(o));
        }
        return {"ok": True, "instances": out, "error": ""};
    } except Exception as e {
        return {"ok": False, "instances": [], "error": str(e)};
    }
}

"""One instance by id — polling-friendly (call on a timer to watch
loading → running). Returns {ok, instance, error}."""
def vast_instance(id: int) -> dict {
    if not _owns_instance(id) {
        return {"ok": False, "instance": {}, "error": "instance not owned by caller"};
    }
    try {
        c: any = _client();
        o: any = c.show_instance(id=id);
        if o is None {
            return {"ok": False, "instance": {}, "error": f"instance {id} not found"};
        }
        return {"ok": True, "instance": _instance_view(o), "error": ""};
    } except Exception as e {
        return {"ok": False, "instance": {}, "error": str(e)};
    }
}

"""SSH + SCP connection strings for a running instance. Returns
{ok, ssh, scp, error}. Use the `ssh` string once the instance cur_state is
"running" (boot is typically 1-5 min)."""
def vast_ssh(id: int) -> dict {
    if not _owns_instance(id) {
        return {"ok": False, "ssh": "", "scp": "", "error": "instance not owned by caller"};
    }
    try {
        c: any = _client();
        return {"ok": True, "ssh": str(c.ssh_url(id=id)), "scp": str(c.scp_url(id=id)), "error": ""};
    } except Exception as e {
        return {"ok": False, "ssh": "", "scp": "", "error": str(e)};
    }
}

"""Instance stdout logs. `tail` e.g. "200", `filter` a regex to grep for.
Returns {ok, logs, error}."""
def vast_logs(id: int, tail: str = "200", filter: str = "") -> dict {
    if not _owns_instance(id) {
        return {"ok": False, "logs": "", "error": "instance not owned by caller"};
    }
    try {
        c: any = _client();
        flt: any = filter if filter else None;
        return {"ok": True, "logs": str(c.logs(instance_id=id, tail=tail, filter=flt)), "error": ""};
    } except Exception as e {
        return {"ok": False, "logs": "", "error": str(e)};
    }
}

"""Run a shell command inside a running instance (vast execute). Returns
{ok, output, error}."""
def vast_exec(id: int, command: str) -> dict {
    if not _owns_instance(id) {
        return {"ok": False, "output": "", "error": "instance not owned by caller"};
    }
    try {
        c: any = _client();
        res: any = c.execute(id=id, command=command);
        return {"ok": True, "output": str(_f(res, "stdout", res)), "error": ""};
    } except Exception as e {
        return {"ok": False, "output": "", "error": str(e)};
    }
}

# Instance lifecycle — each wraps the matching SDK verb and returns
# {ok, action, id, result, error}. destroy stops ALL billing; stop pauses
# compute but disk storage charges continue (per the SDK quickstart).
def stop_gpu_instance(id: int) -> dict { return _lifecycle("stop", id); }
def start_gpu_instance(id: int) -> dict { return _lifecycle("start", id); }
def reboot_gpu_instance(id: int) -> dict { return _lifecycle("reboot", id); }
def destroy_gpu_instance(id: int) -> dict { return _lifecycle("destroy", id); }

def _lifecycle(action: str, id: int) -> dict {
    if not _owns_instance(id) {
        audit.log("vast_denied", {"action": action, "instance_id": id});
        return {
            "ok": False, "action": action, "id": id,
            "result": {}, "error": "instance not owned by caller"
        };
    }
    try {
        c: any = _client();
        res: any = None;
        if action == "stop" { res = c.stop_instance(id=id); }
        elif action == "start" { res = c.start_instance(id=id); }
        elif action == "reboot" { res = c.reboot_instance(id=id); }
        else { res = c.destroy_instance(id=id); }
        if action == "destroy" { _mark_destroyed(id); }
        audit.log("vast_" + action, {"instance_id": id});
        return {"ok": True, "action": action, "id": id, "result": res, "error": ""};
    } except Exception as e {
        return {"ok": False, "action": action, "id": id, "result": {}, "error": str(e)};
    }
}

# ---------------------------------------------------------------------------
# Cloud dispatch — run a rendered training job on instance Y (bridge jobs ↔ vast)
# ---------------------------------------------------------------------------

def _remote_root(scope: str) -> str {
    cfg = workspace.vast_remote_config();
    if scope == "data" {
        return str(cfg.get("remote_data_root", os.environ.get("VAST_REMOTE_DATA_ROOT", "/workspace/data")));
    }
    if scope == "studio" {
        return str(cfg.get("remote_studio_root", os.environ.get("VAST_REMOTE_STUDIO_ROOT", "/workspace/studio-desktop")));
    }
    return str(cfg.get("remote_workspace_root", os.environ.get("VAST_REMOTE_WORKSPACE_ROOT", "/workspace")));
}

def _remote_run_dir(name: str) -> str {
    return f"$HOME/studio-runs/{name}";
}

def _export_env(env: dict) -> str {
    parts: list[str] = [];
    for k in env {
        parts.append(f"export {shlex.quote(str(k))}={shlex.quote(str(env[k]))}");
    }
    if len(parts) == 0 { return "true"; }
    return " && ".join(parts);
}

"""Wrap a rendered local job plan into a detached remote shell one-liner."""
def _remote_launch_cmd(rendered: dict, name: str, mode: str) -> str {
    remote_cwd = _remote_root(str(rendered.get("cwd_scope", "data")));
    run_dir = _remote_run_dir(name);
    runlog = f"{run_dir}/run-{mode}.log";
    inner = str(rendered["cmd"]);
    env_part = _export_env(dict(rendered["env"]));
    wrapped = inner + f'; echo "__EXIT__ $?" >> {runlog}';
    return (
        f"mkdir -p {shlex.quote(run_dir)} && "
        f"cd {shlex.quote(remote_cwd)} && "
        f"{env_part} && "
        f"nohup bash -lc {shlex.quote(wrapped)} >> {shlex.quote(run_dir + '/train.log')} 2>&1 & "
        f"echo DISPATCH_PID:$!"
    );
}

def _find_dispatch(did: str) -> VastDispatch | None {
    for d in [root -->][?:VastDispatch] {
        if d.did == did { return d; }
    }
    return None;
}

def _exit_code_from_tail(text: str) -> int {
    m: any = re.search(r"__EXIT__ (\d+)", text);
    if m is None { return -1; }
    return int(str(m.group(1)));
}

"""Poll remote run log on the instance and refresh dispatch status."""
def _refresh_dispatch(d: VastDispatch) -> dict {
    if d.status != "running" {
        return _dispatch_view(d, "");
    }
    inst = vast_instance(d.instance_id);
    if not bool(inst["ok"]) {
        d.status = "failed";
        d.finished = _now();
        d.message = str(inst["error"]);
        return _dispatch_view(d, "");
    }
    tail_cmd = f"tail -40 {_remote_run_dir(d.name)}/run-{d.mode}.log 2>/dev/null || true";
    log_res = vast_exec(d.instance_id, tail_cmd);
    tail = str(log_res.get("output", "")) if bool(log_res["ok"]) else "";
    code = _exit_code_from_tail(tail);
    if code == 0 {
        d.status = "done";
        d.finished = _now();
        d.message = "remote job finished";
    } elif code > 0 {
        d.status = "failed";
        d.finished = _now();
        d.message = f"remote exit {code}";
    }
    return _dispatch_view(d, tail);
}

def _dispatch_view(d: VastDispatch, log_tail: str) -> dict {
    return {
        "id": d.did,
        "instance_id": d.instance_id,
        "name": d.name,
        "mode": d.mode,
        "backend": d.backend,
        "status": d.status,
        "remote_pid": d.remote_pid,
        "started": d.started,
        "finished": d.finished,
        "message": d.message,
        "inner_cmd": d.inner_cmd,
        "log_tail": log_tail
    };
}

"""Dispatch a training job to a running Vast instance.

Renders the job via backends.render(), launches it detached on the instance
(nohup + __EXIT__ marker in ~/studio-runs/<name>/), and records a VastDispatch
node for polling. Returns {ok, dispatch, error}."""
def dispatch_training_job(
    instance_id: int,
    name: str,
    mode: str,
    model_id: str = "",
    opts: dict = {},
    backend: str = ""
) -> dict {
    if not _owns_instance(instance_id) {
        return {"ok": False, "dispatch": {}, "error": "instance not owned by caller"};
    }
    if not jobs.safe(name) { return {"ok": False, "dispatch": {}, "error": "invalid name"}; }
    if name in workspace.excluded_run_dirs() {
        return {"ok": False, "dispatch": {}, "error": "reserved name"};
    }
    if mode != "sft" and mode != "dpo" {
        return {"ok": False, "dispatch": {}, "error": "mode must be sft|dpo"};
    }
    if mode == "sft" {
        if not model_id or not jobs.safe(model_id, allow_slash=True) {
            return {"ok": False, "dispatch": {}, "error": "invalid model_id"};
        }
    }

    inst = vast_instance(instance_id);
    if not bool(inst["ok"]) {
        return {"ok": False, "dispatch": {}, "error": str(inst["error"])};
    }
    state = str(_f(inst["instance"], "cur_state", ""));
    if state != "running" {
        return {"ok": False, "dispatch": {}, "error": f"instance not running (state={state})"};
    }

    bk = backend if backend else "vast_gpu";
    try {
        rendered = backends.render({
            "backend": bk,
            "method": mode,
            "vars": {"run_name": shlex.quote(name), "model_id": shlex.quote(model_id)},
            "opts": opts
        });
    } except Exception as e {
        return {"ok": False, "dispatch": {}, "error": str(e)};
    }

    launch = _remote_launch_cmd(rendered, name, mode);
    exec_res = vast_exec(instance_id, launch);
    if not bool(exec_res["ok"]) {
        return {"ok": False, "dispatch": {}, "error": str(exec_res["error"])};
    }
    out = str(exec_res["output"]);
    remote_pid = 0;
    m: any = re.search(r"DISPATCH_PID:(\d+)", out);
    if m is not None { remote_pid = int(str(m.group(1))); }

    did = str(uuid4());
    ignored: list = list(rendered.get("ignored_opts", []));
    msg = ("ignored opts: " + ", ".join(sorted(ignored))) if ignored else "dispatched";
    d = root ++> VastDispatch(
        did=did, instance_id=instance_id, name=name, mode=mode,
        backend=str(rendered["backend"]), inner_cmd=str(rendered["cmd"]),
        remote_pid=remote_pid, status="running", started=_now(), message=msg
    );
    audit.log("vast_dispatch", {
        "dispatch_id": did, "instance_id": instance_id,
        "name": name, "mode": mode, "backend": bk, "remote_pid": remote_pid
    });
    return {"ok": True, "dispatch": _dispatch_view(d, out), "error": ""};
}

"""All dispatches recorded for the caller (newest first)."""
def list_vast_dispatches() -> dict {
    rows: list[dict] = [];
    for d in [root -->][?:VastDispatch] {
        rows.append(_refresh_dispatch(d));
    }
    rows.sort(key=lambda r: dict -> str { return str(r["started"]); }, reverse=True);
    return {"dispatches": rows};
}

"""Poll one dispatch by id — refreshes status from the remote run log."""
def get_vast_dispatch(did: str) -> dict {
    d = _find_dispatch(did);
    if d is None { return {"ok": False, "dispatch": {}, "error": "not found"}; }
    return {"ok": True, "dispatch": _refresh_dispatch(d), "error": ""};
}

"""Best-effort stop: pkill the remote run dir pattern, mark dispatch stopped."""
def stop_vast_dispatch(did: str) -> dict {
    d = _find_dispatch(did);
    if d is None { return {"ok": False, "dispatch": {}, "error": "not found"}; }
    if d.status == "running" {
        kill_cmd = f"pkill -f {shlex.quote('studio-runs/' + d.name)} || true";
        vast_exec(d.instance_id, kill_cmd);
        d.status = "stopped";
        d.finished = _now();
        d.message = "stop signal sent";
        audit.log("vast_dispatch_stop", {"dispatch_id": did, "instance_id": d.instance_id});
    }
    return {"ok": True, "dispatch": _dispatch_view(d, ""), "error": ""};
}
