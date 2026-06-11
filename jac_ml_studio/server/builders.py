"""Builder pipeline job management.

Ported from dashboard_app/services/jobs.sv.jac (run_builder / builder_status /
BUILDERS list).
"""

import os
import shlex
import time
from pathlib import Path

import config
import procs
import runlogs


BUILDERS: list[str] = [
    "seed_conversion",
    "idiomatic_batch",
    "idiomatic_batch2",
    "idiomatic_batch3",
    "scale_conversion",
    "dpo_conversion",
    "build_manifest",
    "build_splits",
    "build_dpo_splits",
    "holdout",
    "graph_holdout",
    "dataset_stats",
    "verify_dataset",
]


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _job_file(stage: str) -> Path:
    return config.results_dir() / "_builder" / f".job-{stage}.json"


def _run_log(stage: str) -> Path:
    return config.results_dir() / "_builder" / f"run-{stage}.log"


def _build_status(stage: str, message: str = "") -> dict:
    jf = _job_file(stage)
    rl = _run_log(stage)
    job = procs.live_status(jf, rl)
    if job is None:
        return {
            "stage": stage,
            "status": "idle",
            "pid": 0,
            "started": "",
            "log_tail": runlogs.tail(rl, 40),
            "message": message,
        }
    return {
        "stage": stage,
        "status": job.get("status", "idle"),
        "pid": int(job.get("pid") or 0),
        "started": str(job.get("started", "")),
        "log_tail": runlogs.tail(rl, 40),
        "message": message,
    }


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def run(stage: str) -> dict:
    """Spawn `jac run srccurrent/jacgen/<stage>.jac` as a detached builder job.

    Raises ValueError if *stage* is not in BUILDERS.
    Returns a status dict with message="already running" if the job is live.
    """
    if stage not in BUILDERS:
        raise ValueError(f"unknown builder stage: {stage!r}")

    jf = _job_file(stage)
    rl = _run_log(stage)

    # Check if already running
    existing = procs.live_status(jf, rl)
    if existing and existing.get("status") == "running":
        return _build_status(stage, "already running")

    # Ensure output directory exists
    (config.results_dir() / "_builder").mkdir(parents=True, exist_ok=True)

    # TRUNCATE the runlog so a stale __EXIT__ marker from a previous run is erased.
    # Without this, live_status would immediately mark the new run as done/failed.
    rl.write_text("")

    # Build command: jac run srccurrent/jacgen/<stage>.jac
    target = f"srccurrent/jacgen/{shlex.quote(stage)}.jac"
    inner_cmd = f"{shlex.quote(str(config.jac_bin()))} run {target}"
    cmd = procs.with_exit_marker(inner_cmd, rl)

    # Prepend .venv/bin to PATH so the subprocess finds the right jac
    venv_bin = str(config.data_root() / ".venv" / "bin")
    env_overrides = {"PATH": f"{venv_bin}:{os.environ.get('PATH', '')}"}

    pid = procs.spawn_detached(
        cmd,
        runlog=rl,
        env=env_overrides,
        cwd=config.data_root(),
    )

    now = time.strftime("%Y-%m-%d %H:%M:%S")
    procs.write_job(jf, {
        "name": stage,
        "mode": "builder",
        "pid": pid,
        "status": "running",
        "started": now,
        "cmd": inner_cmd,
    })

    return _build_status(stage, "started")


def status(stage: str) -> dict:
    """Return live status for *stage*.

    Raises ValueError if *stage* is not in BUILDERS.
    Returns status "idle" when no job file exists.
    """
    if stage not in BUILDERS:
        raise ValueError(f"unknown builder stage: {stage!r}")
    return _build_status(stage)


def all_status() -> list[dict]:
    """Return live status for all builder stages, in BUILDERS order."""
    return [_build_status(s) for s in BUILDERS]
