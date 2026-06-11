"""Read-only training-run metrics. Port of dashboard_app/services/runs.sv.jac."""

from pathlib import Path

from fastapi import APIRouter, HTTPException

import config
import procs
import runlogs

router = APIRouter(prefix="/api/runs")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _run_dir(name: str) -> Path:
    return config.results_dir() / name


def _is_running(name: str) -> bool:
    """Return True if either the SFT or DPO job file shows status "running"."""
    for mode in ("sft", "dpo"):
        jf = config.results_dir() / name / f".job-{mode}.json"
        runlog = config.results_dir() / name / f"run-{mode}.log"
        job = procs.live_status(jf, runlog)
        if job and job.get("status") == "running":
            return True
    return False


def _get_run_metrics(name: str, mode: str) -> dict:
    """Build the RunMetrics dict for a single run (port of get_run_metrics)."""
    rdir = _run_dir(name)
    if mode == "dpo":
        log = rdir / "dpo" / "train.log"
        curve_path = None
    else:
        log = rdir / "train.log"
        curve_path = rdir / "metrics.jsonl"

    idiom_path = runlogs.pick_idiom(rdir, mode)
    idiom_label = ""
    if idiom_path is not None:
        # Derive label from filename (matches jac source)
        if "graph-idiom" in idiom_path.name:
            idiom_label = "graph holdout"
        else:
            idiom_label = "function holdout"

    t = runlogs.parse_train_log(log)
    curve = runlogs.read_series(curve_path, "test_pass_pct") if curve_path else []
    isum = runlogs.last_row(idiom_path) if idiom_path else {}
    isum = isum or {}

    idiom_sim = runlogs.read_series(idiom_path, "avg_sim") if idiom_path else []

    # Determine running status
    jf_sft = config.results_dir() / name / ".job-sft.json"
    jf_dpo = config.results_dir() / name / ".job-dpo.json"
    runlog_sft = config.results_dir() / name / "run-sft.log"
    runlog_dpo = config.results_dir() / name / "run-dpo.log"
    running = False
    if mode == "sft":
        j = procs.live_status(jf_sft, runlog_sft)
        running = bool(j and j.get("status") == "running")
    else:
        j = procs.live_status(jf_dpo, runlog_dpo)
        running = bool(j and j.get("status") == "running")

    return {
        "name": name,
        "mode": mode,
        "found": log.exists(),
        "running": running,
        "last_iter": t["last_iter"],
        "train": t["train"],
        "val": t["val"],
        "lr": t["lr"],
        "tps": t["tps"],
        "curve": curve,
        "idiom_sim": idiom_sim,
        "has_idiom": "avg_sim" in isum,
        "idiom_label": idiom_label,
        "idiom_avg_sim": float(isum.get("avg_sim", 0.0)),
        "idiom_idiomatic": int(isum.get("idiomatic", 0)),
        "idiom_python": int(isum.get("python_shaped", 0)),
        "idiom_runs": int(isum.get("runs", 0)),
        "idiom_total": int(isum.get("total", 0)),
        "log_tail": runlogs.tail(log, 40),
    }


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@router.get("")
def list_runs():
    """List all runs with summary info."""
    base = config.results_dir()
    out = []
    if not base.exists():
        return {"runs": out}
    for child in sorted(base.iterdir()):
        if not child.is_dir():
            continue
        if child.name in config.EXCLUDED_RUN_DIRS:
            continue
        rdir = child
        has_sft = (rdir / "train.log").exists() or (rdir / ".train.done").exists()
        has_dpo = (rdir / "dpo").exists()
        out.append({
            "name": child.name,
            "has_sft": has_sft,
            "has_dpo": has_dpo,
            "stages": runlogs.stages(rdir),
            "running": _is_running(child.name),
        })
    return {"runs": out}


@router.get("/compare")
def compare_runs(mode: str = "sft"):
    """Overlay every run's curves for the given mode + per-run headline numbers."""
    if mode not in ("sft", "dpo"):
        raise HTTPException(400, "mode must be sft|dpo")
    base = config.results_dir()
    names = []
    trains = {}
    vals = {}
    curves = {}
    headline = []
    if base.exists():
        for child in sorted(base.iterdir()):
            if not child.is_dir():
                continue
            if child.name in config.EXCLUDED_RUN_DIRS:
                continue
            m = _get_run_metrics(child.name, mode)
            if not m["found"]:
                continue
            name = child.name
            names.append(name)
            trains[name] = m["train"]
            vals[name] = m["val"]
            curves[name] = m["curve"]
            # last_y helper
            def _last_y(series):
                if not series:
                    return 0.0
                return float(series[-1]["y"])
            headline.append({
                "name": name,
                "final_pass": _last_y(m["curve"]),
                "last_loss": _last_y(m["train"]),
                "idiom_sim": m["idiom_avg_sim"],
                "idiomatic": m["idiom_idiomatic"],
                "idiom_label": m["idiom_label"],
                "has_idiom": m["has_idiom"],
            })
    return {
        "names": names,
        "train": runlogs.merge_by_x(trains),
        "val": runlogs.merge_by_x(vals),
        "curve": runlogs.merge_by_x(curves),
        "headline": headline,
    }


@router.get("/{name}")
def get_run(name: str, mode: str = "sft"):
    """Get full metrics for one run."""
    if not procs.safe(name):
        raise HTTPException(400, "invalid run name")
    if mode not in ("sft", "dpo"):
        raise HTTPException(400, "mode must be sft|dpo")
    return _get_run_metrics(name, mode)
