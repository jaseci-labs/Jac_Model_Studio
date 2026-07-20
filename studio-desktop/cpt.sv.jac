"""studio - CPT corpus browser + training control (03-new attempt).

Surfaces the continual-pretrain dataset built by 03-new/cpt_build/build_cpt.py:
manifest stats (pivoted server-side into chart-ready lists) + per-source raw/packed
row previews. Like rl.sv.jac, CPT data lives in THIS repo (jac_ml_studio), not the
studio's data_root (which can point at the DataGeneration checkout), so paths resolve
against the workspace root via paths.workspace_root() — NOT models.data_root().

Training control mirrors train.sv.jac/runs.sv.jac (jobs.sv.jac for detached-process
lifecycle, metrics.sv.jac for log parsing) but scoped to 03-new's own results/adapters
dirs instead of models.results_dir() -- CPT is LoRA continual pretrain on raw text via
mlx_lm.lora directly (no run_probe.sh wrapper: no quantize/base-eval/fuse stages, CPT
has no task-based holdout to eval against yet, see workflow.md's CF-guard open item).
"""

import os;
import json;
import time;
import shlex;
import auth;
import jobs;
import metrics;
import paths;
import backends;
import workspace;
import from pathlib { Path }
import from data { FileRefView, DataRowView }

# CPT layout (files, manifest, src order, kind map) lives in
# studio.workspace.toml (workspace.sv.jac); paths resolve via workspace_root().

def _abs(rel: str) -> Path {
    return paths.resolve(rel, "workspace");
}

def _allowed(rel: str) -> bool {
    for pair in workspace.cpt_files() {
        if pair[0] == rel { return True; }
    }
    return False;
}

def _read_lines(rel: str) -> list {
    p = _abs(rel);
    if not p.exists() { return []; }
    out: list = [];
    for line in p.read_text().split("\n") {
        if line.strip() { out.append(line); }
    }
    return out;
}

def _first_line(s: str) -> str {
    for ln in s.split("\n") {
        t = ln.strip();
        if t {
            return (t[:90] + "…") if len(t) > 90 else t;
        }
    }
    return "";
}

def _row_name(meta: dict, idx: int) -> str {
    f = str(meta.get("file", ""));
    if f { return f; }
    rp = str(meta.get("path", ""));
    if rp {
        repo = str(meta.get("repo", ""));
        base = repo.split("/")[-1] if repo else "";
        return (base + "/" + rp) if base else rp;
    }
    w = meta.get("window", None);
    if w is not None {
        return str(meta.get("source", "pack")) + " #" + str(w);
    }
    return "row " + str(idx);
}

def _build_row(idx: int, rec: any) -> DataRowView {
    meta = rec.get("meta", {});
    src = str(meta.get("source", "—"));
    typ = str(meta.get("type", ""));
    kind = str(workspace.cpt_kind_map().get(typ, src));
    text = str(rec.get("text", ""));
    diff = "";
    uw = meta.get("upsample_weight", None);
    if uw is not None { diff = str(uw) + "x"; }
    return DataRowView(
        idx=idx, name=_row_name(meta, idx), difficulty=diff or "—",
        source=src, kind=kind, preview=_first_line(text), raw=text
    );
}

"""Manifest pivoted into chart-ready lists so the client never parses JSON/regex.

Returns: sources (ordered [{name, rows, tokens, windows, pct}]), totals, gate
([{repo, files, passed, pct}] sorted by files desc), decontam ([{source, dropped}]),
packed {train, valid}, and passthrough scalars (seq_len, split, tokenizer, eos, fim)."""
def cpt_manifest() -> dict {
    p = _abs(workspace.cpt_manifest_rel());
    if not p.exists() {
        return {"ok": False};
    }
    m: dict = {};
    try { m = json.loads(p.read_text()); } except Exception { return {"ok": False}; }

    src_raw = m.get("sources", {});
    total_tokens = 0;
    for k in src_raw { total_tokens += int(src_raw[k].get("tokens", 0)); }
    sources: list = [];
    for name in workspace.cpt_src_order() {
        if name in src_raw {
            s = src_raw[name];
            tok = int(s.get("tokens", 0));
            pct = (tok * 1000) // total_tokens if total_tokens > 0 else 0;
            sources.append({
                "name": name, "rows": int(s.get("rows", 0)),
                "tokens": tok, "windows": int(s.get("windows", 0)),
                "pct": pct  # per-mille (0-1000) so the client avoids float math
            });
        }
    }

    gate_raw = m.get("code_gate", {});
    gate: list = [];
    for repo in gate_raw {
        g = gate_raw[repo];
        files = int(g.get("files", 0));
        passed = int(g.get("passed", 0));
        pctp = (passed * 100) // files if files > 0 else 0;
        gate.append({"repo": repo, "files": files, "passed": passed, "pct": pctp});
    }
    gate.sort(key=lambda d: dict -> int { return int(d["files"]); }, reverse=True);

    decon_raw = m.get("decontam", {});
    decontam: list = [];
    for s2 in decon_raw {
        decontam.append({"source": s2, "dropped": int(decon_raw[s2])});
    }

    packed = m.get("packed", {});
    return {
        "ok": True,
        "sources": sources,
        "total_tokens": total_tokens,
        "gate": gate,
        "decontam": decontam,
        "packed": {"train": int(packed.get("train", 0)), "valid": int(packed.get("val", 0))},
        "seq_len": int(m.get("seq_len", 0)),
        "split": str(m.get("split", "")),
        "tokenizer": str(m.get("tokenizer", "")),
        "eos_token": str(m.get("eos_token", "")),
        "n_repos": len(m.get("repos", {}))
    };
}

