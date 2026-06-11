"""Dataset stats / preview / ingest.

Ported from dashboard_app/services/dataset.sv.jac.
HTML highlighting (_hl/_tok_repl/HL_*) is intentionally NOT ported — all code
fields are returned as raw strings.
"""

import json
import re
from pathlib import Path

import config


# ---------------------------------------------------------------------------
# Allow-lists
# ---------------------------------------------------------------------------

PREVIEW_FILES: list[list[str]] = [
    ["dataset/conversion/sft.jsonl", "SFT idiomatic core"],
    ["dataset/conversion/sft_auto.jsonl", "SFT transpile volume"],
    ["dataset/conversion/dpo.jsonl", "DPO pairs"],
    ["dataset/mlx/train.jsonl", "MLX SFT train"],
    ["dataset/mlx/valid.jsonl", "MLX SFT valid"],
    ["dataset/mlx_dpo/train.jsonl", "MLX DPO train"],
    ["dataset/mlx_dpo/valid.jsonl", "MLX DPO valid"],
    ["dataset/eval_holdout/conversion.jsonl", "Holdout (function)"],
    ["dataset/eval_holdout/graph_conversion.jsonl", "Holdout (graph)"],
]

APPEND_TARGETS: dict[str, str] = {
    "sft": "dataset/conversion/sft.jsonl",
    "dpo": "dataset/conversion/dpo.jsonl",
}


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _abs(rel: str) -> Path:
    return config.data_root() / rel


def _allowed_preview(rel: str) -> bool:
    return any(pair[0] == rel for pair in PREVIEW_FILES)


