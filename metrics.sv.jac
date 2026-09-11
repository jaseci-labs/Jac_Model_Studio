"""studio - pure parsers for training/eval artifacts. Ports server/runlogs.py.

Log/metric parsers for the Train/Evals sections: mlx trainer log → chart series,
JSONL point/last-row readers, idiom-summary pickers, stage done-marker scan, and
per-run series merge. Internal helpers consumed by other .sv.jac modules, NOT HTTP
endpoints — plain `def`, no `:pub`.

Checker notes (jaclang 0.16.1): re.Match / json.loads results stay in `any` locals;
`int()/float()` reject `any`, so captured groups and dict values go through
`int(str(...))` / `float(str(...))`; json.loads landing in a typed dict is `dict(...)`.
"""

import json;
import re;
import from io { BytesIO, TextIOWrapper }
import from pathlib { Path }

# Backwards read granularity for tail(). One block covers ~40 lines of any real
# training log, so the common case is a single 64 KB read regardless of whether
# the log is 4 KB or 400 MB.
glob _TAIL_BLOCK: int = 65536;

# _STREAM_TRADEOFF — parse_train_log / read_series / last_row iterate the open file
# instead of read_text().split("\n"). Byte-identical results (text mode gives the
# same universal-newline splitting; the only differences are a per-line trailing
# "\n" that every branch strips or regex-ignores, and the absence of the empty
# final element a trailing newline produced, which every branch already skipped).
# Measured on an 89 MB JSONL: peak RSS 571 MB -> 92 MB, wall clock 2.2s -> 2.9s.
# ponytail: ceiling — deliberately paying ~30% CPU on these O(file) parsers to make
# their memory O(line). They are chart/summary calls, not the status poll (that is
# tail/last_iter, now bounded); a 1 GB transient on a box whose GPU job wants 48 GB
# is the failure that actually hurts. If the CPU ever matters, the fix is chunked
# reads, not going back to whole-file.

def _num(line: str, pattern: str) -> float {
    m: any = re.search(pattern, line);
    if m is None { return -1.0; }
    return float(str(m.group(1)));
}

def _num2(line: str, p1: str, p2: str) -> float {
    v = _num(line, p1);
    if v >= 0.0 { return v; }
    return _num(line, p2);
}

def _pt(it: int, v: float) -> dict {
    return {"x": it, "y": v};
}

"""Parse an mlx trainer log (SFT mlx_lm.lora + DPO formats) into chart series.
Returns {train, val, lr, tps: list[{x,y}], last_iter: int}."""
def parse_train_log(path: Path) -> dict {
    empty = {"train": [], "val": [], "lr": [], "tps": [], "last_iter": 0};
    if not path.exists() { return empty; }
    train: list[dict] = [];
    val: list[dict] = [];
    lr: list[dict] = [];
    tps: list[dict] = [];
    last_it: int = 0;
    # Streamed line-by-line (same strings the old read_text().split("\n") produced,
    # since every branch below is anchored on a regex that cannot span a newline)
    # so a multi-hundred-MB log never lands in memory whole. See _STREAM_TRADEOFF.
    fh: any = open(path);
    try {
        for line in fh {
            ln: str = str(line);
            m: any = re.search(r"Iter (\d+)", ln);
            if m is None { continue; }
            it = int(str(m.group(1)));
            if it > last_it { last_it = it; }
            tl = _num2(ln, r"Train loss ([0-9.]+)", r": loss ([0-9.]+)");
            if tl >= 0.0 { train.append(_pt(it, tl)); }
            vl = _num(ln, r"Val loss ([0-9.]+)");
            if vl >= 0.0 { val.append(_pt(it, vl)); }
            lv = _num2(ln, r"Learning Rate ([0-9.eE+-]+)", r" lr ([0-9.eE+-]+)");
            if lv >= 0.0 { lr.append(_pt(it, lv)); }
            tv = _num2(ln, r"Tokens/sec ([0-9.]+)", r"tok/s ([0-9.]+)");
            if tv >= 0.0 { tps.append(_pt(it, tv)); }
        }
    } finally {
        fh.close();
    }
    return {"train": train, "val": val, "lr": lr, "tps": tps, "last_iter": last_it};
}

"""Dispatch to a named train-log parser (mlx is the only wired parser today)."""
def parse_train_log_by(parser: str, path: Path) -> dict {
    if parser == "mlx" { return parse_train_log(path); }
    return parse_train_log(path);
}

"""Read a JSONL file as [{x: step, y: <ykey>}]. Skips non-object / incomplete rows."""
def read_series(path: Path, ykey: str) -> list[dict] {
    out: list[dict] = [];
    if not path.exists() { return out; }
    fh: any = open(path);
    try {
        for line in fh {
            stripped = str(line).strip();
            if not stripped.startswith("{") { continue; }
            try {
                r = json.loads(stripped);
            } except Exception { continue; }
            if "step" not in r or ykey not in r { continue; }
            out.append(_pt(int(str(r["step"])), float(str(r[ykey]))));
        }
    } finally {
        fh.close();
    }
    return out;
}