"""All preview-allowed CPT files with line counts."""
def cpt_files() -> list[FileRefView] {
    out: list[FileRefView] = [];
    for pair in workspace.cpt_files() {
        out.append(FileRefView(path=pair[0], label=pair[1], count=len(_read_lines(pair[0]))));
    }
    return out;
}

"""A page of parsed rows from a CPT jsonl (cap 40), gated by the allowlist."""
def cpt_rows(path: str, offset: int, limit: int) -> dict {
    if not _allowed(path) {
        return {"rows": [], "total": 0};
    }
    cap = max(1, min(limit, 40));
    lines = _read_lines(path);
    total = len(lines);
    result: list[DataRowView] = [];
    i = offset;
    while i < total and i < offset + cap {
        try {
            rec = json.loads(str(lines[i]));
            result.append(_build_row(i, rec));
        } except Exception {}
        i += 1;
    }
    return {"rows": result, "total": total};
}


# ---------------------------------------------------------- training control

glob CPT_CONFIGS: dict = {
    "cpt-v1": "03-new/cpt_train/config.yaml",
    "cpt-v2": "03-new/cpt_train/config_v2_6epoch.yaml",
    "cpt-v3": "03-new/cpt_train/config_v3_rank32.yaml"
};
glob CPT_TOTAL_ITERS: dict = {
    "cpt-v1": 2586,  # 3 epochs
    "cpt-v2": 5172,  # 6 epochs
    "cpt-v3": 2586   # 3 epochs, rank-32
};

# CPT training outputs (adapters + results) are namespaced per-user under the
# shared repo checkout, so each tenant trains/resumes independently on their own
# adapter tree. The CPT CORPUS (read by cpt_manifest/files/rows) stays shared.
def _cpt_results_dir(name: str) -> Path {
    return auth.user_workspace_dir("03-new", "results") / name;
}

def _cpt_adapter_dir(name: str) -> Path {
    return auth.user_workspace_dir("03-new", "adapters") / name;
}

def _cpt_job_file(name: str) -> Path {
    return _cpt_results_dir(name) / ".job-cpt.json";
}

def _cpt_run_log(name: str) -> Path {
    return _cpt_results_dir(name) / "run-cpt.log";
}

def _cpt_train_log(name: str) -> Path {
    return _cpt_results_dir(name) / "train.log";
}

"""Latest saved checkpoint (sorted by the zero-padded step prefix mlx_lm names
its files with, e.g. 0000100_adapters.safetensors) + the step it represents.
Same convention as 01-sft-dpo/sft_dpo/run_probe.sh's resume logic."""
def _cpt_resume_point(name: str) -> dict {
    adir = _cpt_adapter_dir(name);
    if not adir.exists() {
        return {"done_steps": 0, "ckpt": ""};
    }
    ckpts = sorted(adir.glob("*_adapters.safetensors"));
    if not ckpts {
        return {"done_steps": 0, "ckpt": ""};
    }
    latest = ckpts[-1];
    digits = "";
    for ch in latest.name {
        if ch.isdigit() { digits += ch; } else { break; }
    }
    steps = int(digits) if digits else 0;
    return {"done_steps": steps, "ckpt": str(latest)};
}

