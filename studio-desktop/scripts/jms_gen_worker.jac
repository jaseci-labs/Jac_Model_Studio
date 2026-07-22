"""jms_gen_worker — standalone synthetic-dataset generation worker (P5 engine).

Spawned DETACHED by jms_gen.sv.jac `start_gen` as `jac run
scripts/jms_gen_worker.jac` (cwd = studio root). This is a plain program: it has
NO auth or graph context and touches ONLY the filesystem. Everything it needs
arrives via the env contract + two server-written snapshots in the project dir:

  JMS_PROJECT_DIR   abs project dir (contains project.json + plan.json)
  JMS_JOB_ID        job id (progress lands in jobs/<jid>/progress.json)
  JMS_PROVIDER      claude | mlx
  JMS_MODEL         provider model id
  JMS_TARGET_ROWS   soft target (stop when reached)
  JMS_MAX_ROWS      hard cap (never append beyond this)
  JMS_BATCH         examples per LLM call (default 8)
  JMS_REGEN_OF      comma row-ids → regeneration mode (same-type replacements)
  JMS_PRICE_IN/OUT  $/Mtok for the chars//4 cost accounting
  ANTHROPIC_API_KEY (claude)  JMS_MLX_MODEL_PATH (mlx: abs model dir)

Flow: chunk pass (per-source sources/<sid>.chunks.jsonl, line-aligned ~2500-3500
est-token chunks, no text stored — re-read from path+lines at prompt time) →
batch loop (weighted-round-robin type pick from the plan mix, 3 least-used-dir
chunks as grounding, one strict-JSON-array LLM call per batch, per-row
validation, per-batch append to dataset/raw.jsonl + progress.json update).

Providers: claude = direct Anthropic REST call via urllib (chosen over a byllm
typed def — a graph-less worker wants zero framework surface and a clean HTTP
401 on the fake-key probe); mlx = own mlx_lm copy of the model (the server took
the heavy lock for us).

SIGTERM: sets a stop flag and exits 143 immediately unless a file write is in
flight (then the write finishes first) — appends stay per-batch atomic-ish.
Exit codes: 0 done, 1 generation failure, 2 config error, 143 stopped.

The scanner filters + row validator are MINIMAL DUPLICATES of
jms_projects.sv.jac (_EX_DIRS/_BINARY_EXT/_INC_*/_included) and
jms_gen.sv.jac (validate_row) — workers cannot import server modules; keep in
sync with those masters.
"""

import json;
import os;
import sys;
import time;
import datetime;
import fnmatch;
import importlib;
import from pathlib { Path }
import from uuid { uuid4 }
import from signal { signal, SIGTERM }
import from http.client { HTTPSConnection }

# ---------------------------------------------------------- scan filter dup ----
# Duplicated from jms_projects.sv.jac (master copy) — keep in sync.
glob _EX_DIRS: list[str] = [".git", "node_modules", "dist", "build", ".venv", "__pycache__", ".jac"];
glob _BINARY_EXT: list[str] = [
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".bmp", ".tiff", ".svg",
    ".pdf", ".zip", ".gz", ".tar", ".tgz", ".bz2", ".xz", ".7z", ".rar",
    ".exe", ".dll", ".bin", ".so", ".dylib", ".o", ".a", ".class", ".jar",
    ".woff", ".woff2", ".ttf", ".otf", ".eot",
    ".mp4", ".mp3", ".wav", ".mov", ".avi", ".mkv", ".flac", ".ogg",
    ".pyc", ".pyo", ".db", ".sqlite", ".sqlite3", ".npy", ".npz", ".safetensors", ".gguf"
];
glob _INC_CODE: list[str] = [".py", ".js", ".ts", ".tsx", ".jac", ".go", ".rs", ".java", ".c", ".cpp", ".h", ".md"];
glob _INC_DOCS: list[str] = [".md", ".rst", ".txt", ".mdx"];
glob _MAX_BYTES: int = 1048576;
glob _MAX_FILES: int = 50000;

# Chunking targets: chars//4 token estimate; emit at ~12k chars (~3000 tok).
glob _CHUNK_EMIT_CHARS: int = 12000;
glob _CHUNKS_PER_BATCH: int = 3;

# Mutated in place (no `global` needed — the module-glob trick).
glob _STATE: dict[str, any] = {"stop": False, "writing": False};
glob _MLX: dict[str, any] = {"model": None, "tokenizer": None};

