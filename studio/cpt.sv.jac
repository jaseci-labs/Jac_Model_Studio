"""studio - CPT corpus browser (03-new attempt). Read-only.

Surfaces the continual-pretrain dataset built by 03-new/cpt_build/build_cpt.py:
manifest stats (pivoted server-side into chart-ready lists) + per-source raw/packed
row previews. Like rl.sv.jac, CPT data lives in THIS repo (jac_ml_studio), not the
studio's data_root (which can point at the DataGeneration checkout), so paths resolve
against the repo root from __file__ — NOT models.data_root().
"""

import os;
import json;
import from pathlib { Path }
import from data { FileRefView, DataRowView }

# studio/ sits directly at repo root (post Jul-10 flatten), so the repo root is
# two dirnames up from studio/cpt.sv.jac.
glob CPT_ROOT: str = os.path.dirname(os.path.dirname(os.path.abspath(__file__)));

# Preview-allowed CPT files: 5 raw per-source + 2 packed splits.
glob CPT_FILES: list[list[str]] = [
    ["03-new/dataset/cpt/docs/raw.jsonl", "docs · raw"],
    ["03-new/dataset/cpt/code/raw.jsonl", "code · raw"],
    ["03-new/dataset/cpt/blogs/raw.jsonl", "blogs · raw"],
    ["03-new/dataset/cpt/osp_paper/raw.jsonl", "osp_paper · raw"],
    ["03-new/dataset/cpt/rehearsal/raw.jsonl", "rehearsal · raw"],
    ["03-new/dataset/cpt/packed/train.jsonl", "packed · train"],
    ["03-new/dataset/cpt/packed/valid.jsonl", "packed · valid"]
];
glob MANIFEST_REL: str = "03-new/dataset/cpt/manifest.json";
# Source order for the composition bar + stat tiles (largest first).
glob SRC_ORDER: list[str] = ["docs", "code", "rehearsal", "blogs", "osp_paper"];
# meta.type -> short kind label for the row browser.
glob KIND_MAP: dict = {
    "official_doc": "doc", "llm_doc": "doc",
    "paper_section": "paper", "paper_listing": "paper",
    "blog_post": "blog", "repo_file": "code", "repo_pack": "code",
    "general_code": "rehearsal"
};

def _abs(rel: str) -> Path {
    return Path(CPT_ROOT) / rel;
}

def _allowed(rel: str) -> bool {
    for pair in CPT_FILES {
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
    kind = str(KIND_MAP.get(typ, src));
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
def:pub cpt_manifest() -> dict {
    p = _abs(MANIFEST_REL);
    if not p.exists() {
        return {"ok": False};
    }
    m: dict = {};
    try { m = json.loads(p.read_text()); } except Exception { return {"ok": False}; }

    src_raw = m.get("sources", {});
    total_tokens = 0;
    for k in src_raw { total_tokens += int(src_raw[k].get("tokens", 0)); }
    sources: list = [];
    for name in SRC_ORDER {
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
def:pub cpt_files() -> list[FileRefView] {
    out: list[FileRefView] = [];
    for pair in CPT_FILES {
        out.append(FileRefView(path=pair[0], label=pair[1], count=len(_read_lines(pair[0]))));
    }
    return out;
}

"""A page of parsed rows from a CPT jsonl (cap 40), gated by the allowlist."""
def:pub cpt_rows(path: str, offset: int, limit: int) -> dict {
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
