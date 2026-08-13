"""studio - supervised remote GPU training runs (BYO cluster + local supervisor).

Wires remote/supervisor.py (the detached per-run orchestrator) into the app:
start_remote_run resolves a SAVED cluster (clusters.sv.jac) into an ssh command,
writes <run_dir>/runspec.json with that command as `ssh_override`, and spawns the
supervisor detached via jobs.spawn_detached with `--no-spheron-api`. Nothing is
provisioned or billed here — the box is the user's own persistent hardware, so
there is no marketplace offer, no deployment id and no vendor REST API in the
loop. From then on the supervisor owns the run end-to-end (wait_vm → provision →
launch → monitor → pull → terminate) and communicates only through files in the
run dir:

  status.json      phase/status/heartbeat/cost/progress/artifacts (read here)
  .job-<mode>.json jobs contract (jobs.live_status resolves it)
  control.json     {"action":"stop"} → graceful stop (written here)
  train.log / metrics.jsonl   local mirrors of the remote run
  run-<mode>.log   supervisor appends "__EXIT__ <code>" at finalize

A CloudRun node on the caller's root tracks each run (multi-tenant: run dirs
live under auth.user_results_dir()). "Detached" = status.json still says
running BUT the heartbeat is stale (>90s) AND the supervisor pid is dead —
the remote job may still be burning the user's box, so list views carry a
billing_alert flag and reattach_run respawns the supervisor with --resume.

`deployment_id`/`hourly_rate` survive on the CloudRun node (and in the runspec)
purely for schema/UI compatibility with the old marketplace flow — they are now
always "" and 0.0.

Checker notes (jaclang 0.16.1): dict/JSON values are `any` → int(str(...)) /
float(str(...)) coercions throughout; json.loads into typed dict via dict(...).
"""

import datetime;
import json;
import os;
import re;
import shlex;
import time;
import audit;
import auth;
import backends;
import clusters;
import jobs;
import metrics;
import paths;
import workspace;
import from pathlib { Path }
import from uuid { uuid4 }

"""One supervised remote GPU run owned by the caller."""
node CloudRun {
    has run_id: str = "";
    has name: str = "";
    has mode: str = "sft";
    has backend: str = "spheron_gpu";
    has cluster_id: str = "";
    has deployment_id: str = "";
    has hourly_rate: float = 0.0;
    has supervisor_pid: int = 0;
    has created: str = "";
    has status: str = "running";
}

# Heartbeat staleness (seconds) before a running run with a dead supervisor
# counts as detached.
glob DETACHED_AFTER_S: float = 90.0;

# train_sft.py CLI options forwardable from cfg.opts (value flags).
glob _OPT_KEYS: list[str] = [
    "lora_r", "lora_alpha", "lora_dropout", "target_modules",
    "max_steps", "num_epochs", "per_device_batch_size", "grad_accum",
    "lr", "max_seq_len", "eval_every", "subset", "seed"
];
# store_true flags (present when opts value is truthy).
glob _BOOL_OPT_KEYS: list[str] = ["bf16", "load_in_4bit"];

def _now() -> str {
    return datetime.datetime.now(datetime.UTC).replace(tzinfo=None).isoformat() + "Z";
}

def _err(msg: str) -> dict {
    return {"ok": False, "run": {}, "error": msg};
}

def _cloudrun_defaults() -> dict {
    return workspace.cloudrun_config();
}

def _run_dir(name: str) -> Path {
    return auth.user_results_dir() / name;
}

def _find_run(run_id: str) -> CloudRun | None {
    for r in [root -->][?:CloudRun] {
        if r.run_id == run_id { return r; }
    }
    return None;
}

"""Dataset rels (data_root-relative): [cloudrun] toml defaults, cfg.dataset wins."""
def _dataset_rels(cfg: dict) -> dict {
    d = _cloudrun_defaults();
    train_rel = str(d.get("train_rel", "model-experiments/01-sft-dpo/dataset/mlx/train.jsonl"));
    valid_rel = str(d.get("valid_rel", "model-experiments/01-sft-dpo/dataset/mlx/valid.jsonl"));
    raw = cfg.get("dataset");
    if isinstance(raw, dict) {
        ds = dict(raw);
        if ds.get("train_rel") { train_rel = str(ds["train_rel"]); }
        if ds.get("valid_rel") { valid_rel = str(ds["valid_rel"]); }
    }
    return {"train_rel": train_rel, "valid_rel": valid_rel};
}

