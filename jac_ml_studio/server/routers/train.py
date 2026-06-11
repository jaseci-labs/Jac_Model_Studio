"""Training job start/stop/status. Port of dashboard_app/services/jobs.sv.jac."""

import os
import time
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

import config
import procs
import runlogs

router = APIRouter(prefix="/api/train")

SFT_KEYS = ["EVAL_EVERY", "SUBSET", "DRY_ITERS", "SKIP_DRY", "LIVE_EVAL"]
DPO_KEYS = ["DPO_ITERS", "DPO_LR", "DPO_BETA", "DPO_LAYERS", "SUBSET"]


# ---------------------------------------------------------------------------
# Pydantic models
# ---------------------------------------------------------------------------

class StartRequest(BaseModel):
    model_config = {"protected_namespaces": ()}
    model_id: str | None = None
    name: str
    mode: str
    opts: dict[str, str] = {}


class StopRequest(BaseModel):
    name: str
    mode: str


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _job_file(name: str, mode: str) -> Path:
    return config.results_dir() / name / f".job-{mode}.json"


def _run_log(name: str, mode: str) -> Path:
    return config.results_dir() / name / f"run-{mode}.log"


def _train_log(name: str, mode: str) -> Path:
    if mode == "dpo":
        return config.results_dir() / name / "dpo" / "train.log"
    return config.results_dir() / name / "train.log"


def _build_status(name: str, mode: str, message: str = "") -> dict:
    """Build a JobStatus dict from the job file + live resolution."""
    jf = _job_file(name, mode)
    rl = _run_log(name, mode)
    job = procs.live_status(jf, rl)
    if job is None:
        # No job file — check if a train.log exists (CLI/finished run)
        tl = _train_log(name, mode)
        if tl.exists():
            status = "finished"
        else:
            status = "idle"
        return {
            "name": name,
            "mode": mode,
            "status": status,
            "pid": 0,
            "started": "",
            "last_iter": runlogs.last_iter(tl),
            "log_tail": runlogs.tail(rl, 40),
            "message": message,
        }
    return {
        "name": name,
        "mode": mode,
        "status": job.get("status", "idle"),
        "pid": int(job.get("pid", 0)),
        "started": str(job.get("started", "")),
        "last_iter": runlogs.last_iter(_train_log(name, mode)),
        "log_tail": runlogs.tail(rl, 40),
        "message": message,
    }


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@router.post("/start")
def start_training(body: StartRequest):
    """Start an SFT or DPO training run."""
    name = body.name
    mode = body.mode
    model_id = body.model_id

    # Validate name
    if not procs.safe(name):
        raise HTTPException(400, "invalid name")
    # Validate mode
    if mode not in ("sft", "dpo"):
        raise HTTPException(400, "mode must be sft|dpo")
    # Validate model_id for SFT
    if mode == "sft":
        if not model_id or not procs.safe(model_id, allow_slash=True):
            raise HTTPException(400, "invalid model_id")

    # Check if already running
    jf = _job_file(name, mode)
    rl = _run_log(name, mode)
    existing = procs.live_status(jf, rl)
    if existing and existing.get("status") == "running":
        return _build_status(name, mode, "already running")

    # Create results dir
    run_dir = config.results_dir() / name
    run_dir.mkdir(parents=True, exist_ok=True)

    # Build env from whitelist
    keys = SFT_KEYS if mode == "sft" else DPO_KEYS
    env_overrides: dict[str, str] = {}
    for k in keys:
        if k in body.opts:
            val = body.opts[k]
            if procs.safe(val):
                env_overrides[k] = val

    # Prepend venv bin to PATH
    venv_bin = str(config.data_root() / ".venv" / "bin")
    current_path = os.environ.get("PATH", "")
    env_overrides["PATH"] = f"{venv_bin}:{current_path}"

    # Build command
    import shlex
    if mode == "sft":
        inner = f"./run_probe.sh {shlex.quote(model_id)} {shlex.quote(name)}"
    else:
        inner = f"./run_dpo.sh {shlex.quote(name)}"

    cmd = procs.with_exit_marker(inner, _run_log(name, mode))

    # Spawn
    pid = procs.spawn_detached(
        cmd,
        runlog=_run_log(name, mode),
        env=env_overrides,
        cwd=config.data_root(),
    )

    # Write job file
    now = time.strftime("%Y-%m-%d %H:%M:%S")
    procs.write_job(jf, {
        "name": name,
        "mode": mode,
        "pid": pid,
        "status": "running",
        "started": now,
        "cmd": inner,
    })

    return _build_status(name, mode, "started")


@router.post("/stop")
def stop_training(body: StopRequest):
    """Stop a running training job."""
    name = body.name
    mode = body.mode
    if not procs.safe(name):
        raise HTTPException(400, "invalid name")
    if mode not in ("sft", "dpo"):
        raise HTTPException(400, "mode must be sft|dpo")
    jf = _job_file(name, mode)
    procs.stop(jf)
    return _build_status(name, mode, "stop signal sent")


@router.get("/status")
def get_status(name: str, mode: str = "sft"):
    """Poll status for a (name, mode) job."""
    if not procs.safe(name):
        raise HTTPException(400, "invalid name")
    if mode not in ("sft", "dpo"):
        raise HTTPException(400, "mode must be sft|dpo")
    return _build_status(name, mode)


@router.get("/sessions")
def list_sessions():
    """List all training sessions across all runs."""
    base = config.results_dir()
    out = []
    if not base.exists():
        return {"sessions": out}
    for child in sorted(base.iterdir()):
        if not child.is_dir():
            continue
        if child.name in config.EXCLUDED_RUN_DIRS:
            continue
        nm = child.name
        for mode in ("sft", "dpo"):
            if mode == "dpo":
                logp = child / "dpo" / "train.log"
            else:
                logp = child / "train.log"
            has_log = logp.exists()
            jf = _job_file(nm, mode)
            rl = _run_log(nm, mode)
            job = procs.live_status(jf, rl)
            if not has_log and job is None:
                continue
            if job is None:
                st = "finished"
            else:
                st = job.get("status", "idle")
                if st == "idle":
                    st = "finished"
            out.append({
                "name": nm,
                "mode": mode,
                "status": st,
                "last_iter": runlogs.last_iter(logp),
                "started": str(job.get("started", "")) if job else "",
                "label": f"{nm} · {mode.upper()}",
            })
    return {"sessions": out}
