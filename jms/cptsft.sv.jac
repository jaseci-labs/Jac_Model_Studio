"""studio - 04-cpt-sft dataset browser + three-arm plan status (read-only).

Surfaces the dataset-generation effort in model-experiments/04-cpt-sft: a frozen
7-category SFT + DPO release plus carved eval holdouts. Like rl.sv.jac / cpt.sv.jac,
this data lives in THIS repo (jac_ml_studio), not the studio's data_root, so paths
resolve against the workspace root via paths.resolve(rel, "workspace").

Browse-only (no builder/launcher): the generation pipeline already ran and the pool
is frozen (dataset/shared/pool_hashes.json). Endpoints:
  cptsft_stats()   -> counts + per-category composition + holdout counts
  cptsft_files()   -> allowlisted browsable files with line counts
  cptsft_rows()    -> a page of parsed DataRowView rows (offset-paginated)
  cptsft_plan_status() -> live three-arm training/eval protocol status

Reuses data.sv.jac's DataRowView / FileRefView so the shared RowBrowser renders
these rows unchanged. Row parsing is local (like cpt.sv.jac's own _build_row): 04's
rows carry category/complexity/task_type at top level (no `meta` envelope), unlike
01's meta.difficulty/meta.source shape.
"""

import json;
import re;
import auth;
import train;
import metrics;
import paths;
import from pathlib { Path }
import from data { FileRefView, DataRowView, _count_lines_cached }

glob _ROOT: str = "model-experiments/04-cpt-sft";

# Browsable files (allowlist) as [rel, label]. NEVER the raw_output/rejected/logs/
# clean_dataset intermediates — only the frozen releases + carved holdouts.
glob _FILES: list[list[str]] = [
    ["model-experiments/04-cpt-sft/dataset/fresh/releases/sft_train.jsonl", "SFT · train"],
    ["model-experiments/04-cpt-sft/dataset/fresh/releases/dpo_train.jsonl", "DPO · train"],
    ["model-experiments/04-cpt-sft/dataset/shared/holdouts/code_gen_holdout.jsonl", "holdout · code_gen"],
    ["model-experiments/04-cpt-sft/dataset/shared/holdouts/debug_holdout.jsonl", "holdout · debug"],
    ["model-experiments/04-cpt-sft/dataset/shared/holdouts/explanation_holdout.jsonl", "holdout · explanation"],
    ["model-experiments/04-cpt-sft/dataset/shared/holdouts/documentation_holdout.jsonl", "holdout · documentation"],
    ["model-experiments/04-cpt-sft/dataset/shared/holdouts/trajectory_holdout.jsonl", "holdout · trajectory"],
    ["model-experiments/04-cpt-sft/dataset/shared/holdouts/migration_holdout.jsonl", "holdout · migration"]
];

# 7 SFT categories in display order (largest-first, from the on-disk build).
glob _CATS: list[str] = [
    "explanation", "code_gen", "conversion", "documentation", "trajectory", "debug", "migration"
];

# 5 DPO preference axes in display order (largest-first, from the on-disk build).
glob _AXES: list[str] = [
    "graph_native", "idiomatic", "correctness", "auth_security", "typing"
];

glob _HOLDOUT_FILES: list[list[str]] = [
    ["model-experiments/04-cpt-sft/dataset/shared/holdouts/code_gen_holdout.jsonl", "code_gen"],
    ["model-experiments/04-cpt-sft/dataset/shared/holdouts/debug_holdout.jsonl", "debug"],
    ["model-experiments/04-cpt-sft/dataset/shared/holdouts/explanation_holdout.jsonl", "explanation"],
    ["model-experiments/04-cpt-sft/dataset/shared/holdouts/documentation_holdout.jsonl", "documentation"],
    ["model-experiments/04-cpt-sft/dataset/shared/holdouts/trajectory_holdout.jsonl", "trajectory"],
    ["model-experiments/04-cpt-sft/dataset/shared/holdouts/migration_holdout.jsonl", "migration"]
];