"""cfg.opts → ' --lora_r 16 --max_steps 100 ...' (whitelisted, value-validated).
Values allow [A-Za-z0-9_.,-] (comma for target_modules, e-notation for lr)."""
def _extra_flags(opts: dict) -> str {
    parts: list[str] = [];
    for k in _OPT_KEYS {
        if k not in opts { continue; }
        v = str(opts[k]).strip();
        if not v { continue; }
        if re.fullmatch(r"[A-Za-z0-9_.,-]+", v) is None { continue; }
        parts.append(f"--{k} {v}");
    }
    for k in _BOOL_OPT_KEYS {
        if k not in opts { continue; }
        v = str(opts[k]).strip().lower();
        if v in ["1", "true", "yes", "on"] { parts.append(f"--{k}"); }
    }
    if len(parts) == 0 { return ""; }
    return " " + " ".join(parts);
}

"""Supervisor policy: [cloudrun] toml defaults, cfg.policy overrides per key."""
def _policy_from(cfg: dict) -> dict {
    d = _cloudrun_defaults();
    pol: dict = {
        "auto_terminate": str(d.get("auto_terminate", "on_success")),
        "max_wall_clock_min": float(str(d.get("max_wall_clock_min", 720))),
        "ssh_wait_timeout_s": float(str(d.get("ssh_wait_timeout_s", 900))),
        "provision_timeout_s": float(str(d.get("provision_timeout_s", 1800))),
        "stall_timeout_min": float(str(d.get("stall_timeout_min", 30))),
        "poll_interval_s": float(str(d.get("poll_interval_s", 10)))
    };
    raw = cfg.get("policy");
    if isinstance(raw, dict) {
        p = dict(raw);
        for k in p {
            key = str(k);
            if key == "auto_terminate" {
                pol[key] = str(p[k]);
            } elif key in pol {
                try {
                    pol[key] = float(str(p[k]));
                } except Exception {}
            }
        }
    }
    return pol;
}

"""Build the runspec.json dict the supervisor consumes. Pure (no graph/auth) so
tests can exercise it directly. remote_dir is made per-run unique (base-<name>)
so a reused transport target (fake stack; resumed VM) never sees a stale
run.log/__EXIT__ from a previous run."""
def _build_runspec(cfg: dict, run_id: str, deployment_id: str, hourly_rate: float, launch_cmd: str) -> dict {
    name = str(cfg.get("name", ""));
    mode = str(cfg.get("mode", "sft"));
    ds = _dataset_rels(cfg);
    sr = paths.studio_root();
    remote_base = str(_cloudrun_defaults().get("remote_dir", "studio-run"));
    spec: dict = {
        "run_id": run_id,
        "name": name,
        "mode": mode,
        "deployment_id": deployment_id,
        "hourly_rate": hourly_rate,
        "remote_dir": f"{remote_base}-{name}",
        "uploads": [
            {"local": str(paths.resolve(str(ds["train_rel"]), "data")), "remote": "data/train.jsonl"},
            {"local": str(paths.resolve(str(ds["valid_rel"]), "data")), "remote": "data/valid.jsonl"},
            {"local": str(sr / "remote" / "bootstrap.sh"), "remote": "bootstrap.sh"},
            {"local": str(sr / "remote" / "train_sft.py"), "remote": "train_sft.py"},
            {"local": str(sr / "remote" / "requirements.txt"), "remote": "requirements.txt"}
        ],
        "launch_cmd": launch_cmd,
        "pull": [
            {"remote": "output/adapter", "local": "adapter"},
            {"remote": "train.log"},
            {"remote": "metrics.jsonl"}
        ],
        "policy": _policy_from(cfg)
    };
    ovr = str(cfg.get("ssh_override", ""));
    if ovr { spec["ssh_override"] = ovr; }
    return spec;
}

def _read_status(run_dir: Path) -> dict {
    p = run_dir / "status.json";
    if not p.exists() { return {}; }
    try {
        return dict(json.loads(p.read_text()));
    } except Exception {
        return {};
    }
}

"""One-way control file recording a server-side direct VM teardown.

Legacy: it was written by the old `terminate_run_vm` panic button, which killed
the marketplace VM through the vendor API. BYO clusters are the user's own
persistent hardware — nothing to destroy — so nothing writes this file anymore,
but _view still ORs it in so runs from the old flow keep reading correctly.

status.json is OWNED by remote/supervisor.py, which rewrites it wholesale on
every heartbeat, so this signal deliberately never lived in there (a read-modify-
write would clobber phase/heartbeat/cost). The file's mere existence is the
signal; its body is informational."""
def _vm_terminated_file(run_dir: Path) -> Path {
    return run_dir / "vm-terminated.json";
}

def _vm_terminated_signal(run_dir: Path) -> bool {
    return _vm_terminated_file(run_dir).exists();
}

