"""studio - dataset stats / preview / ingest. Ports server/datasets.py.

Read-only browser (stats/files/rows) + append. Builder pipeline (subprocess)
lands with the jobs module. All code fields returned as raw strings.
"""

import os;
import json;
import re;
import models;
import from pathlib { Path }

# RL data lives in THIS repo (jac_ml_studio), not the studio's data_root (which points
# at the DataGeneration checkout). Resolve RL files against the repo root, like rl.sv.jac.
glob RL_ROOT: str = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))));

glob PREVIEW_FILES: list[list[str]] = [
    ["dataset/conversion/sft.jsonl", "SFT idiomatic core"],
    ["dataset/conversion/sft_auto.jsonl", "SFT transpile volume"],
    ["dataset/conversion/dpo.jsonl", "DPO pairs"],
    ["dataset/mlx/train.jsonl", "MLX SFT train"],
    ["dataset/mlx/valid.jsonl", "MLX SFT valid"],
    ["dataset/mlx_dpo/train.jsonl", "MLX DPO train"],
    ["dataset/mlx_dpo/valid.jsonl", "MLX DPO valid"],
    ["dataset/eval_holdout/conversion.jsonl", "Holdout (function)"],
    ["dataset/eval_holdout/graph_conversion.jsonl", "Holdout (graph)"]
];
glob APPEND_TARGETS: dict = {
    "sft": "dataset/conversion/sft.jsonl", "dpo": "dataset/conversion/dpo.jsonl"
};

# RL data pipeline — grouped by training use. SFT=gold {messages}; the rest are the
# {prompt, answer} task pool (GRPO reward / eval). See RL_FINDINGS.md.
glob RL_SOURCES: list[str] = ["SFT", "GRPO", "conversion", "synthetic", "splits"];
glob RL_PREVIEW_FILES: dict = {
    "SFT": [["dataset/rl/rft/train.jsonl", "RFT gold · train"], ["dataset/rl/rft/valid.jsonl", "RFT gold · valid"]],
    "GRPO": [["dataset/rl/tasks.jsonl", "reward tasks · all"], ["dataset/rl/train.jsonl", "GRPO train pool"], ["dataset/rl/valid.jsonl", "GRPO valid"]],
    "conversion": [["dataset/rl_conv/tasks.jsonl", "python→jac · all"], ["dataset/rl_conv/train.jsonl", "conv train"], ["dataset/rl_conv/holdout.jsonl", "conv holdout"]],
    "synthetic": [["dataset/rl/synthetic.jsonl", "synthetic · fresh (32)"]],
    "splits": [["dataset/rl/holdout.jsonl", "holdout n=18"], ["dataset/rl/holdout_big.jsonl", "holdout n=32 (+syn)"], ["dataset/rl/train_big.jsonl", "train pool (+syn)"]]
};

obj FileRefView {
    has path: str = "", label: str = "", count: int = 0;
}

obj DataRowView {
    has idx: int = 0, name: str = "", difficulty: str = "", source: str = "",
        kind: str = "", preview: str = "", prompt: str = "", python: str = "",
        jac: str = "", chosen: str = "", rejected: str = "", raw: str = "";
}

def _abs(rel: str) -> Path {
    return models.data_root() / rel;
}

def _allowed(rel: str) -> bool {
    for pair in PREVIEW_FILES {
        if pair[0] == rel {
            return True;
        }
    }
    return False;
}

def _read_lines(rel: str) -> list {
    p = _abs(rel);
    if not p.exists() {
        return [];
    }
    nl = "\n";
    out: list = [];
    for line in p.read_text().split(nl) {
        if line.strip() {
            out.append(line);
        }
    }
    return out;
}

def _line_count(rel: str) -> int {
    return len(_read_lines(rel));
}

