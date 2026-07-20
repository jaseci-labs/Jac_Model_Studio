"""studio - training job start/stop/status. Ports server/routers/train.py.

`def:pub` HTTP endpoints driving SFT / DPO runs. Detached-process lifecycle lives
in jobs.sv.jac (procs.py); log parsing in metrics.sv.jac (runlogs.py); paths +
registry in models.sv.jac (config.py). Job file:   results_dir()/<name>/.job-<mode>.json
run log:    results_dir()/<name>/run-<mode>.log
train log:  results_dir()/<name>/[dpo/]train.log

Checker notes (jaclang 0.16.1): live_status/read_job return dict|None → guard None;
dict values are `any` so the pid is `int(str(job.get("pid") or 0))` and status/started
go through `str(...)`; EXCLUDED_RUN_DIRS is a list[str] membership test.
"""

import time;
import shlex;
import auth;
import jobs;
import metrics;
import models;
import backends;
import workspace;
import from pathlib { Path }

# SFT/DPO option-key whitelists now live in studio.workspace.toml (workspace.sv.jac).

# All SFT/DPO artifacts resolve under the caller's per-user results dir so a
# tenant can only see/stop/delete their own training runs.
def _job_file(name: str, mode: str) -> Path {
    return auth.user_results_dir() / name / f".job-{mode}.json";
}

def _run_log(name: str, mode: str) -> Path {
    return auth.user_results_dir() / name / f"run-{mode}.log";
}

def _train_log(name: str, mode: str) -> Path {
    if mode == "dpo" {
        return auth.user_results_dir() / name / "dpo" / "train.log";
    }
    return auth.user_results_dir() / name / "train.log";
}

"""Build a JobStatus dict from the job file + live resolution (shape == _build_status)."""
def _build_status(name: str, mode: str, message: str = "") -> dict {
    jf = _job_file(name, mode);
    rl = _run_log(name, mode);
    job = jobs.live_status(jf, rl);
    if job is None {
        tl = _train_log(name, mode);
        status = "finished" if tl.exists() else "idle";
        return {
            "name": name,
            "mode": mode,
            "status": status,
            "pid": 0,
            "started": "",
            "last_iter": metrics.last_iter(tl),
            "log_tail": metrics.tail(rl, 40),
            "message": message
        };
    }
    return {
        "name": name,
        "mode": mode,
        "status": str(job.get("status", "idle")),
        "pid": int(str(job.get("pid") or 0)),
        "started": str(job.get("started", "")),
        "last_iter": metrics.last_iter(_train_log(name, mode)),
        "log_tail": metrics.tail(rl, 40),
        "message": message
    };
}

"""Start an SFT or DPO training run (detached). Returns the JobStatus dict."""
def start_training(name: str, mode: str, model_id: str = "", opts: dict = {}, backend: str = "") -> dict {
    if not jobs.safe(name) { raise ValueError("invalid name"); }
    if name in workspace.excluded_run_dirs() { raise ValueError("reserved name"); }
    if mode != "sft" and mode != "dpo" { raise ValueError("mode must be sft|dpo"); }
    if mode == "sft" {
        if not model_id or not jobs.safe(model_id, allow_slash=True) {
            raise ValueError("invalid model_id");
        }
    }

    jf = _job_file(name, mode);
    rl = _run_log(name, mode);
    existing = jobs.live_status(jf, rl);
    if existing is not None and str(existing.get("status")) == "running" {
        return _build_status(name, mode, "already running");
    }

    run_dir = auth.user_results_dir() / name;
    run_dir.mkdir(parents=True, exist_ok=True);

    rendered = backends.render({
        "backend": backend if backend else workspace.training_backend_default(),
        "method": mode,
        "vars": {"run_name": shlex.quote(name), "model_id": shlex.quote(model_id)},
        "opts": opts
    });
    env_overrides = dict(rendered["env"]);
    ignored: list = list(rendered.get("ignored_opts", []));
    msg = ("ignored opts: " + ", ".join(sorted(ignored))) if ignored else "started";
    inner = str(rendered["cmd"]);
    launch_cwd = Path(str(rendered["cwd"]));

    cmd = jobs.with_exit_marker(inner, rl);
    # Truncate the runlog so a previous run's __EXIT__ marker is erased; otherwise
    # live_status would instantly mark the new run as done.
    rl.write_text("");

<<<<<<<< HEAD:jms/train.sv.jac
    # The run scripts live in model-experiments/01-sft-dpo/sft_dpo/ (post-flatten layout); they
    # re-cd themselves to the repo root, so cwd=data_root stays correct.
    inner = "";
    if mode == "sft" {
        inner = f"./model-experiments/01-sft-dpo/sft_dpo/run_probe.sh {shlex.quote(model_id)} {shlex.quote(name)}";
    } else {
        inner = f"./model-experiments/01-sft-dpo/sft_dpo/run_dpo.sh {shlex.quote(name)}";
    }
========
    pid = jobs.spawn_detached(cmd, runlog=rl, env=env_overrides, cwd=launch_cwd);
>>>>>>>> origin/main:studio-desktop/train.sv.jac

    now = time.strftime("%Y-%m-%d %H:%M:%S");
    jobs.write_job(jf, {
        "name": name,
        "mode": mode,
        "backend": str(rendered["backend"]),
        "pid": pid,
        "status": "running",
        "started": now,
        "cmd": inner
    });

    return _build_status(name, mode, msg);
}

"""Stop a running training job (SIGTERM the process group). Returns JobStatus."""
def stop_training(name: str, mode: str) -> dict {
    if not jobs.safe(name) { raise ValueError("invalid name"); }
    if mode != "sft" and mode != "dpo" { raise ValueError("mode must be sft|dpo"); }
    jf = _job_file(name, mode);
    rl = _run_log(name, mode);
    jobs.stop(jf, rl);
    return _build_status(name, mode, "stop signal sent");
}

"""Poll status for a (name, mode) job. Returns JobStatus."""
def get_status(name: str, mode: str = "sft") -> dict {
    if not jobs.safe(name) { raise ValueError("invalid name"); }
    if mode != "sft" and mode != "dpo" { raise ValueError("mode must be sft|dpo"); }
    return _build_status(name, mode);
}

"""List every training session (SFT + DPO) across the caller's run dirs.
{"sessions": [...]} — scoped to the caller's per-user results tree."""
def list_sessions() -> dict {
    base = auth.user_results_dir();
    out: list = [];
    if not base.exists() { return {"sessions": out}; }
    for child in sorted(base.iterdir()) {
        if not child.is_dir() { continue; }
        if child.name in workspace.excluded_run_dirs() { continue; }
        nm = child.name;
        for mode in ["sft", "dpo"] {
            logp: Path = child / "dpo" / "train.log" if mode == "dpo" else child / "train.log";
            has_log = logp.exists();
            jf = _job_file(nm, mode);
            rl = _run_log(nm, mode);
            job = jobs.live_status(jf, rl);
            if not has_log and job is None { continue; }
            st = "finished";
            if job is not None {
                st = str(job.get("status", "idle"));
                if st == "idle" { st = "finished"; }
            }
            started = str(job.get("started", "")) if job is not None else "";
            out.append({
                "name": nm,
                "mode": mode,
                "status": st,
                "last_iter": metrics.last_iter(logp),
                "started": started,
                "label": f"{nm} · {mode.upper()}"
            });
        }
    }
    return {"sessions": out};
}