def _hb_epoch(hb: str) -> float {
    try {
        dt: any = datetime.datetime.strptime(hb, "%Y-%m-%dT%H:%M:%SZ");
        return float(str(dt.replace(tzinfo=datetime.UTC).timestamp()));
    } except Exception {
        return 0.0;
    }
}

"""Detached = status.json says running BUT heartbeat stale (> DETACHED_AFTER_S)
AND the supervisor pid is dead. Pure over (status dict, pid) for testability."""
def _is_detached(st: dict, pid: int) -> bool {
    if str(st.get("status", "")) != "running" { return False; }
    hb = str(st.get("heartbeat", ""));
    if not hb { return False; }
    ep = _hb_epoch(hb);
    if ep <= 0.0 { return False; }
    if time.time() - ep <= DETACHED_AFTER_S { return False; }
    # The supervisor is a direct child of this server: a killed one lingers as
    # a zombie (which still answers kill-0) until reaped.
    jobs.reap(pid);
    return not jobs.alive(pid);
}

"""Env for the spawned supervisor: just the transport-shim seam
(JMS_*_BIN / FAKE_REMOTE_ROOT) when set server-side. No vendor API credentials —
every run is --no-spheron-api and reaches its box through runspec.ssh_override."""
def _supervisor_env() -> dict {
    env: dict = {};
    for k in ["JMS_SSH_BIN", "JMS_RSYNC_BIN", "JMS_SCP_BIN", "FAKE_REMOTE_ROOT"] {
        v = os.environ.get(k, "");
        if v { env[k] = v; }
    }
    return env;
}

"""Spawn remote/supervisor.py detached against *run_dir*. flag: '' | '--resume'
| '--pull-only'. stdout+stderr → <run_dir>/supervisor.log (the __EXIT__ jobs
marker goes to run-<mode>.log, written by the supervisor itself).

`--no-spheron-api` is ALWAYS passed (it is an independent store_true, so it
composes with --resume/--pull-only): every run now reaches its box through
runspec.ssh_override, so the supervisor must never call a vendor REST API to
resolve a transport or to terminate — it just marks vm_terminated itself."""
def _spawn_supervisor(run_dir: Path, flag: str = "") -> int {
    py = os.environ.get("JMS_PYTHON", "python3");
    sup = paths.studio_root() / "remote" / "supervisor.py";
    cmd = f"{shlex.quote(py)} {shlex.quote(str(sup))} --run-dir {shlex.quote(str(run_dir))}";
    if flag { cmd = f"{cmd} {flag}"; }
    cmd = f"{cmd} --no-spheron-api";
    return jobs.spawn_detached(
        cmd,
        runlog=run_dir / "supervisor.log",
        env=_supervisor_env(),
        cwd=paths.studio_root()
    );
}

"""Client-facing view of one run: node fields + status.json merge + log tail +
detached/billing computation. Syncs the node's status on terminal states."""
def _view(r: CloudRun, tail_n: int = 40) -> dict {
    rd = _run_dir(r.name);
    st = _read_status(rd);
    has_st = len(st) > 0;
    phase = str(st.get("phase", "")) if has_st else "starting";
    status = str(st.get("status", "running")) if has_st else r.status;
    pid = r.supervisor_pid;
    if has_st {
        try {
            pid = int(str(st.get("supervisor_pid") or pid));
        } except Exception {}
    }
    detached = _is_detached(st, pid) if has_st else False;
    if detached { status = "detached"; }
    if status in ["done", "failed", "stopped"] and r.status != status {
        r.status = status;
    }
    # The supervisor records its teardown in status.json; the one-way signal file
    # is the legacy server-side path (kept so old runs still read correctly).
    vm_terminated = (bool(st.get("vm_terminated", False)) if has_st else False) or _vm_terminated_signal(rd);
    cost_raw = st.get("cost");
    cost: dict = dict(cost_raw) if isinstance(cost_raw, dict) else {
        "hourly_rate": r.hourly_rate, "elapsed_usd": 0.0, "terminated_at": ""
    };
    prog_raw = st.get("progress");
    progress: dict = dict(prog_raw) if isinstance(prog_raw, dict) else {};
    art_raw = st.get("artifacts");
    artifacts: dict = dict(art_raw) if isinstance(art_raw, dict) else {"pulled": False, "adapter_dir": "", "bytes": 0};
    hist_raw = st.get("phase_history");
    phase_history: list = list(hist_raw) if isinstance(hist_raw, list) else [];
    return {
        "run_id": r.run_id,
        "name": r.name,
        "mode": r.mode,
        "backend": r.backend,
        "cluster_id": r.cluster_id,
        "deployment_id": r.deployment_id,
        "hourly_rate": r.hourly_rate,
        "created": r.created,
        "supervisor_pid": pid,
        "phase": phase,
        "status": status,
        "message": str(st.get("message", "")) if has_st else "supervisor starting",
        "heartbeat": str(st.get("heartbeat", "")) if has_st else "",
        "phase_history": phase_history,
        "cost": cost,
        "progress": progress,
        "artifacts": artifacts,
        "vm_terminated": vm_terminated,
        "exit_code": st.get("exit_code") if has_st else None,
        "error": str(st.get("error", "")) if has_st else "",
        "detached": detached,
        "billing_alert": detached and not vm_terminated,
        "log_tail": metrics.tail(rd / "train.log", tail_n),
        "last_metrics": metrics.last_row(rd / "metrics.jsonl")
    };
}