glob _SFT_REL: str = "model-experiments/04-cpt-sft/dataset/fresh/releases/sft_train.jsonl";
glob _DPO_REL: str = "model-experiments/04-cpt-sft/dataset/fresh/releases/dpo_train.jsonl";

def _abs(rel: str) -> Path {
    return paths.resolve(rel, "workspace");
}

# --------------------------------------------------------- stats memoization ---
# cptsft_stats() JSON-parses every row of sft_train.jsonl + dpo_train.jsonl and
# reads all 6 holdouts. The pool is FROZEN (dataset/shared/pool_hashes.json), so
# the answer only ever changes when one of those 8 files changes on disk. Cache
# key = the (abs path, st_mtime_ns, st_size) triple of each input file joined —
# any rebuild/edit misses the cache. Paths are workspace-absolute (shared, not
# per-user data), so one entry serves every caller; the cache is cleared before
# each insert so it can never hold more than the current signature.
glob _STATS_CACHE: dict[str, dict] = {};

"""Cache signature over *rels*: path + mtime_ns + size of each, missing -> "missing"."""
def _sig(rels: list[str]) -> str {
    parts: list[str] = [];
    for rel in rels {
        p = _abs(rel);
        try {
            st = p.stat();
            parts.append(str(p) + ":" + str(st.st_mtime_ns) + ":" + str(st.st_size));
        } except Exception {
            parts.append(str(p) + ":missing");
        }
    }
    return "|".join(parts);
}

def _allowed(rel: str) -> bool {
    for pair in _FILES {
        if pair[0] == rel { return True; }
    }
    return False;
}