def _cpt_build_status(name: str, message: str = "") -> dict {
    jf = _cpt_job_file(name);
    rl = _cpt_run_log(name);
    tl = _cpt_train_log(name);
    job = jobs.live_status(jf, rl);
    parsed = metrics.parse_train_log_by(backends.log_parser_for("mlx_local", "cpt"), tl);
    total_iters = CPT_TOTAL_ITERS.get(name, 2586);

    if job is None {
        status = "finished" if tl.exists() else "idle";
        return {
            "name": name, "status": status, "pid": 0, "started": "",
            "last_iter": parsed["last_iter"], "total_iters": total_iters,
            "train": parsed["train"], "val": parsed["val"], "lr": parsed["lr"],
            "tps": parsed["tps"], "log_tail": metrics.tail(rl, 40), "message": message
        };
    }
    return {
        "name": name, "status": str(job.get("status", "idle")),
        "pid": int(str(job.get("pid") or 0)), "started": str(job.get("started", "")),
        "last_iter": parsed["last_iter"], "total_iters": total_iters,
        "train": parsed["train"], "val": parsed["val"], "lr": parsed["lr"],
        "tps": parsed["tps"], "log_tail": metrics.tail(rl, 40), "message": message
    };
}

"""Start (or resume) a CPT LoRA run via mlx_lm.lora, detached. Resume-aware: if
03-new/adapters/<name> already has checkpoints, only the REMAINING iters run,
picking up from the latest via --resume-adapter-file (same convention as
run_probe.sh). Returns the status dict."""
def start_cpt_training(name: str = "cpt-v1", config: str = "") -> dict {
    if not jobs.safe(name) {
        raise ValueError("invalid name");
    }

    config_file = str(CPT_CONFIGS.get(name, CPT_CONFIGS["cpt-v1"]));
    if config { config_file = str(config); }
    total_iters = CPT_TOTAL_ITERS.get(name, 2586);

    jf = _cpt_job_file(name);
    rl = _cpt_run_log(name);
    existing = jobs.live_status(jf, rl);
    if existing is not None and str(existing.get("status")) == "running" {
        return _cpt_build_status(name, "already running");
    }

    run_dir = _cpt_results_dir(name);
    run_dir.mkdir(parents=True, exist_ok=True);
    adapter_dir = _cpt_adapter_dir(name);
    adapter_dir.parent.mkdir(parents=True, exist_ok=True);

    resume = _cpt_resume_point(name);
    done_steps = int(str(resume["done_steps"]));
    remain = total_iters - done_steps;
    if remain <= 0 {
        return _cpt_build_status(name, f"already complete ({done_steps}/{total_iters})");
    }

    tl = _cpt_train_log(name);
    if done_steps == 0 {
        tl.write_text("");  # fresh start clears the learning curve
    }

    ckpt = str(resume["ckpt"]);
    resume_flag = f" --resume-adapter-file {shlex.quote(ckpt)}" if ckpt else "";
    rendered = backends.render({
        "method": "cpt",
        "vars": {
            "config_file": shlex.quote(config_file),
            "adapter_dir": shlex.quote(str(adapter_dir)),
            "iters": str(remain),
            "resume_flag": resume_flag,
            "train_log": shlex.quote(str(tl))
        }
    });
    inner = str(rendered["cmd"]);
    env_overrides = dict(rendered["env"]);
    launch_cwd = Path(str(rendered["cwd"]));

    cmd = jobs.with_exit_marker(inner, rl);
    rl.write_text("");  # erase a previous run's __EXIT__ marker

    pid = jobs.spawn_detached(cmd, runlog=rl, env=env_overrides, cwd=launch_cwd);

    now = time.strftime("%Y-%m-%d %H:%M:%S");
    jobs.write_job(jf, {
        "name": name, "mode": "cpt", "pid": pid, "status": "running",
        "started": now, "cmd": inner,
        "resumed_from": done_steps, "iters_this_run": remain
    });

    msg = "";
    if done_steps > 0 {
        msg = f"training {remain} iters (resuming from {done_steps}/{total_iters})";
    } else {
        msg = f"training {remain} iters from scratch";
    }
    return _cpt_build_status(name, msg);
}

"""Stop a running CPT job (SIGTERM the process group). Returns status."""
def stop_cpt_training(name: str = "cpt-v1") -> dict {
    if not jobs.safe(name) {
        raise ValueError("invalid name");
    }
    jobs.stop(_cpt_job_file(name), _cpt_run_log(name));
    return _cpt_build_status(name, "stop signal sent");
}

"""Poll live status + full loss/lr/tps curves for a CPT run."""
def get_cpt_status(name: str = "cpt-v1") -> dict {
    if not jobs.safe(name) {
        raise ValueError("invalid name");
    }
    return _cpt_build_status(name);
}

"""Get status of all CPT runs for comparison view."""
def get_all_cpt_status() -> dict {
    out: dict = {};
    for name in ["cpt-v1", "cpt-v2", "cpt-v3"] {
        out[name] = _cpt_build_status(name);
    }
    return out;
}