"""Start a supervised remote SFT run on one of the caller's saved clusters. cfg:
  {name, mode: "sft", base_model,
   cluster_id  (REQUIRED str — a cluster_id from clusters.list_clusters()),
   opts: {lora/train params}?, dataset: {train_rel, valid_rel}?,
   policy: {auto_terminate?, max_wall_clock_min?, ...}?,
   launch_cmd_override?  (dev/test-only: bypasses the backend template)}

`cluster_id` is resolved through clusters.cluster_ssh_override() into the
runspec's `ssh_override` (a cfg-supplied `ssh_override` is overridden by it).
Nothing is provisioned: deployment_id stays "" and hourly_rate 0.0.
Returns {ok, run, error}."""
def start_remote_run(cfg: dict) -> dict {
    name = str(cfg.get("name", ""));
    mode = str(cfg.get("mode", "sft"));
    if not jobs.safe(name) { return _err("invalid name"); }
    if name in workspace.excluded_run_dirs() { return _err("reserved name"); }
    if mode != "sft" { return _err("mode must be sft (dpo cloud runs not wired yet)"); }
    base_model = str(cfg.get("base_model", ""));
    if not base_model or not jobs.safe(base_model, allow_slash=True) {
        return _err("invalid base_model");
    }
    cluster_id = str(cfg.get("cluster_id", "")).strip();
    if not cluster_id { return _err("cluster_id required (pick a saved cluster)"); }
    ovr = clusters.cluster_ssh_override(cluster_id);
    if not ovr {
        return _err("cluster not found or its ssh key was deleted — reconnect it in the CLUSTERS tab");
    }
    # No VM is deployed: the box already exists and is the user's own hardware.
    deployment_id = "";
    hourly_rate = 0.0;

    ds = _dataset_rels(cfg);
    train_rel = str(ds["train_rel"]);
    valid_rel = str(ds["valid_rel"]);
    if not jobs.safe(train_rel, allow_slash=True) or not jobs.safe(valid_rel, allow_slash=True) {
        return _err("invalid dataset rel");
    }
    if not paths.resolve(train_rel, "data").is_file() {
        return _err(f"train dataset missing: {train_rel}");
    }
    if not paths.resolve(valid_rel, "data").is_file() {
        return _err(f"valid dataset missing: {valid_rel}");
    }

    opts_raw = cfg.get("opts");
    opts: dict = dict(opts_raw) if isinstance(opts_raw, dict) else {};

    launch_cmd = str(cfg.get("launch_cmd_override", ""));
    if not launch_cmd {
        try {
            rendered = backends.render({
                "backend": "spheron_gpu",
                "method": mode,
                "vars": {
                    "base_model": shlex.quote(base_model),
                    "extra_flags": _extra_flags(opts)
                },
                "opts": {}
            });
            launch_cmd = str(rendered["cmd"]);
        } except Exception as e {
            return _err(f"render failed: {e}");
        }
    }

    run_id = str(uuid4());
    # The resolved cluster ssh command rides in through _build_runspec's existing
    # ssh_override passthrough (copy, not mutation — cfg belongs to the caller).
    spec = _build_runspec({**cfg, "ssh_override": ovr}, run_id, deployment_id, hourly_rate, launch_cmd);
    run_dir = _run_dir(name);
    run_dir.mkdir(parents=True, exist_ok=True);
    # Clear a previous run's state under the same name: stale status/control
    # would confuse the new supervisor; stale train.log/metrics.jsonl mirrors
    # would corrupt the byte-offset mirroring. (Pulled adapters are kept.)
    for stale in ["status.json", "control.json", "train.log", "metrics.jsonl"] {
        try {
            (run_dir / stale).unlink();
        } except Exception {}
    }
    (run_dir / "runspec.json").write_text(json.dumps(spec, indent=2));
    # Truncate the run log so a previous __EXIT__ marker can't finish this run.
    (run_dir / f"run-{mode}.log").write_text("");

    pid = 0;
    try {
        pid = _spawn_supervisor(run_dir, "");
    } except Exception as e {
        return _err(f"spawn failed: {e}");
    }
    jobs.write_job(run_dir / f".job-{mode}.json", {
        "name": name, "mode": mode, "pid": pid,
        "status": "running", "started": _now()
    });

    r = CloudRun(
        run_id=run_id, name=name, mode=mode, backend="spheron_gpu",
        cluster_id=cluster_id, deployment_id=deployment_id, hourly_rate=hourly_rate,
        supervisor_pid=pid, created=_now(), status="running"
    );
    root ++> r;
    # cluster_id only — never the resolved ssh command, which carries a path to
    # private key material (see clusters.cluster_ssh_override).
    audit.log("cloudrun_start", {
        "run_id": run_id, "name": name, "cluster_id": cluster_id,
        "supervisor_pid": pid
    });
    return {"ok": True, "run": _view(r), "error": ""};
}