def _now() -> str {
    return datetime.datetime.now(datetime.UTC).replace(tzinfo=None).isoformat() + "Z";
}

def _log(msg: str) -> None {
    print(msg, flush=True);
}

def _env_int(name: str, fallback: int) -> int {
    try {
        return int(str(os.environ.get(name, str(fallback))));
    } except Exception {
        return fallback;
    }
}

def _env_float(name: str, fallback: float) -> float {
    try {
        return float(str(os.environ.get(name, str(fallback))));
    } except Exception {
        return fallback;
    }
}

"""SIGTERM → stop; exit 143 now unless a file write is mid-flight (the write
finishes, then the loop exits)."""
def _on_term(signum: any, frame: any) -> None {
    _STATE["stop"] = True;
    if not bool(_STATE["writing"]) {
        _log("[stop] SIGTERM — exiting");
        sys.exit(143);
    }
}

# ------------------------------------------------------------- chunk pass ------
"""Dup of jms_projects._included — keep in sync."""
def _included(fname: str, ext: str, kind: str, inc: list[str], exc: list[str]) -> bool {
    for pat in exc {
        if fnmatch.fnmatch(fname, pat) { return False; }
    }
    if fname.endswith(".lock") { return False; }
    if ext in _BINARY_EXT { return False; }
    if inc {
        for pat in inc {
            if fnmatch.fnmatch(fname, pat) { return True; }
        }
        return False;
    }
    defaults = _INC_CODE if kind == "code" else _INC_DOCS;
    return ext in defaults;
}

"""Included files under *spath* as {"abs", "rel"} dicts (scanner filter rules).
Returns a bare `list` — iterating a `list[dict]` and touching the loop var
crashes the 0.16.1 checker; bare list + isinstance narrowing is the safe form."""
def _walk_source(spath: str, kind: str, inc: list[str], exc: list[str]) -> list {
    out: list = [];
    walked = 0;
    for (dp, dns, fns) in os.walk(spath) {
        keep = [d for d in dns if d not in _EX_DIRS];
        dns.clear();
        dns.extend(keep);
        for fn in fns {
            walked = walked + 1;
            if walked > _MAX_FILES { return out; }
            ext = os.path.splitext(fn)[1].lower();
            if not _included(fn, ext, kind, inc, exc) { continue; }
            full = os.path.join(dp, fn);
            try {
                if int(os.path.getsize(full)) > _MAX_BYTES { continue; }
            } except Exception { continue; }
            out.append({"abs": full, "rel": os.path.relpath(full, spath)});
        }
    }
    return out;
}

