"""Read-only training-run metrics for the Monitor screen.

Parses the mlx_lm.lora train log + per-checkpoint metrics JSONL produced by
run_probe.sh / run_dpo.sh and serves them to the client as chart-ready point
series ({"x": iter, "y": value}). The parsing mirrors srccurrent/jacgen/
dashboard.jac so the UI agrees with the ASCII dashboard and the PNG plots.

Layout under <root>/results/<name>/:
  train.log, metrics.jsonl, idiom-metrics.jsonl     (SFT)
  dpo/train.log, dpo/idiom-metrics.jsonl            (DPO)
  .<stage>.done markers                              (base/dry/train/curve/finetuned)
"""

import json;
import re;
import os;
import from pathlib { Path }


obj RunSummary {
    has name: str,
        has_sft: bool,
        has_dpo: bool,
        stages: list[str],
        running: bool;
}


obj RunMetrics {
    has name: str,
        mode: str,
        found: bool,
        running: bool,
        last_iter: int,
        train: list[dict],
        val: list[dict],
        lr: list[dict],
        tps: list[dict],
        curve: list[dict],
        idiom_sim: list[dict],
        has_idiom: bool,
        idiom_label: str,
        idiom_avg_sim: float,
        idiom_idiomatic: int,
        idiom_python: int,
        idiom_runs: int,
        idiom_total: int,
        log_tail: str;
}


def _pick_idiom(rdir: str, mode: str) -> list {
    # First idiom summary that exists -> [path, label]. Function-holdout idiom is
    # preferred; gemma's SFT run only has the graph-holdout idiom, so fall back.
    if mode == "dpo" {
        cands: list = [
            [rdir + "/dpo/idiom-metrics.jsonl", "function holdout"],
            [rdir + "/dpo/graph-idiom.jsonl", "graph holdout"],
        ];
    } else {
        cands: list = [
            [rdir + "/idiom-metrics.jsonl", "function holdout"],
            [rdir + "/graph-idiom.jsonl", "graph holdout"],
        ];
    }
    for c in cands {
        if "avg_sim" in _last_row(str(c[0])) { return [str(c[0]), str(c[1])]; }
    }
    return ["", ""];
}


def _root() -> str {
    # Absolute repo root, whether the server runs from it or from dashboard_app/.
    if Path("results").exists() { return str(Path(".").resolve()); }
    if Path("../results").exists() { return str(Path("..").resolve()); }
    return str(Path(os.environ.get("DG_ROOT", "..")).resolve());
}


def _num(line: str, pattern: str) -> float {
    m = re.search(pattern, line);
    if m is None { return -1.0; }
    return float(str(m.group(1)));
}


def _num2(line: str, p1: str, p2: str) -> float {
    # Try the mlx_lm.lora (SFT) pattern, then the mlx-lm-lora (DPO) pattern.
    v: float = _num(line, p1);
    if v >= 0.0 { return v; }
    return _num(line, p2);
}


def _pt(it: int, v: float) -> dict {
    return {"x": it, "y": v};
}


def _parse_train(path: str) -> dict {
    train: list = []; val: list = []; lr: list = [];
    tps: list = []; last_it: int = 0;
    p = Path(path);
    if not p.exists() {
        return {"train": train, "val": val, "lr": lr, "tps": tps, "last": 0};
    }
    for line in p.read_text().split("\n") {
        m = re.search("Iter (\\d+)", line);
        if m is None { continue; }
        it: int = int(str(m.group(1)));
        if it > last_it { last_it = it; }
        tl: float = _num2(line, "Train loss ([0-9.]+)", ": loss ([0-9.]+)");
        if tl >= 0.0 { train.append(_pt(it, tl)); }
        vl: float = _num(line, "Val loss ([0-9.]+)");
        if vl >= 0.0 { val.append(_pt(it, vl)); }
        lv: float = _num2(line, "Learning Rate ([0-9.eE+-]+)", " lr ([0-9.eE+-]+)");
        if lv >= 0.0 { lr.append(_pt(it, lv)); }
        tv: float = _num2(line, "Tokens/sec ([0-9.]+)", "tok/s ([0-9.]+)");
        if tv >= 0.0 { tps.append(_pt(it, tv)); }
    }
    return {"train": train, "val": val, "lr": lr, "tps": tps, "last": last_it};
}


def _read_series(path: str, ykey: str) -> list[dict] {
    # Per-step JSONL -> [{x: step, y: <ykey>}]. Skips rows missing either key
    # (e.g. the single-row idiom SUMMARY files, which have no "step").
    out: list = [];
    p = Path(path);
    if not p.exists() { return out; }
    for line in p.read_text().split("\n") {
        if not line.strip().startswith("{") { continue; }
        r: dict = dict(json.loads(line));
        if "step" not in r or ykey not in r { continue; }
        out.append(_pt(int(str(r["step"])), float(str(r[ykey]))));
    }
    return out;
}


def _last_row(path: str) -> dict {
    # Last JSON object in a JSONL file (e.g. the idiom-eval summary), or {}.
    last: dict = {};
    p = Path(path);
    if not p.exists() { return last; }
    for line in p.read_text().split("\n") {
        if not line.strip().startswith("{") { continue; }
        last = dict(json.loads(line));
    }
    return last;
}


