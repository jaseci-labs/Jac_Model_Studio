"""studio - JMS TRAIN stage: LoRA finetuning on a project's curated dataset.

The ONLY module that touches a training backend for a JMS project. Two backends:

  local-mlx  A local mlx_lm.lora LoRA run under <project>/runs/<rid>/, driven by
             the detached-process jobs engine (jobs.sv.jac) exactly like
             cpt.sv.jac / train.sv.jac. Takes the GLOBAL heavy GPU lock
             (jobs.heavy_acquire) — this box has one GPU + 48 GB, so at most one
             heavy local job runs at a time. The base model must be an available
             LOCAL model (models registry → abs path). mlx_lm.lora is invoked with
             a JSON config file (valid YAML: yaml.load reads it) so LoRA rank/scale
             — which have no CLI flag — can be set; CLI has no rank flag.

  spheron    A remote Spheron VM run, delegated wholesale to cloudruns.sv.jac
             (P8). The CloudRun node owns the VM lifecycle; the JmsTrainRun node
             just carries `cloud_run_id` and proxies status/cost/phase through.
             NO heavy lock (the GPU is remote). base_model is a free-text HF id.
             The picked offer is REQUIRED (client sends it).

The JmsTrainRun node lives in jms_projects.sv.jac (same one-way-import precedent
as JmsGenJob) so get_project can list runs without importing this module. The
on-disk run dir + job files are the restart-surviving source of truth; the node
is the graph index, synced on terminal transitions by train_status.

mlx_lm.lora --data wants a DIRECTORY with train.jsonl + valid.jsonl. We build one
under runs/<rid>/data/ from the project's dataset/train.jsonl (+ holdout.jsonl as
valid; if holdout is empty we reserve the last VALID_FRACTION% of train, min 1
row — train stays whole since tiny sets can't spare rows). The same built pair
(abs paths) is what the spheron branch hands cloudruns as its dataset.

Checker notes (jaclang 0.16.1): dict values are `any` → int(str(...)) /
float(str(...)); `++>` returns a list → unwrap [0]; live_status/run_status can
return None/error dicts → guard them.
"""

import json;
import os;
import shlex;
import datetime;
import auth;
import jobs;
import metrics;
import models;
import paths;
import cloudruns;
import from pathlib { Path }
import from uuid { uuid4 }
import from jms_projects {
    JmsProject, JmsTrainRun,
    _find_project, _train_runs_of, jms_project_dir, _adapter_on_disk
}

glob DEFAULT_ITERS: int = 200;
glob DEFAULT_BATCH: int = 1;
glob DEFAULT_LR: str = "1e-5";
glob DEFAULT_NUM_LAYERS: int = 16;
glob DEFAULT_LORA_R: int = 8;
glob DEFAULT_LORA_SCALE: str = "16.0";   # mlx's lora_parameters.scale (~alpha)
glob VALID_FRACTION: int = 10;           # % of train reserved as valid when holdout empty
glob _CONTROL_KEYS: list[str] = ["offer", "launch_cmd_override", "ssh_key_id", "ssh_override", "policy"];

def _now() -> str {
    return datetime.datetime.now(datetime.UTC).replace(tzinfo=None).isoformat() + "Z";
}

# ------------------------------------------------------------------- paths -----
def _run_dir(p: JmsProject, rid: str) -> Path {
    return jms_project_dir(p.slug) / "runs" / rid;
}

def _job_file(p: JmsProject, rid: str) -> Path {
    return _run_dir(p, rid) / ".job-train.json";
}

def _run_log(p: JmsProject, rid: str) -> Path {
    return _run_dir(p, rid) / "run.log";
}

def _data_dir(p: JmsProject, rid: str) -> Path {
    return _run_dir(p, rid) / "data";
}

def _adapter_dir(p: JmsProject, rid: str) -> Path {
    return _run_dir(p, rid) / "adapter";
}