"""Row-level filter predicate for cptsft_rows: does *rec* pass the (optional)
category + axis filters? Empty string means that axis is unconstrained. Pure
(no filesystem) so the filter logic is unit-testable."""
def _row_matches(rec: any, category: str, axis: str) -> bool {
    if category and str(rec.get("category", "")) != category { return False; }
    if axis and str(rec.get("axis", "")) != axis { return False; }
    return True;
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

def _fence(text: str, lang: str) -> str {
    m = re.search("(?s)```" + lang + "[^\n]*\n(.*?)```", text);
    if m { return m.group(1).strip(); }
    m2 = re.search("(?s)```[A-Za-z0-9]*\\s*\n(.*?)```", text);
    if m2 { return m2.group(1).strip(); }
    return "";
}

def _strip_fences(s: str) -> str {
    return re.sub("(?s)```.*?```", "", s).strip();
}

def _funcname(code: str) -> str {
    for pat in ["def\\s+(\\w+)", "walker\\s+(\\w+)", "node\\s+(\\w+)", "obj\\s+(\\w+)", "class\\s+(\\w+)"] {
        m = re.search(pat, code);
        if m { return m.group(1); }
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

"""Parse one 04-cpt-sft record into a DataRowView. SFT + holdout rows are
{messages:[user,assistant]} with top-level category/complexity/task_type; DPO rows
are {prompt,chosen,rejected,axis}. Source column carries category (SFT) / axis (DPO),
difficulty carries complexity."""
def _build_row(idx: int, rec: any) -> DataRowView {
    cat = str(rec.get("category", ""));
    cx = str(rec.get("complexity", ""));
    py = ""; jc = ""; chosen = ""; rejected = ""; prompt = ""; raw = "";
    kind = "raw"; nm = "";
    if "messages" in rec {
        kind = "sft";
        msgs = list(rec["messages"]);
        mcount = len(msgs);
        usr = str(msgs[0].get("content", "")) if mcount > 0 else "";
        ast = str(msgs[1].get("content", "")) if mcount > 1 else "";
        py = _fence(usr, "python");
        jc = _fence(ast, "jac");
        if not jc { jc = ast.strip(); }
        prompt = _strip_fences(usr);
        nm = str(rec.get("task_type", "")) or _funcname(py) or _funcname(jc);
    } elif "chosen" in rec {
        kind = "dpo";
        prompt = _strip_fences(str(rec.get("prompt", "")));
        chosen = _fence(str(rec["chosen"]), "jac") or str(rec["chosen"]).strip();
        rejected = _fence(str(rec["rejected"]), "jac") or str(rec["rejected"]).strip();
        cat = str(rec.get("axis", cat));
        nm = str(rec.get("axis", "")) or _funcname(chosen);
    } else {
        raw = json.dumps(rec, indent=2);
    }
    preview = _first_line(prompt) or _first_line(jc) or _first_line(chosen) or _first_line(raw);
    return DataRowView(
        idx=idx, name=nm or "—", difficulty=cx or "—", source=cat or "—",
        kind=kind, preview=preview, prompt=prompt, python=py, jac=jc,
        chosen=chosen, rejected=rejected, raw=raw
    );
}

"""Dataset stats: SFT total + per-category composition, DPO pairs + per-axis
composition (both pct as per-mille 0-1000 so the client avoids float math), and
carved holdout counts. `categories`/`axes` double as the client's filter-option
source for the SFT/DPO row-level filters (see cptsft_rows)."""
def cptsft_stats() -> dict {
    inputs: list[str] = [_SFT_REL, _DPO_REL];
    for hp in _HOLDOUT_FILES { inputs.append(hp[0]); }
    key = _sig(inputs);
    hit = _STATS_CACHE.get(key);
    # ponytail: the memo hands back the SAME dict object on a hit. Every caller
    # (cptsft_plan_status, the RPC serializer) treats it read-only; nothing in the
    # app mutates a stats result, so no defensive copy.
    if hit is not None { return hit; }

    sft_lines = _read_lines(_SFT_REL);
    sft_total = len(sft_lines);
    counts: dict = {};
    for ln in sft_lines {
        try {
            r = json.loads(str(ln));
            c = str(r.get("category", "other"));
            counts[c] = int(counts.get(c, 0)) + 1;
        } except Exception {}
    }
    categories: list = [];
    seen: list = [];
    for c in _CATS {
        n = int(counts.get(c, 0));
        if n > 0 {
            pct = (n * 1000) // sft_total if sft_total > 0 else 0;
            categories.append({"name": c, "count": n, "pct": pct});
            seen.append(c);
        }
    }
    # any category not in the known order still gets surfaced (honest, no hiding)
    for c in counts {
        if c not in seen {
            n = int(counts[c]);
            pct = (n * 1000) // sft_total if sft_total > 0 else 0;
            categories.append({"name": str(c), "count": n, "pct": pct});
        }
    }

    # DPO axis composition, same shape/logic as categories (largest-first order,
    # any unknown axis still surfaced honestly).
    dpo_lines = _read_lines(_DPO_REL);
    dpo_total = len(dpo_lines);
    acounts: dict = {};
    for ln in dpo_lines {
        try {
            r = json.loads(str(ln));
            a = str(r.get("axis", "other"));
            acounts[a] = int(acounts.get(a, 0)) + 1;
        } except Exception {}
    }
    axes: list = [];
    aseen: list = [];
    for a in _AXES {
        n = int(acounts.get(a, 0));
        if n > 0 {
            pct = (n * 1000) // dpo_total if dpo_total > 0 else 0;
            axes.append({"name": a, "count": n, "pct": pct});
            aseen.append(a);
        }
    }
    for a in acounts {
        if a not in aseen {
            n = int(acounts[a]);
            pct = (n * 1000) // dpo_total if dpo_total > 0 else 0;
            axes.append({"name": str(a), "count": n, "pct": pct});
        }
    }

    holdouts: list = [];
    htotal = 0;
    for pair in _HOLDOUT_FILES {
        n = _count_lines_cached(_abs(pair[0]));
        holdouts.append({"name": pair[1], "count": n});
        htotal += n;
    }

    out: dict = {
        "sft_total": sft_total,
        "dpo_pairs": dpo_total,
        "categories": categories,
        "axes": axes,
        "holdouts": holdouts,
        "holdout_total": htotal
    };
    _STATS_CACHE.clear();
    _STATS_CACHE[key] = out;
    return out;
}

"""All allowlisted browsable files with line counts."""
def cptsft_files() -> list[FileRefView] {
    out: list[FileRefView] = [];
    for pair in _FILES {
        out.append(FileRefView(path=pair[0], label=pair[1], count=_count_lines_cached(_abs(pair[0]))));
    }
    return out;
}

"""A page of parsed rows from an allowlisted jsonl (cap 40), gated by the allowlist.

Optional row-level filters: `category` scopes SFT/holdout rows to `row["category"]`,
`axis` scopes DPO rows to `row["axis"]`. Empty string (the default) means no filter
— identical to the original offset-into-file pagination, so old callers are
unchanged. With a filter set, pagination is over the FILTERED set (total = matched
count, offset indexes into matches), so we scan the whole file to build a matched
index first (O(total) — fine at these ≤10k row counts, same reasoning as
jms_curate.curate_rows). The returned row `idx` stays the on-disk line index so
expand/toggle keys remain unique and truthful."""
def cptsft_rows(path: str, offset: int, limit: int, category: str = "", axis: str = "") -> dict {
    if not _allowed(path) {
        return {"rows": [], "total": 0};
    }
    cap = max(1, min(limit, 40));
    lines = _read_lines(path);

    # fast path: no filter → original offset-into-file pagination, unchanged.
    if not category and not axis {
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

    # filtered path: build the matched (on-disk index, record) list, then slice.
    matched: list = [];
    li = 0;
    for ln in lines {
        try {
            rec = json.loads(str(ln));
            if _row_matches(rec, category, axis) { matched.append({"idx": li, "rec": rec}); }
        } except Exception {}
        li += 1;
    }
    mtotal = len(matched);
    filtered: list[DataRowView] = [];
    j = max(0, offset);
    while j < mtotal and j < offset + cap {
        m = matched[j];
        filtered.append(_build_row(int(m["idx"]), m["rec"]));
        j += 1;
    }
    return {"rows": filtered, "total": mtotal};
}

# ---------------------------------------------------------------- plan status

"""Any training runs whose name marks them as an Arm A/B/C run for this effort,
cross-checked live against the caller's real results tree (train.list_sessions),
not just the design doc. Matches names containing 'arm' or 'cpt-sft' / 'cptsft'."""
def _arm_runs() -> list {
    out: list = [];
    try {
        sess = train.list_sessions();
        for s in list(sess.get("sessions", [])) {
            nm = str(s.get("name", "")).lower();
            if ("arm" in nm) or ("cpt-sft" in nm) or ("cptsft" in nm) {
                out.append({
                    "name": str(s.get("name", "")),
                    "mode": str(s.get("mode", "")),
                    "status": str(s.get("status", ""))
                });
            }
        }
    } except Exception {}
    return out;
}

def _train_status_for(runs: list, tag: str) -> str {
    for r in runs {
        if tag in str(r["name"]).lower() { return str(r["status"]); }
    }
    return "not started";
}

"""Eval state of ONE run directory, read off the caller's real results tree the
same way _train_status_for reads the training side.

The eval an arm gets is the holdout probe, and the probe writes its scores into the
run dir as idiom-metrics.jsonl / graph-idiom*.jsonl — exactly the artifacts
metrics.idiom_summary already picks up for the Train HISTORY view. A row carrying
`avg_sim` means a probe genuinely ran and scored; nothing on disk means nothing has
been evaluated yet. "finished" matches list_sessions' own vocabulary for a job that
is no longer running (train.list_sessions maps idle -> "finished")."""
def _eval_state_of_run(name: str, mode: str) -> str {
    try {
        rdir = auth.user_results_dir() / name;
        if not rdir.exists() { return "not started"; }
        if metrics.idiom_summary(rdir, mode, "function") { return "finished"; }
        if metrics.idiom_summary(rdir, mode, "graph") { return "finished"; }
    } except Exception {
        return "unknown";
    }
    return "not started";
}

"""Real eval state for the arm whose run name carries *tag*. No matching run at all
-> "not started" (nothing can have been evaluated). Mirrors _train_status_for's
first-match-wins lookup and its vocabulary."""
def _eval_status_for(runs: list, tag: str) -> str {
    for r in runs {
        if tag in str(r["name"]).lower() {
            return _eval_state_of_run(str(r["name"]), str(r["mode"]));
        }
    }
    return "not started";
}

"""Live three-arm protocol status: reads real on-disk state (fresh build counts,
whether post_cptv2 / the CPT-v2 base adapter exist, pool freeze metadata) and
cross-checks the caller's results tree for any Arm A/B/C run. Nothing fabricated —
pending is reported as pending, and anything this function cannot determine from
disk is reported as "unknown" rather than guessed.

The `base` / `dataset` / `train`-for-Incumbent strings are protocol DESCRIPTIONS
(what each arm is defined to be), not measured state. Every state cell — the arms'
`train` and `eval` — is derived from the results tree on each call. Note this is
deliberately NOT covered by cptsft_stats' memo: the dataset pool is frozen, run and
eval state are not."""
def cptsft_plan_status() -> dict {
    stats = cptsft_stats();
    sft_total = int(stats["sft_total"]);
    dpo_pairs = int(stats["dpo_pairs"]);

    fresh_done = sft_total > 0 and dpo_pairs > 0;
    post_cptv2_exists = _abs(_ROOT + "/dataset/post_cptv2").exists();
    cptv2_base_exists = _abs("model-experiments/03-cpt-only/adapters/cpt-v2").exists();

    pool: dict = {"frozen_at": "", "n_hashes": 0};
    ph = _abs(_ROOT + "/dataset/shared/pool_hashes.json");
    if ph.exists() {
        try {
            pj = json.loads(ph.read_text());
            pool["frozen_at"] = str(pj.get("frozen_at", ""));
            pool["n_hashes"] = len(dict(pj.get("hashes", {})));
        } except Exception {}
    }

    runs = _arm_runs();
    post_ds = "fresh (" + str(sft_total) + " SFT / " + str(dpo_pairs) + " DPO)";
    post_pending = "post_cptv2 (pending)" if not post_cptv2_exists else "post_cptv2 (built)";
    cptv2_base = "CPT-v2 · 03-cpt-only/adapters/cpt-v2" + ("" if cptv2_base_exists else " (missing)");

    blocked = "blocked · dataset pending";
    arms: list = [
        {
            "arm": "Incumbent", "base": "588-ex conversion checkpoint",
            "dataset": "conversion-only (n=588)", "train": "reference (eval-only)",
            # The incumbent is a reference checkpoint, not an Arm run — no run name
            # in the results tree identifies it, so its eval state is genuinely not
            # derivable here. Say "unknown" rather than assert a confident
            # "not started" this function cannot actually know.
            "eval": "unknown"
        },
        {
            "arm": "A", "base": "pre-CPT base (qwen-q4)",
            "dataset": post_ds,
            "train": _train_status_for(runs, "arm-a") if runs else "not started",
            "eval": _eval_status_for(runs, "arm-a") if runs else "not started"
        },
        {
            "arm": "B", "base": cptv2_base,
            "dataset": post_pending,
            "train": _train_status_for(runs, "arm-b") if post_cptv2_exists else blocked,
            # dataset pending blocks the eval exactly as it blocks the train.
            "eval": _eval_status_for(runs, "arm-b") if post_cptv2_exists else blocked
        },
        {
            "arm": "C", "base": "pre-CPT base (qwen-q4)",
            "dataset": post_pending,
            "train": _train_status_for(runs, "arm-c") if post_cptv2_exists else blocked,
            "eval": _eval_status_for(runs, "arm-c") if post_cptv2_exists else blocked
        }
    ];

    return {
        "fresh_done": fresh_done,
        "sft_total": sft_total,
        "dpo_pairs": dpo_pairs,
        "holdout_total": int(stats["holdout_total"]),
        "post_cptv2_exists": post_cptv2_exists,
        "cptv2_base_exists": cptv2_base_exists,
        "pool": pool,
        "arms": arms,
        "arm_runs": runs,
        "categories": stats["categories"]
    };
}
