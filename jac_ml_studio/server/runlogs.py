"""Pure parsers for training artifacts. Ported from dashboard_app/services/runs.sv.jac."""
import json
import re
from pathlib import Path


# ---------------------------------------------------------------------------
# Internal helpers (mirrors _num / _num2 / _pt from runs.sv.jac)
# ---------------------------------------------------------------------------

def _num(line: str, pattern: str) -> float:
    """Return first captured float from *line* or -1.0 if not found."""
    m = re.search(pattern, line)
    if m is None:
        return -1.0
    return float(m.group(1))


def _num2(line: str, p1: str, p2: str) -> float:
    """Try SFT pattern first, then DPO pattern; return -1.0 if neither matches."""
    v = _num(line, p1)
    if v >= 0.0:
        return v
    return _num(line, p2)


def _pt(it: int, v: float) -> dict:
    return {"x": it, "y": v}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def parse_train_log(path: Path) -> dict:
    """Parse an mlx trainer log into chart-ready series.

    Handles both SFT (mlx_lm.lora) and DPO trainer formats in the same pass.

    Returns dict with keys: train, val, lr, tps (each list[{x,y}]) and last_iter (int).
    """
    empty = {"train": [], "val": [], "lr": [], "tps": [], "last_iter": 0}
    if not path.exists():
        return empty

    train: list = []
    val: list = []
    lr: list = []
    tps: list = []
    last_it: int = 0

    for line in path.read_text().split("\n"):
        m = re.search(r"Iter (\d+)", line)
        if m is None:
            continue
        it = int(m.group(1))
        if it > last_it:
            last_it = it

        # Train loss: SFT "Train loss X" or DPO ": loss X"
        tl = _num2(line, r"Train loss ([0-9.]+)", r": loss ([0-9.]+)")
        if tl >= 0.0:
            train.append(_pt(it, tl))

        # Val loss: SFT only
        vl = _num(line, r"Val loss ([0-9.]+)")
        if vl >= 0.0:
            val.append(_pt(it, vl))

        # Learning rate: SFT "Learning Rate X" or DPO " lr X"
        lv = _num2(line, r"Learning Rate ([0-9.eE+-]+)", r" lr ([0-9.eE+-]+)")
        if lv >= 0.0:
            lr.append(_pt(it, lv))

        # Tokens/sec: SFT "Tokens/sec X" or DPO "tok/s X"
        tv = _num2(line, r"Tokens/sec ([0-9.]+)", r"tok/s ([0-9.]+)")
        if tv >= 0.0:
            tps.append(_pt(it, tv))

    return {"train": train, "val": val, "lr": lr, "tps": tps, "last_iter": last_it}


def read_series(path: Path, ykey: str) -> list[dict]:
    """Read a JSONL file as [{x: step, y: <ykey>}] point series.

    Skips lines that are not JSON objects and rows missing either "step" or ykey
    (e.g. summary rows in idiom JSONL files that have no "step" key).
    """
    out: list = []
    if not path.exists():
        return out
    for line in path.read_text().split("\n"):
        stripped = line.strip()
        if not stripped.startswith("{"):
            continue
        try:
            r = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        if "step" not in r or ykey not in r:
            continue
        out.append(_pt(int(r["step"]), float(r[ykey])))
    return out


def last_row(path: Path) -> dict:
    """Return the last parseable JSON object in a JSONL file, or {} if none/missing."""
    last: dict = {}
    if not path.exists():
        return last
    for line in path.read_text().split("\n"):
        stripped = line.strip()
        if not stripped.startswith("{"):
            continue
        try:
            last = json.loads(stripped)
        except json.JSONDecodeError:
            continue
    return last


def tail(path: Path, n: int = 40) -> str:
    """Return the last *n* lines of *path* as a single string, or "" if missing."""
    if not path.exists():
        return ""
    lines = path.read_text().split("\n")
    start = max(0, len(lines) - n)
    return "\n".join(lines[start:])


def pick_idiom(run_dir: Path, mode: str) -> Path | None:
    """Return the best idiom-metrics file for *run_dir* / *mode*, or None.

    Prefers idiom-metrics.jsonl (function holdout) over graph-idiom.jsonl.
    DPO mode looks under <run_dir>/dpo/ instead of directly in <run_dir>.
    A file is only accepted if its last row contains an "avg_sim" key.
    """
    if mode == "dpo":
        candidates = [
            run_dir / "dpo" / "idiom-metrics.jsonl",
            run_dir / "dpo" / "graph-idiom.jsonl",
        ]
    else:
        candidates = [
            run_dir / "idiom-metrics.jsonl",
            run_dir / "graph-idiom.jsonl",
        ]
    for cand in candidates:
        row = last_row(cand)
        if row and "avg_sim" in row:
            return cand
    return None


def stages(run_dir: Path) -> list[str]:
    """Return the ordered list of completed stage names for *run_dir*.

    A stage is complete when its .<stage>.done marker file exists.
    Order: base, dry, train, curve, finetuned.  Missing dir → [].
    """
    found: list = []
    if not run_dir.exists():
        return found
    for s in ["base", "dry", "train", "curve", "finetuned"]:
        if (run_dir / f".{s}.done").exists():
            found.append(s)
    return found


def merge_by_x(by_run: dict[str, list[dict]]) -> list[dict]:
    """Merge per-run [{x, y}] series into overlay rows [{x, <name>: y, ...}].

    Rows are sorted by x.  Missing runs for a given x are simply absent from
    that row (not filled with None/0), matching the jac source _merge behaviour.
    """
    rows: dict = {}
    for name, series in by_run.items():
        for pt in series:
            xi = int(pt["x"])
            row = rows.get(xi, {"x": xi})
            row[name] = float(pt["y"])
            rows[xi] = row
    return [rows[k] for k in sorted(rows)]


def last_iter(log_path: Path) -> int:
    """Return the maximum Iter number found in *log_path*, or 0 if missing/empty."""
    if not log_path.exists():
        return 0
    last = 0
    for m in re.finditer(r"Iter (\d+)", log_path.read_text()):
        v = int(m.group(1))
        if v > last:
            last = v
    return last