"""Last parseable JSON object in a JSONL file, or {} if none/missing."""
def last_row(path: Path) -> dict {
    last: dict = {};
    if not path.exists() { return last; }
    fh: any = open(path);
    try {
        for line in fh {
            stripped = str(line).strip();
            if not stripped.startswith("{") { continue; }
            try {
                last = dict(json.loads(stripped));
            } except Exception { continue; }
        }
    } finally {
        fh.close();
    }
    return last;
}

"""Byte offset in *buf* just after the *n*-th line separator counted from the END,
or -1 when *buf* holds fewer than *n* separators. A separator is CRLF, lone CR or
lone LF — the same three forms text mode collapses to "\n", so the offset always
lands on a "\n"-split boundary (and, since CR/LF never occur inside a multi-byte
UTF-8 sequence, on a safe decode boundary too)."""
def _tail_cut(buf: bytes, n: int) -> int {
    count = 0;
    i = len(buf) - 1;
    while i >= 0 {
        b = buf[i];
        if b == 10 {
            count = count + 1;
            if count >= n { return i + 1; }
            if i > 0 and buf[i - 1] == 13 { i = i - 1; }
        } elif b == 13 {
            count = count + 1;
            if count >= n { return i + 1; }
        }
        i = i - 1;
    }
    return -1;
}

"""Last *n* lines of *path* joined, or "" if missing.

Identical to the old `read_text().split("\n")[-n:]` join for every input, but seeks
backwards from EOF in 64 KB blocks so a 400 MB training log costs one read instead
of one full decode + a multi-million-element list. The tail bytes are decoded
through a TextIOWrapper so the locale encoding default and universal-newline
translation match Path.read_text() byte for byte."""
def tail(path: Path, n: int = 40) -> str {
    if not path.exists() { return ""; }
    if n <= 0 { return ""; }
    buf: bytes = bytes();
    cut = -1;
    fh: any = open(path, "rb");
    try {
        fh.seek(0, 2);
        pos = int(str(fh.tell()));
        while pos > 0 {
            step = min(_TAIL_BLOCK, pos);
            pos = pos - step;
            fh.seek(pos);
            buf = bytes(fh.read(step)) + buf;
            cut = _tail_cut(buf, n);
            if cut >= 0 { break; }
        }
    } finally {
        fh.close();
    }
    if cut < 0 { cut = 0; }
    return str(TextIOWrapper(BytesIO(buf[cut:])).read());
}

"""Maximum Iter number in *log_path*, or 0 if missing/empty.

Scans the bounded tail first (an mlx log only ever counts UP, so the largest Iter
lives in the last few lines) and falls back to a streaming full scan when the tail
carries no Iter at all.
# ponytail: ceiling — a log whose Iter numbers go BACKWARDS mid-file (a resume
# that restarts the counter in the same file) now reports the tail's maximum
# rather than the historical maximum. No writer in this repo does that; a run
# that resumes gets a fresh log file."""
def last_iter(log_path: Path) -> int {
    if not log_path.exists() { return 0; }
    last = 0;
    for m in re.finditer(r"Iter (\d+)", tail(log_path, 200)) {
        v = int(str(m.group(1)));
        if v > last { last = v; }
    }
    if last > 0 { return last; }
    fh: any = open(log_path);
    try {
        for line in fh {
            for m2 in re.finditer(r"Iter (\d+)", str(line)) {
                v2 = int(str(m2.group(1)));
                if v2 > last { last = v2; }
            }
        }
    } finally {
        fh.close();
    }
    return last;
}

"""Merge per-run [{x,y}] series into overlay rows [{x, <name>: y, ...}], sorted by x."""
def merge_by_x(by_run: dict) -> list {
    rows: dict = {};
    for (name, series) in by_run.items() {
        for pt in list(series) {
            xi = int(str(pt["x"]));
            row = rows.get(xi, {"x": xi});
            row[name] = float(str(pt["y"]));
            rows[xi] = row;
        }
    }
    return [rows[k] for k in sorted(rows)];
}

"""Ordered list of completed stage names (each has a .<stage>.done marker)."""
def stages(run_dir: Path) -> list[str] {
    found: list[str] = [];
    if not run_dir.exists() { return found; }
    for s in ["base", "dry", "train", "curve", "finetuned"] {
        if (run_dir / f".{s}.done").exists() { found.append(s); }
    }
    return found;
}

"""Last-row idiom summary for a holdout kind ("function" | "graph"), or {}."""
def idiom_summary(run_dir: Path, mode: str, kind: str) -> dict {
    base: Path = run_dir;
    if mode == "dpo" { base = run_dir / "dpo"; }
    candidates: list[Path] = [];
    if kind == "function" {
        candidates = [base / "idiom-metrics.jsonl"];
    } else {
        candidates = [base / "graph-idiom-metrics.jsonl", base / "graph-idiom.jsonl"];
    }
    for cand in candidates {
        row = last_row(cand);
        if row and "avg_sim" in row { return row; }
    }
    return {};
}