def _fence(text: str, lang: str) -> str {
    m = re.search("(?s)```" + lang + "[^\n]*\n(.*?)```", text);
    if m {
        return m.group(1).strip();
    }
    m2 = re.search("(?s)```[A-Za-z0-9]*\\s*\n(.*?)```", text);
    if m2 {
        return m2.group(1).strip();
    }
    return "";
}

def _funcname(code: str) -> str {
    for pat in ["def\\s+(\\w+)", "walker\\s+(\\w+)", "node\\s+(\\w+)", "obj\\s+(\\w+)", "class\\s+(\\w+)"] {
        m = re.search(pat, code);
        if m {
            return m.group(1);
        }
    }
    return "";
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

def _strip_fences(s: str) -> str {
    return re.sub("(?s)```.*?```", "", s).strip();
}

def _build_row(idx: int, rec: any) -> DataRowView {
    meta = rec.get("meta", {});
    diff = str(meta.get("difficulty", "—"));
    src = str(meta.get("source", rec.get("source", "—")));
    py = ""; jc = ""; chosen = ""; rejected = ""; prompt = ""; raw = "";
    kind = "raw"; nm = "";
    if "messages" in rec {
        kind = "sft";
        msgs = rec["messages"];
        mcount = len(list(msgs));
        usr = str(msgs[0].get("content", "")) if mcount > 0 else "";
        ast = str(msgs[1].get("content", "")) if mcount > 1 else "";
        py = _fence(usr, "python");
        jc = _fence(ast, "jac");
        if not jc { jc = ast.strip(); }
        prompt = _strip_fences(usr);
        nm = _funcname(py) or _funcname(jc);
    } elif "chosen" in rec {
        kind = "dpo";
        prompt = _strip_fences(str(rec.get("prompt", "")));
        chosen = _fence(str(rec["chosen"]), "jac") or str(rec["chosen"]).strip();
        rejected = _fence(str(rec["rejected"]), "jac") or str(rec["rejected"]).strip();
        py = _fence(str(rec.get("prompt", "")), "python");
        nm = _funcname(chosen) or _funcname(py);
    } elif "python" in rec {
        kind = "holdout";
        py = str(rec["python"]);
        prompt = str(rec.get("prompt", ""));
        nm = str(rec.get("func_name", "")) or _funcname(py);
    } elif "answer" in rec {
        # RL task: {prompt, answer=json-string {id, source, expected_output, timeout}}
        kind = "rltask";
        prompt = str(rec.get("prompt", ""));
        ad: dict = {};
        try { ad = json.loads(str(rec["answer"])); } except Exception {}
        nm = str(ad.get("id", ""));
        src = str(ad.get("source", src));
        jc = str(ad.get("expected_output", "")).strip();
        raw = json.dumps(ad, indent=2);
    } else {
        raw = json.dumps(rec, indent=2);
    }
    preview = _first_line(py) or _first_line(prompt) or _first_line(jc) or _first_line(chosen) or _first_line(raw);
    return DataRowView(
        idx=idx, name=nm or "—", difficulty=diff, source=src, kind=kind,
        preview=preview, prompt=prompt, python=py, jac=jc,
        chosen=chosen, rejected=rejected, raw=raw
    );
}

"""Dataset statistics: counts per SFT file, DPO pairs, split sizes."""
def:pub dataset_stats() -> dict {
    sft_rels = ["dataset/conversion/sft.jsonl", "dataset/conversion/sft_auto.jsonl"];
    sft_files: list = [];
    grand = 0;
    for rel in sft_rels {
        n = _line_count(rel);
        sft_files.append({"path": rel, "total": n});
        grand += n;
    }
    splits = {
        "mlx_train": _line_count("dataset/mlx/train.jsonl"),
        "mlx_valid": _line_count("dataset/mlx/valid.jsonl"),
        "dpo_train": _line_count("dataset/mlx_dpo/train.jsonl"),
        "dpo_valid": _line_count("dataset/mlx_dpo/valid.jsonl"),
        "holdout": _line_count("dataset/eval_holdout/conversion.jsonl"),
        "graph_holdout": _line_count("dataset/eval_holdout/graph_conversion.jsonl")
    };
    return {
        "sft_files": sft_files, "sft_total": grand,
        "dpo_pairs": _line_count("dataset/conversion/dpo.jsonl"), "splits": splits
    };
}

"""All preview-allowed files with line counts."""
def:pub dataset_files() -> list[FileRefView] {
    out: list[FileRefView] = [];
    for pair in PREVIEW_FILES {
        out.append(FileRefView(path=pair[0], label=pair[1], count=_line_count(pair[0])));
    }
    return out;
}

"""A page of parsed rows from the JSONL at `path` (cap 40)."""
def:pub dataset_rows(path: str, offset: int, limit: int) -> dict {
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

def _rl_allowed(source: str, rel: str) -> bool {
    for pair in RL_PREVIEW_FILES.get(source, []) {
        if pair[0] == rel { return True; }
    }
    return False;
}

def _rl_read_lines(rel: str) -> list {
    p = Path(RL_ROOT) / rel;
    if not p.exists() { return []; }
    out: list = [];
    for line in p.read_text().split("\n") {
        if line.strip() { out.append(line); }
    }
    return out;
}

"""RL dataset sources (SFT/GRPO/conversion/synthetic/splits) with their files + counts."""
def:pub rl_dataset_files(source: str) -> list[FileRefView] {
    out: list[FileRefView] = [];
    for pair in RL_PREVIEW_FILES.get(source, []) {
        out.append(FileRefView(path=pair[0], label=pair[1], count=len(_rl_read_lines(pair[0]))));
    }
    return out;
}

"""A page of parsed rows from an RL dataset file (cap 40), gated by source."""
def:pub rl_dataset_rows(source: str, path: str, offset: int, limit: int) -> dict {
    if not _rl_allowed(source, path) {
        return {"rows": [], "total": 0};
    }
    cap = max(1, min(limit, 40));
    lines = _rl_read_lines(path);
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

"""Append valid JSONL rows to *target* (key in APPEND_TARGETS — sft/dpo). Each
non-empty line is validated as JSON with the required schema (DPO needs
prompt/chosen/rejected; SFT needs a messages list). Returns {added, errors, total}.

# studio: the original used a binary seek(-1, 2) to test for a trailing newline;
# here read_text().endswith is simpler and the file is small (also re-read by
# _line_count). Unknown targets return an error dict instead of raising."""
def:pub add_examples(target: str, jsonl: str) -> dict {
    if target not in APPEND_TARGETS {
        return {"added": 0, "errors": [f"unknown target: {target}"], "total": 0};
    }
    rel = str(APPEND_TARGETS[target]);
    is_dpo = target == "dpo";
    valid: list[str] = [];
    errors: list[str] = [];
    n = 0;
    for raw in jsonl.split("\n") {
        if not raw.strip() {
            continue;
        }
        n += 1;
        rec: any = None;
        try {
            rec = json.loads(raw);
        } except Exception {
            errors.append(f"line {n}: not valid JSON");
            continue;
        }
        if is_dpo {
            if not ("prompt" in rec and "chosen" in rec and "rejected" in rec) {
                errors.append(f"line {n}: DPO row needs prompt/chosen/rejected");
                continue;
            }
        } elif "messages" not in rec {
            errors.append(f"line {n}: SFT row needs a messages list");
            continue;
        }
        valid.append(json.dumps(rec));
    }
    if valid {
        p = _abs(rel);
        p.parent.mkdir(parents=True, exist_ok=True);
        if p.exists() and p.stat().st_size > 0 {
            if not p.read_text().endswith("\n") {
                with open(p, "a") as fa {
                    fa.write("\n");
                }
            }
        }
        with open(p, "a") as fb {
            fb.write("\n".join(valid) + "\n");
        }
    }
    return {"added": len(valid), "errors": errors, "total": _line_count(rel)};
}
