"""Evals runner — detached jac eval jobs with SQLite history.

Evals are detached jac-run processes like builders; history is kept in SQLite;
the __EXIT__ marker in run.log is authoritative over pid liveness.
NO RAM guard vs chat/training — by user decision, do not add one.
"""

import os
import re
import shlex
import shutil
import signal
from pathlib import Path

import config
import db
import procs
import runlogs


def eval_dir(eval_id: int) -> Path:
    """Return (and create) the directory that stores artifacts for *eval_id*."""
    d = config.results_dir() / "_evals" / str(eval_id)
    d.mkdir(parents=True, exist_ok=True)
    return d


def start(
    kind: str,
    model_path_rel: str,
    adapter_rel: str | None,
    holdout_key: str,
    limit: int | None,
    sim_threshold: float | None,
    eval_id: int,
) -> int:
    """Spawn a detached eval job.  Returns the child pid."""
    ed = eval_dir(eval_id)
    run_log = ed / "run.log"
    metrics_out = ed / "metrics.jsonl"

    # Truncate the runlog so stale __EXIT__ markers from prior attempts are gone.
    run_log.write_text("")

    # Base env
    venv_bin = str(config.data_root() / ".venv" / "bin")
    current_path = os.environ.get("PATH", "")
    env: dict[str, str] = {
        "JAC_EVAL_MODE": "mlx",
        "JAC_EVAL_MODEL": model_path_rel,
        "JAC_HOLDOUT": config.HOLDOUTS[holdout_key],
        "PATH": f"{venv_bin}:{current_path}",
    }

    if adapter_rel:
        env["JAC_EVAL_ADAPTER"] = adapter_rel

    if kind == "probe":
        env["JAC_EVAL_METRICS_OUT"] = str(metrics_out)
        env["JAC_EVAL_STEP"] = "0"
        if limit is not None:
            env["JAC_EVAL_LIMIT"] = str(limit)
        script = "eval_probe.jac"
    else:  # idiom
        env["JAC_IDIOM_OUT"] = str(metrics_out)
        if sim_threshold is not None:
            env["JAC_IDIOM_SIM"] = str(sim_threshold)
        if limit is not None:
            env["JAC_EVAL_LIMIT"] = str(limit)
        script = "idiom_eval.jac"

    inner = f"{shlex.quote(str(config.jac_bin()))} run srccurrent/jacgen/{script}"
    cmd = procs.with_exit_marker(inner, run_log)

    pid = procs.spawn_detached(
        cmd,
        runlog=run_log,
        env=env,
        cwd=config.data_root(),
    )
    return pid


def refresh(row: dict) -> dict:
    """Refresh status for *row*; mutates DB if terminal.  Returns fresh row."""
    if row["status"] != "running":
        return row

    eval_id = row["id"]
    pid = row["pid"] or 0
    procs.reap(pid)

    ed = eval_dir(eval_id)
    run_log = ed / "run.log"
    metrics_path = ed / "metrics.jsonl"

    log_text = runlogs.tail(run_log, 80)
    m = re.search(r"__EXIT__ (\d+)", log_text)

    if m is not None:
        if m.group(1) == "0":
            scores = runlogs.last_row(metrics_path)
            if scores:
                db.finish_eval_run(eval_id, "done", scores)
            else:
                db.finish_eval_run(eval_id, "failed", None)
        else:
            db.finish_eval_run(eval_id, "failed", None)
    elif procs.alive(pid):
        pass  # still running — no DB update
    else:
        db.finish_eval_run(eval_id, "failed", None)

    return db.get_eval_run(eval_id)


def stop_eval(row: dict) -> dict:
    """Kill a running eval and mark it stopped.  Returns fresh row."""
    eval_id = row["id"]
    if row["status"] == "running":
        pid = row["pid"] or 0
        if pid > 0 and procs.alive(pid):
            try:
                os.killpg(os.getpgid(pid), signal.SIGTERM)
            except Exception:
                try:
                    os.kill(pid, signal.SIGTERM)
                except Exception:
                    pass
        db.finish_eval_run(eval_id, "stopped", None)
    return db.get_eval_run(eval_id)


def remove(row: dict) -> None:
    """Stop if running, delete DB row and artifact directory."""
    if row["status"] == "running":
        stop_eval(row)
    eval_id = row["id"]
    db.delete_eval_run(eval_id)
    shutil.rmtree(eval_dir(eval_id), ignore_errors=True)