"""Poll one run: status.json merge + train.log tail + detached computation."""
def run_status(run_id: str) -> dict {
    r = _find_run(run_id);
    if r is None { return _err("run not found"); }
    return {"ok": True, "run": _view(r), "error": ""};
}

"""All the caller's cloud runs, newest first. Each row carries billing_alert
(detached + VM not known-terminated → may still be billing)."""
def list_cloud_runs() -> dict {
    rows: list[dict] = [];
    for r in [root -->][?:CloudRun] {
        rows.append(_view(r, 5));
    }
    rows.sort(key=lambda x: dict -> str { return str(x["created"]); }, reverse=True);
    return {"runs": rows};
}

"""Graceful stop: control.json {"action":"stop"} → the supervisor pkills the
remote job and pulls partials. If the supervisor is already dead, falls back to
jobs.stop (there is no VM to destroy — the cluster is the user's own box)."""
def stop_run(run_id: str) -> dict {
    r = _find_run(run_id);
    if r is None { return _err("run not found"); }
    rd = _run_dir(r.name);
    (rd / "control.json").write_text(json.dumps({"action": "stop"}));
    st = _read_status(rd);
    pid = r.supervisor_pid;
    try {
        pid = int(str(st.get("supervisor_pid") or pid));
    } except Exception {}
    if not jobs.alive(pid) {
        jobs.stop(rd / f".job-{r.mode}.json", rd / f"run-{r.mode}.log");
        r.status = "stopped";
    }
    audit.log("cloudrun_stop", {"run_id": run_id, "supervisor_alive": jobs.alive(pid)});
    return {"ok": True, "run": _view(r), "error": ""};
}

"""Respawn the supervisor with --resume. Only valid on a detached run (the
supervisor probes remote state and jumps to the right phase)."""
def reattach_run(run_id: str) -> dict {
    r = _find_run(run_id);
    if r is None { return _err("run not found"); }
    rd = _run_dir(r.name);
    st = _read_status(rd);
    pid = r.supervisor_pid;
    try {
        pid = int(str(st.get("supervisor_pid") or pid));
    } except Exception {}
    if not _is_detached(st, pid) {
        return _err("run is not detached (supervisor alive or run terminal)");
    }
    try {
        newpid = _spawn_supervisor(rd, "--resume");
    } except Exception as e {
        return _err(f"reattach spawn failed: {e}");
    }
    r.supervisor_pid = newpid;
    r.status = "running";
    audit.log("cloudrun_reattach", {"run_id": run_id, "supervisor_pid": newpid});
    return {"ok": True, "run": _view(r), "error": ""};
}

"""Re-pull artifacts for a finished run (short-lived --pull-only supervisor)."""
def pull_artifacts(run_id: str) -> dict {
    r = _find_run(run_id);
    if r is None { return _err("run not found"); }
    rd = _run_dir(r.name);
    st = _read_status(rd);
    pid = r.supervisor_pid;
    try {
        pid = int(str(st.get("supervisor_pid") or pid));
    } except Exception {}
    if jobs.alive(pid) { return _err("supervisor still running"); }
    try {
        newpid = _spawn_supervisor(rd, "--pull-only");
    } except Exception as e {
        return _err(f"pull spawn failed: {e}");
    }
    r.supervisor_pid = newpid;
    audit.log("cloudrun_pull", {"run_id": run_id, "supervisor_pid": newpid});
    return {"ok": True, "run": _view(r), "error": ""};
}