"""Split one file into line-aligned chunks of ~_CHUNK_EMIT_CHARS chars. Rows
carry path (rel) + line range + est tokens; the text is re-read at prompt time."""
def _chunk_file(abspath: str, rel: str) -> list {
    txt = "";
    try {
        f: any = open(abspath, "r", encoding="utf-8", errors="replace");
        txt = str(f.read());
        f.close();
    } except Exception {
        return [];
    }
    lines = txt.splitlines();
    out: list = [];
    cur_start = 1;
    buf = 0;
    i = 0;
    while i < len(lines) {
        buf = buf + len(lines[i]) + 1;
        if buf >= _CHUNK_EMIT_CHARS {
            out.append({"path": rel, "start_line": cur_start, "end_line": i + 1, "text_tokens": buf // 4});
            cur_start = i + 2;
            buf = 0;
        }
        i = i + 1;
    }
    if buf > 0 {
        out.append({"path": rel, "start_line": cur_start, "end_line": len(lines), "text_tokens": buf // 4});
    }
    return out;
}

"""Ensure every source has a FRESH sources/<sid>.chunks.jsonl (fresh = mtime
newer than project.json). Returns the total chunk count across sources."""
def _ensure_chunks(pdir: Path, project: dict[str, any]) -> int {
    pj_mtime = float((pdir / "project.json").stat().st_mtime);
    total = 0;
    srcs_in: any = project.get("sources", []);
    if not isinstance(srcs_in, list) { return 0; }
    for src in srcs_in {
        if not isinstance(src, dict) { continue; }
        sid = str(src.get("sid", ""));
        cf = pdir / "sources" / (sid + ".chunks.jsonl");
        if cf.exists() and float(cf.stat().st_mtime) > pj_mtime {
            n = len([ln for ln in cf.read_text().splitlines() if ln.strip()]);
            _log(f"[chunk] {sid}: fresh ({n} chunks)");
            total = total + n;
            continue;
        }
        inc = [str(x) for x in list(src.get("include", []))];
        exc = [str(x) for x in list(src.get("exclude", []))];
        rows: list = [];
        files: any = _walk_source(str(src.get("path", "")), str(src.get("kind", "code")), inc, exc);
        for fd in files {
            if not isinstance(fd, dict) { continue; }
            chs: any = _chunk_file(str(fd.get("abs", "")), str(fd.get("rel", "")));
            # .extend(any) crashes the 0.16.1 checker — append in a loop.
            for ch in chs { rows.append(ch); }
        }
        _STATE["writing"] = True;
        cf.parent.mkdir(parents=True, exist_ok=True);
        cf.write_text("\n".join([json.dumps(r) for r in rows]) + ("\n" if rows else ""));
        _STATE["writing"] = False;
        _log(f"[chunk] {sid}: wrote {len(rows)} chunks");
        total = total + len(rows);
    }
    return total;
}

"""In-memory chunk index: {"root", "path", "start_line", "end_line", "dir"}."""
def _load_index(pdir: Path, project: dict[str, any]) -> list {
    out: list = [];
    srcs_in: any = project.get("sources", []);
    if not isinstance(srcs_in, list) { return out; }
    for src in srcs_in {
        if not isinstance(src, dict) { continue; }
        cf = pdir / "sources" / (str(src.get("sid", "")) + ".chunks.jsonl");
        if not cf.exists() { continue; }
        src_root = str(src.get("path", ""));
        for ln in cf.read_text().splitlines() {
            if not ln.strip() { continue; }
            c: dict[str, any] = {};
            try { c = dict(json.loads(ln)); } except Exception { continue; }
            rel = str(c.get("path", ""));
            if not rel { continue; }
            out.append({
                "root": src_root, "path": rel,
                "start_line": int(str(c.get("start_line", 1))),
                "end_line": int(str(c.get("end_line", 1))),
                "dir": os.path.dirname(rel)
            });
        }
    }
    return out;
}

"""Re-read a chunk's text from disk (1-based inclusive line range)."""
def _chunk_text(c: dict[str, any]) -> str {
    full = os.path.join(str(c["root"]), str(c["path"]));
    try {
        f: any = open(full, "r", encoding="utf-8", errors="replace");
        txt = str(f.read());
        f.close();
    } except Exception {
        return "";
    }
    lines = txt.splitlines();
    a = int(str(c["start_line"]));
    b = int(str(c["end_line"]));
    if a < 1 { a = 1; }
    if b > len(lines) { b = len(lines); }
    if b < a { return ""; }
    return "\n".join(lines[a - 1:b]);
}

# ------------------------------------------------------------ batch helpers ----
"""Deterministic weighted round-robin over the plan mix (share_pct credits).
*mix* is a bare list of dicts (see _walk_source note on the checker crash)."""
def _pick_type(mix: list, credits: dict[str, any]) -> dict[str, any] {
    total = 0;
    for m in mix {
        if not isinstance(m, dict) { continue; }
        share = int(str(m.get("share_pct", 0)));
        if share < 1 { share = 1; }
        name = str(m.get("type_name", "example"));
        credits[name] = int(str(credits.get(name, 0))) + share;
        total = total + share;
    }
    best: dict[str, any] = {};
    best_c = -999999999;
    for m in mix {
        if not isinstance(m, dict) { continue; }
        name = str(m.get("type_name", "example"));
        c = int(str(credits.get(name, 0)));
        if c > best_c {
            best_c = c;
            best = m;
        }
    }
    if not best { return {"type_name": "example", "description": "", "share_pct": 100}; }
    credits[str(best.get("type_name", "example"))] = best_c - total;
    return best;
}

"""Pick *k* distinct chunks, preferring least-used directories then least-used
chunks (coverage). Usage dicts are mutated in place across batches."""
def _sample_chunks(index: list, dir_use: dict[str, any], chunk_use: dict[str, any], k: int) -> list {
    picked: list = [];
    taken: dict[str, any] = {};
    for n in range(k) {
        best = -1;
        best_score = 0;
        for i in range(len(index)) {
            if str(i) in taken { continue; }
            ci: any = index[i];
            du = int(str(dir_use.get(str(ci["dir"]), 0)));
            cu = int(str(chunk_use.get(str(i), 0)));
            score = du * 1000000000 + cu * 1000 + (i % 1000);
            if best < 0 or score < best_score {
                best = i;
                best_score = score;
            }
        }
        if best < 0 { break; }
        taken[str(best)] = True;
        cb: any = index[best];
        d = str(cb["dir"]);
        dir_use[d] = int(str(dir_use.get(d, 0))) + 1;
        chunk_use[str(best)] = int(str(chunk_use.get(str(best), 0))) + 1;
        picked.append(cb);
    }
    return picked;
}

"""The batched instruction prompt: n examples of one type, grounded ONLY in the
given excerpts, STRICT JSON array of {"messages": [...]} objects."""
def _build_user(type_name: str, type_desc: str, n: int, excerpts: str) -> str {
    return (
        f"Generate exactly {n} training examples of type \"{type_name}\" ({type_desc}), "
        + "grounded ONLY in these source excerpts:\n\n" + excerpts + "\n\n"
        + "Output a STRICT JSON array of objects, each shaped "
        + "{\"messages\": [{\"role\": \"user\", \"content\": \"...\"}, {\"role\": \"assistant\", \"content\": \"...\"}]}. "
        + "Multi-turn conversations are allowed but every one must end with an assistant message, "
        + "and every content must be non-empty. "
        + "Output ONLY the JSON array — no prose, no code fences."
    );
}

"""First [...] JSON array in *txt* (tolerates fences/prose). None on a miss."""
def _extract_rows(txt: str) -> list | None {
    t = txt.strip();
    a = t.find("[");
    b = t.rfind("]");
    if a < 0 or b <= a { return None; }
    try {
        val: any = json.loads(t[a:b + 1]);
        if isinstance(val, list) { return list(val); }
        return None;
    } except Exception {
        return None;
    }
}

"""Dup of jms_gen.sv.jac validate_row (master copy) — keep in sync."""
def _valid_row(row: dict[str, any]) -> bool {
    msgs: any = row.get("messages", None);
    if not isinstance(msgs, list) or len(msgs) < 2 { return False; }
    prev = "";
    idx = 0;
    for m in msgs {
        if not isinstance(m, dict) { return False; }
        role = str(m.get("role", ""));
        content = str(m.get("content", ""));
        if not content.strip() { return False; }
        if idx == 0 {
            if role not in ["system", "user"] { return False; }
        } else {
            if role not in ["user", "assistant"] { return False; }
        }
        if role == prev { return False; }
        prev = role;
        idx = idx + 1;
    }
    return prev == "assistant";
}

# --------------------------------------------------------------- providers -----
"""One blocking Anthropic /v1/messages call via http.client (urllib.urlopen's
overloads crash the 0.16.1 checker). Raises RuntimeError with the HTTP status +
body snippet on an API error (the fake-key probe surfaces here)."""
def _claude_generate(model: str, key: str, system: str, user: str, max_out: int) -> str {
    body = json.dumps({
        "model": model,
        "max_tokens": max_out,
        "system": system,
        "messages": [{"role": "user", "content": user}]
    }).encode("utf-8");
    conn: any = HTTPSConnection("api.anthropic.com", timeout=600);
    txt = "";
    code = 0;
    try {
        conn.request("POST", "/v1/messages", body, {
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json"
        });
        resp: any = conn.getresponse();
        code = int(str(resp.status));
        txt = str(resp.read().decode("utf-8"));
    } finally {
        conn.close();
    }
    if code != 200 {
        raise RuntimeError(f"anthropic http {code}: {txt[:300]}");
    }
    data = dict(json.loads(txt));
    parts: list[str] = [];
    blks: any = data.get("content", []);
    for blk in blks {
        if isinstance(blk, dict) and str(blk.get("type", "")) == "text" {
            parts.append(str(blk.get("text", "")));
        }
    }
    return "".join(parts);
}

"""Load the worker's OWN mlx model copy once (the server holds the heavy lock)."""
def _mlx_load(path: str) -> None {
    # importlib indirection: `import from mlx_lm { load }` + a direct call
    # crashes the 0.16.1 checker's overload resolution.
    mod: any = importlib.import_module("mlx_lm");
    t0 = time.time();
    loaded: any = mod.load(path);
    _MLX["model"] = loaded[0];
    _MLX["tokenizer"] = loaded[1];
    _log(f"[mlx] model loaded in {int(time.time() - t0)}s: {path}");
}

"""Greedy decode (no sampler) — deterministic and the most JSON-reliable; the
`import from mlx_lm.sample_utils` form also crashes the 0.16.1 checker."""
def _mlx_generate(system: str, user: str, max_out: int) -> str {
    mod: any = importlib.import_module("mlx_lm");
    msgs: list = [
        {"role": "system", "content": system},
        {"role": "user", "content": user}
    ];
    ptoks: any = _MLX["tokenizer"].apply_chat_template(msgs, add_generation_prompt=True);
    out: any = mod.generate(
        _MLX["model"], _MLX["tokenizer"], ptoks,
        max_tokens=max_out, verbose=False
    );
    return str(out);
}

# ---------------------------------------------------------------- progress -----
"""Write jobs/<jid>/progress.json under the SIGTERM write-guard."""
def _write_progress(pdir: Path, jid: str, prog: dict[str, any]) -> None {
    _STATE["writing"] = True;
    pf = pdir / "jobs" / jid / "progress.json";
    pf.parent.mkdir(parents=True, exist_ok=True);
    pf.write_text(json.dumps(prog));
    _STATE["writing"] = False;
}

"""Append rows to dataset/raw.jsonl under the SIGTERM write-guard."""
def _append_rows(pdir: Path, rows: list) -> None {
    _STATE["writing"] = True;
    rawf = pdir / "dataset" / "raw.jsonl";
    rawf.parent.mkdir(parents=True, exist_ok=True);
    f: any = open(str(rawf), "a", encoding="utf-8");
    for r in rows {
        f.write(json.dumps(r) + "\n");
    }
    f.close();
    _STATE["writing"] = False;
}

def _sum_vals(d: dict[str, any]) -> int {
    tot = 0;
    for k in d { tot = tot + int(str(d[k])); }
    return tot;
}

"""chars//4 token accounting × the $/Mtok prices passed via env."""
def _calc_cost(in_chars: int, out_chars: int, price_in: float, price_out: float) -> float {
    return (in_chars // 4) / 1000000.0 * price_in + (out_chars // 4) / 1000000.0 * price_out;
}

def _mk_progress(rows_done: int, target: int, batches: int, cost: float) -> dict[str, any] {
    return {
        "rows_done": rows_done, "target": target, "batches": batches,
        "est_cost_usd": cost, "last_batch_at": _now()
    };
}

# -------------------------------------------------------------------- main -----
def main() -> int {
    pdir_s = str(os.environ.get("JMS_PROJECT_DIR", ""));
    if not pdir_s or not os.path.isdir(pdir_s) {
        _log("FATAL: JMS_PROJECT_DIR not set or not a directory");
        return 2;
    }
    pdir = Path(pdir_s);
    jid = str(os.environ.get("JMS_JOB_ID", "job"));
    provider = str(os.environ.get("JMS_PROVIDER", "claude"));
    model = str(os.environ.get("JMS_MODEL", ""));
    target = _env_int("JMS_TARGET_ROWS", 0);
    max_rows = _env_int("JMS_MAX_ROWS", target);
    batch = _env_int("JMS_BATCH", 8);
    if batch < 1 { batch = 8; }
    regen_raw = str(os.environ.get("JMS_REGEN_OF", ""));
    price_in = _env_float("JMS_PRICE_IN", 0.0);
    price_out = _env_float("JMS_PRICE_OUT", 0.0);

    signal(int(SIGTERM), _on_term);

    project: dict[str, any] = {};
    plan: dict[str, any] = {};
    try {
        project = dict(json.loads((pdir / "project.json").read_text()));
        plan = dict(json.loads((pdir / "plan.json").read_text()));
    } except Exception as e {
        _log("FATAL: cannot read project.json/plan.json: " + str(e)[:200]);
        return 2;
    }
    _log(f"[gen] job={jid} provider={provider} model={model} target={target} max={max_rows} batch={batch}");

    # ---- provider setup -------------------------------------------------------
    key = str(os.environ.get("ANTHROPIC_API_KEY", ""));
    if provider == "claude" and not key {
        _log("FATAL: claude provider without ANTHROPIC_API_KEY");
        return 2;
    }
    if provider == "mlx" {
        mpath = str(os.environ.get("JMS_MLX_MODEL_PATH", ""));
        if not mpath or not os.path.isdir(mpath) {
            _log("FATAL: mlx provider without a valid JMS_MLX_MODEL_PATH");
            return 2;
        }
        _log("[mlx] loading model (can take minutes)...");
        try {
            _mlx_load(mpath);
        } except Exception as e {
            _log("FATAL: mlx load failed: " + str(e)[:240]);
            return 2;
        }
    }

    # ---- chunk pass -----------------------------------------------------------
    _ensure_chunks(pdir, project);
    index = _load_index(pdir, project);
    if len(index) == 0 {
        _log("FATAL: no source chunks — is the source path readable?");
        return 2;
    }
    _log(f"[chunk] index ready: {len(index)} chunks across sources");

    mix: list = [];
    mix_in: any = plan.get("mix", []);
    if isinstance(mix_in, list) {
        for m in mix_in {
            if isinstance(m, dict) { mix.append(dict(m)); }
        }
    }
    if not mix {
        mix = [{"type_name": "example", "description": "a representative training example", "share_pct": 100}];
    }
    by_name: dict[str, any] = {};
    for m2 in mix {
        if isinstance(m2, dict) { by_name[str(m2.get("type_name", "example"))] = m2; }
    }
    plan_sys = str(plan.get("system_prompt", ""));
    notes = str(plan.get("grounding_notes", ""));
    sys_p = plan_sys;
    if notes { sys_p = sys_p + "\n\nGrounding notes: " + notes; }

    # ---- regen mode: same-type replacement counts -----------------------------
    regen_ids = [s for s in regen_raw.split(",") if s.strip()];
    remaining: dict[str, any] = {};
    if regen_ids {
        rawf = pdir / "dataset" / "raw.jsonl";
        idset: dict[str, any] = {};
        for s in regen_ids { idset[s.strip()] = True; }
        if rawf.exists() {
            for ln in rawf.read_text().splitlines() {
                if not ln.strip() { continue; }
                row: dict[str, any] = {};
                try { row = dict(json.loads(ln)); } except Exception { continue; }
                rid = str(row.get("_id", ""));
                if rid in idset {
                    t = str(row.get("_type", "example"));
                    remaining[t] = int(str(remaining.get(t, 0))) + 1;
                }
            }
        }
        target = _sum_vals(remaining);
        max_rows = target;
        _log(f"[regen] replacing {target} rows across {len(remaining)} types");
        if target == 0 {
            _log("[regen] no matching rows — nothing to do");
            return 0;
        }
    }

    # ---- batch loop -----------------------------------------------------------
    credits: dict[str, any] = {};
    dir_use: dict[str, any] = {};
    chunk_use: dict[str, any] = {};
    rows_done = 0;
    batches = 0;
    skip_streak = 0;
    api_err_streak = 0;
    in_chars = 0;
    out_chars = 0;
    batch_budget = 4 * ((max_rows + batch - 1) // batch) + 4;

    _write_progress(pdir, jid, _mk_progress(0, target, 0, 0.0));

    while rows_done < target and rows_done < max_rows {
        if bool(_STATE["stop"]) { return 143; }
        if batches >= batch_budget {
            _log(f"FATAL: batch budget exhausted ({batches} batches, {rows_done} rows) — model output mostly invalid");
            return 1;
        }
        n = min(batch, target - rows_done, max_rows - rows_done);
        mixent: dict[str, any] = {};
        if regen_ids {
            # most-remaining type first
            best_t = "";
            best_n = 0;
            for t in remaining {
                if int(str(remaining[t])) > best_n {
                    best_n = int(str(remaining[t]));
                    best_t = t;
                }
            }
            if best_n == 0 { break; }
            n = min(batch, best_n);
            mixent = dict(by_name.get(best_t, {"type_name": best_t, "description": "", "share_pct": 100}));
        } else {
            mixent = _pick_type(mix, credits);
        }
        type_name = str(mixent.get("type_name", "example"));
        type_desc = str(mixent.get("description", ""));

        chunks = _sample_chunks(index, dir_use, chunk_use, _CHUNKS_PER_BATCH);
        parts: list[str] = [];
        refs: list[str] = [];
        for c in chunks {
            if not isinstance(c, dict) { continue; }
            txt = _chunk_text(c);
            if not txt.strip() { continue; }
            ref = str(c.get("path", "")) + ":" + str(c.get("start_line", 0)) + "-" + str(c.get("end_line", 0));
            refs.append(ref);
            parts.append("### " + ref + "\n" + txt);
        }
        if not parts {
            skip_streak = skip_streak + 1;
            batches = batches + 1;
            _log(f"[batch {batches}] no readable chunk text — skipped");
            if skip_streak >= 4 {
                _log("FATAL: 4 consecutive unusable batches");
                return 1;
            }
            continue;
        }
        excerpts = "\n\n".join(parts);
        user = _build_user(type_name, type_desc, n, excerpts);
        max_out = n * 600 + 400;
        if max_out > 8000 { max_out = 8000; }

        raw_txt = "";
        failed = False;
        try {
            if provider == "claude" {
                raw_txt = _claude_generate(model, key, sys_p, user, max_out);
                api_err_streak = 0;
            } else {
                raw_txt = _mlx_generate(sys_p, user, max_out);
            }
        } except Exception as e {
            failed = True;
            if provider == "claude" {
                api_err_streak = api_err_streak + 1;
                _log(f"[batch {batches + 1}] api error: {str(e)[:220]}");
                if api_err_streak >= 2 {
                    _log("FATAL: " + str(e)[:260]);
                    return 1;
                }
                time.sleep(2);
            } else {
                skip_streak = skip_streak + 1;
                _log(f"[batch {batches + 1}] mlx generate error: {str(e)[:220]}");
                if skip_streak >= 4 {
                    _log("FATAL: 4 consecutive failed batches");
                    return 1;
                }
            }
        }
        if failed {
            batches = batches + 1;
            continue;
        }
        in_chars = in_chars + len(sys_p) + len(user);
        out_chars = out_chars + len(raw_txt);

        parsed = _extract_rows(raw_txt);
        if parsed is None and provider == "mlx" {
            # one nudge retry, then skip the batch
            _log(f"[batch {batches + 1}] JSON parse miss — retrying with nudge");
            try {
                raw2 = _mlx_generate(sys_p, user + "\n\nYour previous reply was not a valid JSON array. Output ONLY the JSON array.", max_out);
                in_chars = in_chars + len(sys_p) + len(user);
                out_chars = out_chars + len(raw2);
                parsed = _extract_rows(raw2);
            } except Exception as e2 {
                _log(f"[batch {batches + 1}] retry error: {str(e2)[:180]}");
            }
        }
        batches = batches + 1;
        if parsed is None {
            skip_streak = skip_streak + 1;
            _log(f"[batch {batches}] no valid JSON array — batch skipped");
            if skip_streak >= 4 {
                _log("FATAL: 4 consecutive unparseable batches");
                return 1;
            }
            _write_progress(pdir, jid, _mk_progress(rows_done, target, batches, _calc_cost(in_chars, out_chars, price_in, price_out)));
            continue;
        }

        cap = max_rows - rows_done;
        if regen_ids {
            t = str(mixent.get("type_name", "example"));
            cap = min(cap, int(str(remaining.get(t, 0))));
        }
        accepted: list = [];
        for r in parsed {
            if len(accepted) >= cap { break; }
            if not isinstance(r, dict) { continue; }
            rd = dict(r);
            if not _valid_row(rd) { continue; }
            accepted.append({
                "_id": uuid4().hex[:8],
                "_type": type_name,
                "_meta": {"chunks": refs, "job": jid},
                "messages": list(rd["messages"])
            });
        }
        if accepted {
            _append_rows(pdir, accepted);
            rows_done = rows_done + len(accepted);
            if regen_ids {
                t = str(mixent.get("type_name", "example"));
                remaining[t] = int(str(remaining.get(t, 0))) - len(accepted);
            }
            skip_streak = 0;
        } else {
            skip_streak = skip_streak + 1;
            if skip_streak >= 4 {
                _log("FATAL: 4 consecutive batches with zero valid rows");
                return 1;
            }
        }
        cost_now = _calc_cost(in_chars, out_chars, price_in, price_out);
        _write_progress(pdir, jid, _mk_progress(rows_done, target, batches, cost_now));
        _log(f"[batch {batches}] type={type_name} asked={n} got={len(accepted)} rows_done={rows_done}/{target} cost=${cost_now}");
        if bool(_STATE["stop"]) {
            _log("[stop] SIGTERM after batch write — exiting");
            return 143;
        }
    }

    cost_end = _calc_cost(in_chars, out_chars, price_in, price_out);
    _write_progress(pdir, jid, _mk_progress(rows_done, target, batches, cost_end));
    _log(f"[gen] done: {rows_done} rows in {batches} batches, est cost ${cost_end}");
    return 0;
}

with entry {
    sys.exit(main());
}
