"""Dataset stats / preview / ingest for the Ingest screen.

Read-only stats mirror srccurrent/jacgen/dataset_stats.jac. Preview pages any of
the known JSONL files. add_examples appends validated raw rows to the conversion
source files (sft.jsonl / dpo.jsonl) so the builders pick them up on the next run
(triggered from the same screen via services/jobs.run_builder).
"""

import json;
import os;
import from pathlib { Path }


obj FileStat {
    has path: str,
        total: int,
        by_difficulty: dict,
        by_generator: dict,
        by_source: dict;
}


obj DatasetStats {
    has sft_files: list[FileStat],
        sft_total: int,
        dpo_pairs: int,
        splits: dict;
}


obj FileRef {
    has path: str,
        label: str,
        count: int;
}


# Files the preview + ingest are allowed to touch (no arbitrary fs access).
glob PREVIEW_FILES: list[list[str]] = [
    ["dataset/conversion/sft.jsonl", "SFT idiomatic core"],
    ["dataset/conversion/sft_auto.jsonl", "SFT transpile volume"],
    ["dataset/conversion/dpo.jsonl", "DPO pairs"],
    ["dataset/mlx/train.jsonl", "MLX SFT train"],
    ["dataset/mlx/valid.jsonl", "MLX SFT valid"],
    ["dataset/mlx_dpo/train.jsonl", "MLX DPO train"],
    ["dataset/mlx_dpo/valid.jsonl", "MLX DPO valid"],
    ["dataset/eval_holdout/conversion.jsonl", "Holdout (function)"],
    ["dataset/eval_holdout/graph_conversion.jsonl", "Holdout (graph)"],
];
glob APPEND_TARGETS: list[str] = ["dataset/conversion/sft.jsonl", "dataset/conversion/dpo.jsonl"];


def _root() -> str {
    if Path("results").exists() { return str(Path(".").resolve()); }
    if Path("../results").exists() { return str(Path("..").resolve()); }
    return str(Path(os.environ.get("DG_ROOT", "..")).resolve());
}


def _abs(rel: str) -> str {
    return _root() + "/" + rel;
}


def _allowed_preview(rel: str) -> bool {
    for pair in PREVIEW_FILES {
        if pair[0] == rel { return True; }
    }
    return False;
}


def _line_count(path: str) -> int {
    p = Path(path);
    if not p.exists() { return 0; }
    n: int = 0;
    for line in p.read_text().split("\n") { if line.strip() != "" { n += 1; } }
    return n;
}


def _count_file(rel: str) -> FileStat {
    by_diff: dict = {}; by_gen: dict = {}; by_src: dict = {};
    total: int = 0;
    p = Path(_abs(rel));
    if not p.exists() {
        return FileStat(path=rel, total=0, by_difficulty=by_diff, by_generator=by_gen, by_source=by_src);
    }
    for line in p.read_text().split("\n") {
        if line.strip() == "" { continue; }
        rec: dict = dict(json.loads(line));
        meta: dict = dict(rec.get("meta", {}));
        diff: str = str(meta.get("difficulty", "?"));
        gen: str = str(meta.get("generator", "?"));
        src: str = str(meta.get("source", "?"));
        by_diff[diff] = int(by_diff.get(diff, 0)) + 1;
        by_gen[gen] = int(by_gen.get(gen, 0)) + 1;
        by_src[src] = int(by_src.get(src, 0)) + 1;
        total += 1;
    }
    return FileStat(path=rel, total=total, by_difficulty=by_diff, by_generator=by_gen, by_source=by_src);
}


def:pub dataset_stats() -> DatasetStats {
    sft_rel: list[str] = ["dataset/conversion/sft.jsonl", "dataset/conversion/sft_auto.jsonl"];
    files: list[FileStat] = [];
    grand: int = 0;
    for rel in sft_rel {
        fs: FileStat = _count_file(rel);
        files.append(fs);
        grand += fs.total;
    }
    splits: dict = {
        "mlx_train": _line_count(_abs("dataset/mlx/train.jsonl")),
        "mlx_valid": _line_count(_abs("dataset/mlx/valid.jsonl")),
        "dpo_train": _line_count(_abs("dataset/mlx_dpo/train.jsonl")),
        "dpo_valid": _line_count(_abs("dataset/mlx_dpo/valid.jsonl")),
        "holdout": _line_count(_abs("dataset/eval_holdout/conversion.jsonl")),
        "graph_holdout": _line_count(_abs("dataset/eval_holdout/graph_conversion.jsonl")),
    };
    return DatasetStats(
        sft_files=files,
        sft_total=grand,
        dpo_pairs=_line_count(_abs("dataset/conversion/dpo.jsonl")),
        splits=splits,
    );
}


def:pub list_dataset_files() -> list[FileRef] {
    out: list[FileRef] = [];
    for pair in PREVIEW_FILES {
        out.append(FileRef(path=pair[0], label=pair[1], count=_line_count(_abs(pair[0]))));
    }
    return out;
}


def:pub sample_rows(rel: str, offset: int, limit: int) -> list[str] {
    # Paged JSONL preview -> compact JSON strings (client can't json-stringify).
    out: list[str] = [];
    if not _allowed_preview(rel) { return out; }
    cap: int = limit;
    if cap > 50 { cap = 50; }
    if cap < 1 { cap = 1; }
    p = Path(_abs(rel));
    if not p.exists() { return out; }
    lines: list[str] = [];
    for line in p.read_text().split("\n") { if line.strip() != "" { lines.append(line); } }
    i: int = offset;
    while i < len(lines) and i < offset + cap {
        try {
            rec: dict = dict(json.loads(lines[i]));
            out.append(json.dumps(rec));
        } except Exception {
            out.append(str(lines[i]));
        }
        i += 1;
    }
    return out;
}


def:pub add_examples(target: str, text: str) -> dict {
    # Append one-JSON-object-per-line `text` to an allowed conversion file.
    if target not in APPEND_TARGETS {
        return {"added": 0, "errors": ["target not allowed"], "total": 0};
    }
    is_dpo: bool = target.endswith("dpo.jsonl");
    valid: list = [];
    errors: list = [];
    n: int = 0;
    for raw in text.split("\n") {
        if raw.strip() == "" { continue; }
        n += 1;
        try {
            rec: dict = dict(json.loads(raw));
        } except Exception {
            errors.append("line " + str(n) + ": not valid JSON");
            continue;
        }
        if is_dpo {
            if "prompt" not in rec or "chosen" not in rec or "rejected" not in rec {
                errors.append("line " + str(n) + ": DPO row needs prompt/chosen/rejected");
                continue;
            }
        } else {
            if "messages" not in rec {
                errors.append("line " + str(n) + ": SFT row needs a messages list");
                continue;
            }
        }
        valid.append(json.dumps(rec));
    }
    if len(valid) > 0 {
        p = Path(_abs(target));
        p.parent.mkdir(parents=True, exist_ok=True);
        existing: str = "";
        if p.exists() { existing = p.read_text(); }
        if existing != "" and not existing.endswith("\n") { existing += "\n"; }
        p.write_text(existing + "\n".join(valid) + "\n");
    }
    return {"added": len(valid), "errors": errors, "total": _line_count(_abs(target))};
}
