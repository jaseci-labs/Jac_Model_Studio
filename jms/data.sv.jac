"""studio - dataset stats / preview / ingest. Ports server/datasets.py.

Read-only browser (stats/files/rows) + append. Builder pipeline (subprocess)
lands with the jobs module. All code fields returned as raw strings.
"""

import os;
import json;
import re;
import models;
import paths;
import workspace;
import from pathlib { Path }

# Dataset + RL file maps now live in studio.workspace.toml (workspace.sv.jac):
# preview_files / append_targets / split_files / sft_stat_files / rl_preview_files.
# RL data still resolves against the workspace checkout (paths.workspace_root),
# not the studio data_root when JAC_STUDIO_DATA_ROOT points elsewhere.

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
    for pair in workspace.preview_files() {
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

# Memoized non-blank line counts. Key = "<absolute path>|<st_mtime_ns>|<st_size>",
# so any write to the file (which necessarily bumps mtime_ns and/or size) misses
# the cache — a stale count is impossible short of a same-nanosecond same-size
# rewrite. The absolute path carries the per-user/data-root prefix, so two tenants
# pointed at different roots can never collide on a bare filename.
glob _LINE_COUNT_CACHE: dict[str, int] = {};
glob _LINE_COUNT_CAP: int = 512;

"""Non-blank line count of *p*, streamed in 1 MiB binary chunks (the file is never
loaded whole) and memoized on (path, mtime_ns, size). Missing file -> 0.

# ponytail: byte-level `.strip()` (ASCII whitespace) instead of the text-mode
# `str.strip()` the old full-read path used, and no lone-CR ("\r"-only) line-ending
# translation. Both only differ for a line whose sole content is a lone CR or a
# non-ASCII space — impossible in the JSONL these paths count."""
def _count_lines_cached(p: Path) -> int {
    try {
        st = p.stat();
    } except Exception {
        return 0;
    }
    key = str(p) + "|" + str(st.st_mtime_ns) + "|" + str(st.st_size);
    hit = _LINE_COUNT_CACHE.get(key);
    if hit is not None { return int(hit); }
    nl = "\n".encode();
    n = 0;
    rem = "".encode();
    try {
        with open(p, "rb") as fc {
            while True {
                chunk = fc.read(1048576);
                if not chunk { break; }
                parts = (rem + chunk).split(nl);
                rem = parts[len(parts) - 1];
                i = 0;
                while i < len(parts) - 1 {
                    if parts[i].strip() { n += 1; }
                    i += 1;
                }
            }
        }
    } except Exception {
        return 0;
    }
    if rem.strip() { n += 1; }
    if len(_LINE_COUNT_CACHE) > _LINE_COUNT_CAP { _LINE_COUNT_CACHE.clear(); }
    _LINE_COUNT_CACHE[key] = n;
    return n;
}

def _line_count(rel: str) -> int {
    return _count_lines_cached(_abs(rel));
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
def dataset_stats() -> dict {
    sft_rels = workspace.data_sft_stat_files();
    sft_files: list = [];
    grand = 0;
    for rel in sft_rels {
        n = _line_count(rel);
        sft_files.append({"path": rel, "total": n});
        grand += n;
    }
    split_rels = workspace.data_split_files();
    splits: dict = {};
    for k in split_rels {
        splits[k] = _line_count(str(split_rels[k]));
    }
    return {
        "sft_files": sft_files, "sft_total": grand,
        "dpo_pairs": _line_count("model-experiments/01-sft-dpo/dataset/conversion/dpo.jsonl"), "splits": splits
    };
}

"""All preview-allowed files with line counts."""
def dataset_files() -> list[FileRefView] {
    out: list[FileRefView] = [];
    for pair in workspace.preview_files() {
        out.append(FileRefView(path=pair[0], label=pair[1], count=_line_count(pair[0])));
    }
    return out;
}

"""A page of parsed rows from the JSONL at `path` (cap 40)."""
def dataset_rows(path: str, offset: int, limit: int) -> dict {
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
    pairs = (workspace.rl_preview_files().get(source, []) as list[list[str]]);
    for pair in pairs {
        if pair[0] == rel { return True; }
    }
    return False;
}

def _rl_read_lines(rel: str) -> list {
    p = paths.resolve(rel, "workspace");
    if not p.exists() { return []; }
    out: list = [];
    for line in p.read_text().split("\n") {
        if line.strip() { out.append(line); }
    }
    return out;
}

"""The RL source axis (SFT/GRPO/conversion/synthetic/splits) from
studio.workspace.toml — drives the RlData section's source picker so it stays in
sync with the server (no client-side duplicate of the source list)."""
def rl_sources() -> list[str] {
    return workspace.rl_sources();
}

"""RL dataset sources (SFT/GRPO/conversion/synthetic/splits) with their files + counts."""
def rl_dataset_files(source: str) -> list[FileRefView] {
    out: list[FileRefView] = [];
    pairs = (workspace.rl_preview_files().get(source, []) as list[list[str]]);
    for pair in pairs {
        out.append(FileRefView(path=pair[0], label=pair[1], count=_count_lines_cached(paths.resolve(pair[0], "workspace"))));
    }
    return out;
}

"""A page of parsed rows from an RL dataset file (cap 40), gated by source."""
def rl_dataset_rows(source: str, path: str, offset: int, limit: int) -> dict {
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

"""Append valid JSONL rows to *target* (key in workspace.append_targets() — sft/dpo). Each
non-empty line is validated as JSON with the required schema (DPO needs
prompt/chosen/rejected; SFT needs a messages list). Returns {added, errors, total}.

# studio: like the original, a binary seek(-1, 2) tests for the trailing newline —
# no whole-file read to inspect one byte. The closing _line_count streams the file
# once (memoized). Unknown targets return an error dict instead of raising."""
def add_examples(target: str, jsonl: str) -> dict {
    if target not in workspace.append_targets() {
        return {"added": 0, "errors": [f"unknown target: {target}"], "total": 0};
    }
    rel = str(workspace.append_targets()[target]);
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
            # One-byte seek instead of reading the whole file to inspect its last
            # byte (the original studio code did exactly this seek(-1, 2)).
            ends_nl = True;
            try {
                with open(p, "rb") as fs {
                    fs.seek(-1, 2);
                    ends_nl = fs.read(1) == "\n".encode();
                }
            } except Exception { ends_nl = True; }
            if not ends_nl {
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