def _config_file(p: JmsProject, rid: str) -> Path {
    return _run_dir(p, rid) / "mlx_config.json";
}

def _dataset_dir(p: JmsProject) -> Path {
    return jms_project_dir(p.slug) / "dataset";
}

"""cloudruns names the spheron run jms-<slug>-<rid>; its run dir (adapter +
metrics mirror) is under auth.user_results_dir()/<name>."""
def _cloud_name(p: JmsProject, rid: str) -> str {
    return f"jms-{p.slug}-{rid}";
}

def _cloud_dir(p: JmsProject, rid: str) -> Path {
    return auth.user_results_dir() / _cloud_name(p, rid);
}

def _find_run(p: JmsProject, rid: str) -> JmsTrainRun | None {
    for r in _train_runs_of(p) {
        if r.rid == rid { return r; }
    }
    return None;
}

def _nonblank(p: Path) -> list[str] {
    if not p.exists() { return []; }
    try {
        return [ln for ln in p.read_text().split("\n") if ln.strip()];
    } except Exception {
        return [];
    }
}

# --------------------------------------------------------------- data prep -----
"""Build the mlx data dir (train.jsonl + valid.jsonl) mlx_lm.lora --data needs.
valid = holdout.jsonl when non-empty, else the last VALID_FRACTION% (min 1) rows
of train (train stays whole — tiny sets can't spare rows). Returns
{train, valid, split_from_train, dir}."""
def _prepare_data(p: JmsProject, rid: str) -> dict {
    ds = _dataset_dir(p);
    train_lines = _nonblank(ds / "train.jsonl");
    valid_lines = _nonblank(ds / "holdout.jsonl");
    split = False;
    if len(valid_lines) == 0 and len(train_lines) > 0 {
        k = max(1, len(train_lines) * VALID_FRACTION // 100);
        valid_lines = train_lines[len(train_lines) - k:];
        split = True;
    }
    dd = _data_dir(p, rid);
    dd.mkdir(parents=True, exist_ok=True);
    (dd / "train.jsonl").write_text(("\n".join(train_lines) + "\n") if train_lines else "");
    (dd / "valid.jsonl").write_text(("\n".join(valid_lines) + "\n") if valid_lines else "");
    return {"train": len(train_lines), "valid": len(valid_lines), "split_from_train": split, "dir": str(dd)};
}

# ------------------------------------------------------------- status mapping --
"""jobs.live_status status → unified run status."""
def _map_local(s: str) -> str {
    if s == "done" { return "completed"; }
    if s in ["failed", "stopped", "running"] { return s; }
    return "running";
}

"""cloudruns run status → unified run status (detached still counts as running)."""
def _map_cloud(s: str) -> str {
    if s == "done" { return "completed"; }
    if s == "detached" { return "running"; }
    if s in ["failed", "stopped", "running"] { return s; }
    return "running";
}

def _cfg_iters(r: JmsTrainRun) -> int {
    if r.cfg_json {
        try {
            c = dict(json.loads(r.cfg_json));
            return int(str(c.get("iters", 0)));
        } except Exception {}
    }
    return 0;
}

# ----------------------------------------------------------------- endpoints ---
"""Start a LoRA finetune on a project's curated dataset. Guards: train.jsonl
exists non-empty, backend ∈ {local-mlx, spheron}, no other run already running on
this project. local-mlx additionally needs an available local base model + the
free heavy GPU lock; spheron needs opts.offer. `opts`:

  common:   iters, batch_size, learning_rate, num_layers, lora_r, lora_alpha
  spheron:  offer (REQUIRED {offer_id, gpu_type, gpu_count, region, os?,
            instance_type?, hourly_rate, provider?}), ssh_key_id?, ssh_override?,
            policy?, launch_cmd_override? (dev/test bypass, forwarded to cloudruns)

Returns {ok, rid, run, error} — run is the train_status dict."""
def start_train(pid: str, backend: str, base_model: str, opts: dict = {}) -> dict {
    p = _find_project(pid);
    if p is None { return {"ok": False, "rid": "", "error": "unknown project"}; }
    if backend not in ["local-mlx", "spheron"] {
        return {"ok": False, "rid": "", "error": "backend must be local-mlx or spheron"};
    }
    if len(_nonblank(_dataset_dir(p) / "train.jsonl")) == 0 {
        return {"ok": False, "rid": "", "error": "no training data — materialize a train split first"};
    }
    # One training run per project at a time (live-resolved so a stale node from a
    # server restart doesn't wedge the project forever).
    for existing in _train_runs_of(p) {
        if existing.status == "running" {
            live = _live_status(p, existing);
            if str(live.get("status", "")) == "running" {
                return {"ok": False, "rid": "", "error": f"a run is already training ({existing.rid})"};
            }
        }
    }
    if not base_model or not jobs.safe(base_model, allow_slash=True) {
        return {"ok": False, "rid": "", "error": "invalid base_model"};
    }

    rid = uuid4().hex[:12];
    run_dir = _run_dir(p, rid);
    run_dir.mkdir(parents=True, exist_ok=True);

    if backend == "local-mlx" {
        return _start_local(p, rid, base_model, opts);
    }
    return _start_spheron(p, rid, base_model, opts);
}

"""Pure mlx_lm.lora config builder (valid YAML == JSON). LoRA rank/scale have no
CLI flag, so they ride in the config file. steps_per_eval/save_every are pinned to
`iters` so a tiny dataset never triggers a mid-run eval that would crash on too
few valid rows. Kept pure so tests can assert flags/paths without spawning."""
def _mlx_config(model_path: str, datadir: str, adapter_dir: str, opts: dict) -> dict {
    iters = int(str(opts.get("iters", DEFAULT_ITERS)));
    batch = int(str(opts.get("batch_size", DEFAULT_BATCH)));
    num_layers = int(str(opts.get("num_layers", DEFAULT_NUM_LAYERS)));
    lora_r = int(str(opts.get("lora_r", DEFAULT_LORA_R)));
    lr = 1e-5;
    try { lr = float(str(opts.get("learning_rate", DEFAULT_LR))); } except Exception { lr = 1e-5; }
    scale = 16.0;
    try { scale = float(str(opts.get("lora_alpha", DEFAULT_LORA_SCALE))); } except Exception { scale = 16.0; }
    return {
        "model": model_path,
        "train": True,
        "fine_tune_type": "lora",
        "data": datadir,
        "adapter_path": adapter_dir,
        "iters": iters,
        "batch_size": batch,
        "learning_rate": lr,
        "num_layers": num_layers,
        "steps_per_report": 1,
        "steps_per_eval": max(iters, 1),
        "val_batches": 1,
        "save_every": max(iters, 1),
        "max_seq_length": 2048,
        "lora_parameters": {"rank": lora_r, "scale": scale, "dropout": 0.0}
    };
}

"""local-mlx: build the mlx data dir + JSON config, grab the heavy lock, spawn
mlx_lm.lora detached. Base model must be an available LOCAL model."""
def _start_local(p: JmsProject, rid: str, base_model: str, opts: dict) -> dict {
    m = models.model_by_id(base_model);
    if not m or not models.model_available(m) {
        return {"ok": False, "rid": "", "error": f"local model not available: {base_model}"};
    }
    model_path = str(models.model_path(m));

    prep = _prepare_data(p, rid);
    if int(str(prep["valid"])) == 0 {
        return {"ok": False, "rid": "", "error": "no rows to train on"};
    }

    adapter_dir = _adapter_dir(p, rid);
    adapter_dir.mkdir(parents=True, exist_ok=True);

    mlx_cfg = _mlx_config(model_path, str(prep["dir"]), str(adapter_dir), opts);
    iters = int(str(mlx_cfg["iters"]));
    cfg_file = _config_file(p, rid);
    cfg_file.write_text(json.dumps(mlx_cfg, indent=2));

    jf = _job_file(p, rid);
    rl = _run_log(p, rid);

    # One heavy local job at a time (shared GPU). Self-heals from the job file.
    grab = jobs.heavy_acquire(f"jmstrain:{rid}", jf, rl);
    if not grab["ok"] {
        return {"ok": False, "rid": "", "error": f"GPU busy: {grab['busy_with']} is running"};
    }

    venv_bin = str(paths.data_root() / ".venv" / "bin");
    env: dict = {};
    if (paths.data_root() / ".venv" / "bin").is_dir() {
        env["PATH"] = f"{venv_bin}:{os.environ.get('PATH', '')}";
    }
    inner = f"mlx_lm.lora --config {shlex.quote(str(cfg_file))}";
    rl.write_text("");   # erase any stale __EXIT__ marker
    cmd = jobs.with_exit_marker(inner, rl);

    pid_child = 0;
    try {
        pid_child = jobs.spawn_detached(cmd, runlog=rl, env=env, cwd=_run_dir(p, rid));
    } except Exception as e {
        jobs.heavy_release(f"jmstrain:{rid}");
        return {"ok": False, "rid": "", "error": f"spawn failed: {str(e)[:200]}"};
    }

    jobs.write_job(jf, {
        "name": f"jmstrain-{rid}", "mode": "jms_train", "pid": pid_child,
        "status": "running", "started": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "cmd": inner
    });

    lora_p = dict(mlx_cfg["lora_parameters"]);
    cfg_json = json.dumps({
        "iters": iters, "batch_size": int(str(mlx_cfg["batch_size"])),
        "learning_rate": float(str(mlx_cfg["learning_rate"])),
        "num_layers": int(str(mlx_cfg["num_layers"])),
        "lora_r": int(str(lora_p["rank"])), "lora_scale": float(str(lora_p["scale"])),
        "data": prep
    });
    p ++> JmsTrainRun(
        rid=rid, backend="local-mlx", base_model=base_model, status="running",
        cfg_json=cfg_json, adapter_path=str(adapter_dir), started=_now()
    );
    return {"ok": True, "rid": rid, "run": train_status(p.pid, rid), "error": ""};
}

"""spheron: build the mlx data pair, then delegate to cloudruns.start_remote_run.
offer is REQUIRED. The built train/valid abs paths become cfg.dataset (cloudruns
accepts abs paths — they satisfy jobs.safe + paths.resolve). NO heavy lock."""
def _start_spheron(p: JmsProject, rid: str, base_model: str, opts: dict) -> dict {
    offer_raw = opts.get("offer");
    if not isinstance(offer_raw, dict) or len(dict(offer_raw)) == 0 {
        return {"ok": False, "rid": "", "error": "offer required — pick a GPU offer"};
    }
    prep = _prepare_data(p, rid);
    if int(str(prep["valid"])) == 0 {
        return {"ok": False, "rid": "", "error": "no rows to train on"};
    }
    train_abs = str(_data_dir(p, rid) / "train.jsonl");
    valid_abs = str(_data_dir(p, rid) / "valid.jsonl");

    passthrough: dict = {};
    for k in opts {
        if str(k) not in _CONTROL_KEYS { passthrough[str(k)] = opts[k]; }
    }

    cfg: dict = {
        "name": _cloud_name(p, rid),
        "mode": "sft",
        "base_model": base_model,
        "offer": dict(offer_raw),
        "opts": passthrough,
        "dataset": {"train_rel": train_abs, "valid_rel": valid_abs}
    };
    for k in ["ssh_key_id", "ssh_override", "policy", "launch_cmd_override"] {
        if k in opts { cfg[k] = opts[k]; }
    }

    res = cloudruns.start_remote_run(cfg);
    if not bool(res["ok"]) {
        return {"ok": False, "rid": "", "error": str(res["error"])};
    }
    run = dict(res["run"]);
    cloud_run_id = str(run.get("run_id", ""));

    cfg_json = json.dumps({
        "iters": int(str(opts.get("max_steps", opts.get("iters", 0)))),
        "offer": dict(offer_raw), "data": prep
    });
    p ++> JmsTrainRun(
        rid=rid, backend="spheron", base_model=base_model, status="running",
        cfg_json=cfg_json, adapter_path="", cloud_run_id=cloud_run_id, started=_now()
    );
    return {"ok": True, "rid": rid, "run": train_status(p.pid, rid), "error": ""};
}

# ------------------------------------------------------------- status readers --
"""Coarse live status (no log tail) used by the already-running guard + list.
Syncs the node on terminal transitions. Returns {"status": ...}."""
def _live_status(p: JmsProject, r: JmsTrainRun) -> dict {
    if r.backend == "spheron" {
        cs = cloudruns.run_status(r.cloud_run_id);
        if not bool(cs["ok"]) { return {"status": r.status}; }
        st = _map_cloud(str(dict(cs["run"]).get("status", "running")));
        _sync_terminal(p, r, st, _adapter_on_disk(str(_cloud_dir(p, r.rid) / "adapter")), str(_cloud_dir(p, r.rid) / "adapter"));
        return {"status": st};
    }
    live = jobs.live_status(_job_file(p, r.rid), _run_log(p, r.rid));
    st = r.status;
    if live is not None { st = _map_local(str(live.get("status", r.status))); }
    _sync_terminal(p, r, st, _adapter_on_disk(str(_adapter_dir(p, r.rid))), str(_adapter_dir(p, r.rid)));
    return {"status": st};
}

"""Sync a node to a terminal status once (records finished, adapter_path, and —
local only — releases the heavy GPU lock)."""
def _sync_terminal(p: JmsProject, r: JmsTrainRun, status: str, ready: bool, adir: str) -> None {
    if r.status == "running" and status != "running" {
        r.status = status;
        r.finished = _now();
        if ready or status == "completed" { r.adapter_path = adir; }
        if r.backend == "local-mlx" { jobs.heavy_release(f"jmstrain:{r.rid}"); }
    } elif ready and not r.adapter_path {
        r.adapter_path = adir;
    }
}

"""Poll one run — unified shape across both backends:
{rid, backend, base_model, status, log_tail, metrics: [{x,y}], val_metrics,
 lr_metrics, progress: {last_iter, total_iters}, cost?, phase?, adapter_path,
 adapter_ready, cloud_run_id, error, started, finished}."""
def train_status(pid: str, rid: str) -> dict {
    p = _find_project(pid);
    if p is None { return {"error": "unknown project"}; }
    r = _find_run(p, rid);
    if r is None { return {"error": "unknown run"}; }
    if r.backend == "spheron" { return _spheron_status(p, r); }
    return _local_status(p, r);
}

def _base(r: JmsTrainRun) -> dict {
    return {
        "rid": r.rid, "backend": r.backend, "base_model": r.base_model,
        "cloud_run_id": r.cloud_run_id, "started": r.started, "finished": r.finished
    };
}

def _local_status(p: JmsProject, r: JmsTrainRun) -> dict {
    rl = _run_log(p, r.rid);
    jf = _job_file(p, r.rid);
    live = jobs.live_status(jf, rl);
    status = r.status;
    if live is not None { status = _map_local(str(live.get("status", r.status))); }
    adir = str(_adapter_dir(p, r.rid));
    ready = _adapter_on_disk(adir);
    _sync_terminal(p, r, status, ready, adir);
    ready = _adapter_on_disk(str(r.adapter_path)) if r.adapter_path else ready;

    parsed = metrics.parse_train_log(rl);
    err = "";
    if status == "failed" { err = _tail_error(rl); }
    out = _base(r);
    out["status"] = status;
    out["log_tail"] = metrics.tail(rl, 40);
    out["metrics"] = parsed["train"];
    out["val_metrics"] = parsed["val"];
    out["lr_metrics"] = parsed["lr"];
    out["progress"] = {"last_iter": parsed["last_iter"], "total_iters": _cfg_iters(r)};
    out["cost"] = {};
    out["phase"] = "";
    out["adapter_path"] = r.adapter_path;
    out["adapter_ready"] = ready;
    out["error"] = err;
    return out;
}

def _spheron_status(p: JmsProject, r: JmsTrainRun) -> dict {
    cs = cloudruns.run_status(r.cloud_run_id);
    out = _base(r);
    if not bool(cs["ok"]) {
        out["status"] = r.status;
        out["log_tail"] = "";
        out["metrics"] = [];
        out["val_metrics"] = [];
        out["lr_metrics"] = [];
        out["progress"] = {"last_iter": 0, "total_iters": _cfg_iters(r)};
        out["cost"] = {};
        out["phase"] = "";
        out["adapter_path"] = r.adapter_path;
        out["adapter_ready"] = _adapter_on_disk(str(r.adapter_path));
        out["error"] = str(cs["error"]);
        return out;
    }
    run = dict(cs["run"]);
    status = _map_cloud(str(run.get("status", "running")));
    adir = str(_cloud_dir(p, r.rid) / "adapter");
    ready = _adapter_on_disk(adir);
    _sync_terminal(p, r, status, ready, adir);

    mfile = _cloud_dir(p, r.rid) / "metrics.jsonl";
    out["status"] = status;
    out["log_tail"] = str(run.get("log_tail", ""));
    out["metrics"] = metrics.read_series(mfile, "loss");
    out["val_metrics"] = metrics.read_series(mfile, "eval_loss");
    out["lr_metrics"] = [];
    prog_raw = run.get("progress");
    out["progress"] = dict(prog_raw) if isinstance(prog_raw, dict) else {};
    cost_raw = run.get("cost");
    out["cost"] = dict(cost_raw) if isinstance(cost_raw, dict) else {};
    out["phase"] = str(run.get("phase", ""));
    out["adapter_path"] = r.adapter_path;
    out["adapter_ready"] = _adapter_on_disk(str(r.adapter_path)) if r.adapter_path else ready;
    out["error"] = str(run.get("error", ""));
    return out;
}

"""Last non-blank log line mentioning an error (best-effort), else the last line."""
def _tail_error(rl: Path) -> str {
    lines = _nonblank(rl);
    if not lines { return ""; }
    for ln in reversed(lines) {
        low = ln.lower();
        if "error" in low or "traceback" in low or "exception" in low {
            return ln[:200];
        }
    }
    return str(lines[-1])[:200];
}

"""Stop a running run: spheron → cloudruns graceful stop; local → SIGTERM the job
group + release the heavy lock. Returns the fresh train_status."""
def stop_train(pid: str, rid: str) -> dict {
    p = _find_project(pid);
    if p is None { return {"error": "unknown project"}; }
    r = _find_run(p, rid);
    if r is None { return {"error": "unknown run"}; }
    if r.backend == "spheron" {
        cloudruns.stop_run(r.cloud_run_id);
    } else {
        jobs.stop(_job_file(p, rid), _run_log(p, rid));
        jobs.heavy_release(f"jmstrain:{rid}");
    }
    return train_status(pid, rid);
}

"""All of a project's train runs, newest first, each live-resolved (with log tails
+ metrics — a handful of runs per project, polled by the client)."""
def list_train_runs(pid: str) -> list[dict] {
    p = _find_project(pid);
    if p is None { return []; }
    out: list[dict] = [];
    for r in _train_runs_of(p) { out.append(train_status(pid, r.rid)); }
    out.sort(key=lambda d: dict -> str { return str(d.get("started", "")); }, reverse=True);
    return out;
}
