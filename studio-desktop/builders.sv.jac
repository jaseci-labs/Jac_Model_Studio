"""studio - builder pipeline job management. Ports server/builders.py.

The 13 dataset build stages are run as detached `jac run model-experiments/01-sft-dpo/sft_dpo/jacgen/<stage>.jac`
subprocesses via jobs.sv.jac (spawn_detached + with_exit_marker + write_job). Stage
status is resolved live from the run log's `__EXIT__` marker / pid liveness by
jobs.live_status; log tails come from metrics.tail. Endpoints are client-facing.

Checker notes (jaclang 0.16.1): job dict values are `any`, so pid goes through
int(str(...)); stage names are validated with jobs.safe before being embedded in
the shell command.
"""

import os;
import shlex;
import time;
import auth;
import jobs;
import metrics;
import models;
import paths;
import workspace;
import from pathlib { Path }

# Builder stage list now lives in studio.workspace.toml (workspace.sv.jac).

"""One builder stage as the client sees it: live status + recent log tail."""
obj BuilderView {
    has stage: str = "",
        status: str = "idle",
        pid: int = 0,
        started: str = "",
        log_tail: str = "",
        message: str = "";
}

def _job_file(stage: str) -> Path {
    return auth.user_results_dir() / "_builder" / f".job-{stage}.json";
}

def _run_log(stage: str) -> Path {
    return auth.user_results_dir() / "_builder" / f"run-{stage}.log";
}

def _build_status(stage: str, message: str = "") -> BuilderView {
    jf = _job_file(stage);
    rl = _run_log(stage);
    job = jobs.live_status(jf, rl);
    tail = metrics.tail(rl, 40);
    if job is None {
        return BuilderView(
            stage=stage, status="idle", pid=0, started="", log_tail=tail, message=message
        );
    }
    return BuilderView(
        stage=stage,
        status=str(job.get("status", "idle")),
        pid=int(str(job.get("pid") or 0)),
        started=str(job.get("started", "")),
        log_tail=tail,
        message=message
    );
}

"""Live status for all builder stages, in workspace order."""
def list_builders() -> list[BuilderView] {
    out: list[BuilderView] = [];
    for s in workspace.builder_stages() {
        out.append(_build_status(s));
    }
    return out;
}

"""Spawn `<jac_bin> run model-experiments/01-sft-dpo/sft_dpo/jacgen/<stage>.jac` as a detached builder job
(cwd = data root, .venv/bin prepended to PATH). No-op with message="already running"
if the job is live; the run log is truncated first so a stale __EXIT__ marker from a
previous run can't immediately mark the new run done/failed."""
def run_builder(stage: str) -> BuilderView {
    if stage not in workspace.builder_stages() {
        return BuilderView(stage=stage, status="idle", message=f"unknown builder stage: {stage}");
    }
    if not jobs.safe(stage) {
        return BuilderView(stage=stage, status="idle", message=f"invalid stage name: {stage}");
    }
    jf = _job_file(stage);
    rl = _run_log(stage);
    existing = jobs.live_status(jf, rl);
    if existing is not None and str(existing.get("status", "")) == "running" {
        return _build_status(stage, "already running");
    }
<<<<<<<< HEAD:jms/builders.sv.jac
    grab = jobs.heavy_acquire(f"builder:{stage}", jf, rl);
    if not grab["ok"] {
        return _build_status(stage, f"busy: {grab['busy_with']} is running");
    }
    target = f"model-experiments/01-sft-dpo/sft_dpo/jacgen/{shlex.quote(stage)}.jac";
========
    (auth.user_results_dir() / "_builder").mkdir(parents=True, exist_ok=True);
    # Erase any stale __EXIT__ marker from a prior run.
    rl.write_text("");
    target = paths.jacgen_stage(stage);
>>>>>>>> origin/main:studio-desktop/builders.sv.jac
    inner_cmd = f"{shlex.quote(str(models.jac_bin()))} run {target}";
    cmd = jobs.with_exit_marker(inner_cmd, rl);
    venv_bin = str(models.data_root() / ".venv" / "bin");
    env_overrides = {"PATH": f"{venv_bin}:{os.environ.get('PATH', '')}"};
    pid = jobs.spawn_detached(cmd, rl, env_overrides, models.data_root());
    now = time.strftime("%Y-%m-%d %H:%M:%S");
    jobs.write_job(jf, {
        "name": stage,
        "mode": "builder",
        "pid": pid,
        "status": "running",
        "started": now,
        "cmd": inner_cmd
    });
    return _build_status(stage, "started");
}

"""Live status for a single builder stage."""
def get_builder(stage: str) -> BuilderView {
    if stage not in workspace.builder_stages() {
        return BuilderView(stage=stage, status="idle", message=f"unknown builder stage: {stage}");
    }
    return _build_status(stage);
}