def _line_count(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(1 for line in path.read_text().split("\n") if line.strip())


def _count_file(rel: str) -> dict:
    by_diff: dict = {}
    by_gen: dict = {}
    by_src: dict = {}
    total: int = 0
    p = _abs(rel)
    if p.exists():
        for line in p.read_text().split("\n"):
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            meta = rec.get("meta", {})
            diff = str(meta.get("difficulty", "?"))
            gen = str(meta.get("generator", "?"))
            src = str(meta.get("source", "?"))
            by_diff[diff] = by_diff.get(diff, 0) + 1
            by_gen[gen] = by_gen.get(gen, 0) + 1
            by_src[src] = by_src.get(src, 0) + 1
            total += 1
    return {
        "path": rel,
        "total": total,
        "by_difficulty": by_diff,
        "by_generator": by_gen,
        "by_source": by_src,
    }


def _fence(text: str, lang: str) -> str:
    """Extract the first fenced code block for *lang* from *text*.

    Falls back to the first fenced block of any language if the specific lang
    is not found.  Returns "" if no fence is found.
    """
    m = re.search(r"(?s)```" + lang + r"[^\n]*\n(.*?)```", text)
    if m:
        return m.group(1).strip()
    m2 = re.search(r"(?s)```[A-Za-z0-9]*\s*\n(.*?)```", text)
    if m2:
        return m2.group(1).strip()
    return ""


def _funcname(code: str) -> str:
    for pat in [r"def\s+(\w+)", r"walker\s+(\w+)", r"node\s+(\w+)", r"obj\s+(\w+)", r"class\s+(\w+)"]:
        m = re.search(pat, code)
        if m:
            return m.group(1)
    return ""


def _first_line(s: str) -> str:
    for ln in s.split("\n"):
        t = ln.strip()
        if t:
            return t[:90] + "…" if len(t) > 90 else t
    return ""


def _build_row(idx: int, rec: dict) -> dict:
    meta = rec.get("meta", {})
    diff = str(meta.get("difficulty", "—"))
    src = str(meta.get("source", rec.get("source", "—")))
    py = jc = chosen = rejected = prompt = raw = ""
    kind = "raw"
    nm = ""

    if "messages" in rec:
        kind = "sft"
        msgs = rec["messages"]
        usr = str(msgs[0].get("content", "")) if len(msgs) > 0 else ""
        ast = str(msgs[1].get("content", "")) if len(msgs) > 1 else ""
        py = _fence(usr, "python")
        jc = _fence(ast, "jac")
        if not jc:
            jc = ast.strip()
        prompt = re.sub(r"(?s)```.*?```", "", usr).strip()
        nm = _funcname(py) or _funcname(jc)
    elif "chosen" in rec:
        kind = "dpo"
        prompt = re.sub(r"(?s)```.*?```", "", str(rec.get("prompt", ""))).strip()
        chosen = _fence(str(rec["chosen"]), "jac") or str(rec["chosen"]).strip()
        rejected = _fence(str(rec["rejected"]), "jac") or str(rec["rejected"]).strip()
        py = _fence(str(rec.get("prompt", "")), "python")
        nm = _funcname(chosen) or _funcname(py)
    elif "python" in rec:
        kind = "holdout"
        py = str(rec["python"])
        prompt = str(rec.get("prompt", ""))
        nm = str(rec.get("func_name", "")) or _funcname(py)
    else:
        raw = json.dumps(rec, indent=2)

    preview = _first_line(py) or _first_line(prompt) or _first_line(jc) or _first_line(chosen) or _first_line(raw)

    return {
        "idx": idx,
        "name": nm or "—",
        "difficulty": diff,
        "source": src,
        "kind": kind,
        "preview": preview,
        "prompt": prompt,
        "python": py,
        "jac": jc,
        "chosen": chosen,
        "rejected": rejected,
        "raw": raw,
    }


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def stats() -> dict:
    """Dataset statistics: counts per SFT file, DPO pairs, split sizes."""
    sft_rels = ["dataset/conversion/sft.jsonl", "dataset/conversion/sft_auto.jsonl"]
    sft_files = []
    grand = 0
    for rel in sft_rels:
        fs = _count_file(rel)
        sft_files.append(fs)
        grand += fs["total"]
    splits = {
        "mlx_train": _line_count(_abs("dataset/mlx/train.jsonl")),
        "mlx_valid": _line_count(_abs("dataset/mlx/valid.jsonl")),
        "dpo_train": _line_count(_abs("dataset/mlx_dpo/train.jsonl")),
        "dpo_valid": _line_count(_abs("dataset/mlx_dpo/valid.jsonl")),
        "holdout": _line_count(_abs("dataset/eval_holdout/conversion.jsonl")),
        "graph_holdout": _line_count(_abs("dataset/eval_holdout/graph_conversion.jsonl")),
    }
    return {
        "sft_files": sft_files,
        "sft_total": grand,
        "dpo_pairs": _line_count(_abs("dataset/conversion/dpo.jsonl")),
        "splits": splits,
    }


def list_files() -> list[dict]:
    """List all preview-allowed files with their line counts."""
    return [
        {"path": pair[0], "label": pair[1], "count": _line_count(_abs(pair[0]))}
        for pair in PREVIEW_FILES
    ]


def rows(rel: str, offset: int, limit: int) -> dict:
    """Return a page of parsed DataRow dicts from the JSONL file at *rel*.

    Raises ValueError if *rel* is not in PREVIEW_FILES.
    Limit is capped at 40.
    """
    if not _allowed_preview(rel):
        raise ValueError(f"path not allowed: {rel!r}")
    cap = max(1, min(limit, 40))
    p = _abs(rel)
    if not p.exists():
        return {"rows": [], "total": 0}
    lines = [ln for ln in p.read_text().split("\n") if ln.strip()]
    total = len(lines)
    result = []
    i = offset
    while i < total and i < offset + cap:
        try:
            rec = json.loads(lines[i])
            result.append(_build_row(i, rec))
        except Exception:
            pass
        i += 1
    return {"rows": result, "total": total}


def add_examples(target: str, text: str) -> dict:
    """Append valid JSONL rows to *target* (key in APPEND_TARGETS).

    Validates each non-empty line as JSON with the required schema fields.
    Raises ValueError for unknown target keys.
    """
    if target not in APPEND_TARGETS:
        raise ValueError(f"unknown target: {target!r}")
    rel = APPEND_TARGETS[target]
    is_dpo = target == "dpo"
    valid = []
    errors = []
    n = 0
    for raw in text.split("\n"):
        if not raw.strip():
            continue
        n += 1
        try:
            rec = json.loads(raw)
        except Exception:
            errors.append(f"line {n}: not valid JSON")
            continue
        if is_dpo:
            if not all(k in rec for k in ("prompt", "chosen", "rejected")):
                errors.append(f"line {n}: DPO row needs prompt/chosen/rejected")
                continue
        else:
            if "messages" not in rec:
                errors.append(f"line {n}: SFT row needs a messages list")
                continue
        valid.append(json.dumps(rec))

    if valid:
        p = _abs(rel)
        p.parent.mkdir(parents=True, exist_ok=True)
        if p.exists() and p.stat().st_size > 0:
            with open(p, "rb") as f:
                f.seek(-1, 2)
                if f.read(1) != b"\n":
                    with open(p, "a") as fa:
                        fa.write("\n")
        with open(p, "a") as fa:
            fa.write("\n".join(valid) + "\n")

    return {"added": len(valid), "errors": errors, "total": _line_count(_abs(rel))}