def _tail(path: str, n: int) -> str {
    p = Path(path);
    if not p.exists() { return ""; }
    lines: list = p.read_text().split("\n");
    start: int = 0;
    if len(lines) > n { start = len(lines) - n; }
    return "\n".join(lines[start:]);
}


def _stages(rdir: str) -> list[str] {
    found: list = [];
    for s in ["base", "dry", "train", "curve", "finetuned"] {
        if Path(rdir + "/." + s + ".done").exists() { found.append(s); }
    }
    return found;
}


def:pub list_runs() -> list[RunSummary] {
    # Every model dir under results/ with its SFT/DPO presence + finished stages.
    out: list[RunSummary] = [];
    base = Path(_root() + "/results");
    if not base.exists() { return out; }
    for child in sorted(base.iterdir()) {
        if not child.is_dir() { continue; }
        if child.name == "comparison" { continue; }
        rdir: str = str(child);
        has_sft: bool = Path(rdir + "/train.log").exists() or Path(rdir + "/.train.done").exists();
        has_dpo: bool = Path(rdir + "/dpo").exists();
        out.append(RunSummary(
            name=child.name,
            has_sft=has_sft,
            has_dpo=has_dpo,
            stages=_stages(rdir),
            running=False,
        ));
    }
    return out;
}


def:pub get_run_metrics(name: str, mode: str) -> RunMetrics {
    # Chart-ready series for one run. mode is "sft" or "dpo".
    rdir: str = _root() + "/results/" + name;
    if mode == "dpo" {
        log: str = rdir + "/dpo/train.log";
        curve_path: str = "";
    } else {
        log: str = rdir + "/train.log";
        curve_path: str = rdir + "/metrics.jsonl";
    }
    picked: list = _pick_idiom(rdir, mode);
    idiom: str = str(picked[0]);
    idiom_label: str = str(picked[1]);
    t: dict = _parse_train(log);
    curve: list = [];
    if curve_path != "" { curve = _read_series(curve_path, "test_pass_pct"); }
    isum: dict = {};
    if idiom != "" { isum = _last_row(idiom); }
    return RunMetrics(
        name=name,
        mode=mode,
        found=Path(log).exists(),
        running=False,
        last_iter=int(t["last"]),
        train=list(t["train"]),
        val=list(t["val"]),
        lr=list(t["lr"]),
        tps=list(t["tps"]),
        curve=curve,
        idiom_sim=_read_series(idiom, "avg_sim") if idiom != "" else [],
        has_idiom=("avg_sim" in isum),
        idiom_label=idiom_label,
        idiom_avg_sim=float(str(isum.get("avg_sim", 0.0))),
        idiom_idiomatic=int(str(isum.get("idiomatic", 0))),
        idiom_python=int(str(isum.get("python_shaped", 0))),
        idiom_runs=int(str(isum.get("runs", 0))),
        idiom_total=int(str(isum.get("total", 0))),
        log_tail=_tail(log, 25),
    );
}


obj CompareResult {
    has names: list[str],
        train: list[dict],
        val: list[dict],
        curve: list[dict],
        headline: list[dict];
}


def _last_y(series: list) -> float {
    if len(series) == 0 { return 0.0; }
    return float(str(series[len(series) - 1]["y"]));
}


def _merge(by_run: dict, names: list[str]) -> list[dict] {
    # Per-run [{x, y}] -> overlay rows [{x, <run>: y, ...}] merged on x.
    rows: dict = {};
    for nm in names {
        series: list = list(by_run[nm]);
        for pt in series {
            xi: int = int(str(pt["x"]));
            row: dict = dict(rows.get(xi, {"x": xi}));
            row[nm] = float(str(pt["y"]));
            rows[xi] = row;
        }
    }
    out: list[dict] = [];
    for k in sorted(rows.keys()) { out.append(dict(rows[k])); }
    return out;
}


def:pub compare_runs(mode: str) -> CompareResult {
    # Overlay every run's curves for the given mode + per-run headline numbers.
    base = Path(_root() + "/results");
    names: list[str] = [];
    trains: dict = {};
    vals: dict = {};
    curves: dict = {};
    headline: list[dict] = [];
    if base.exists() {
        for child in sorted(base.iterdir()) {
            if not child.is_dir() { continue; }
            if child.name == "comparison" or child.name == "_builder" { continue; }
            m: RunMetrics = get_run_metrics(child.name, mode);
            if not m.found { continue; }
            names.append(child.name);
            trains[child.name] = m.train;
            vals[child.name] = m.val;
            curves[child.name] = m.curve;
            headline.append({
                "name": child.name,
                "final_pass": _last_y(m.curve),
                "last_loss": _last_y(m.train),
                "idiom_sim": m.idiom_avg_sim,
                "idiomatic": m.idiom_idiomatic,
                "idiom_label": m.idiom_label,
                "has_idiom": m.has_idiom,
            });
        }
    }
    return CompareResult(
        names=names,
        train=_merge(trains, names),
        val=_merge(vals, names),
        curve=_merge(curves, names),
        headline=headline,
    );
}
