"""studio - JMS project management + source scanning (OSP graph, per-user).

The JMS product surface (frontend → JmsShell → JmsProject) is backed by a small
graph: `root ++> JmsProject ++> JmsSource`. Projects hang off the caller's OWN
root, so every read (`[root -->][?:JmsProject]`) is multi-tenant isolated for
free — same guarantee persistence.sv.jac / evals.sv.jac rely on.

A project owns an on-disk skeleton under <workspace_root>/jms-projects/<slug>/
(dataset/ sources/ jobs/ runs/ evals/); the slug is the filesystem identity and
is **immutable after creation** — `rename_project` changes the DISPLAY name only
and never touches the directory (see its docstring for why). Sources are
fast os.walk stat passes — no file contents read — producing file counts + a
bytes//4 token estimate + an extension histogram, capped at 50k files.

`write_project_snapshot` dumps project.json into the project dir for the later
generate/train workers to consume.

Lifecycle extras (all additive — every pre-existing signature/return shape is
untouched): `rename_project` (display name), `duplicate_project` (config-only
clone by default, opt-in streamed curated-dataset copy), `dataset_export_info`
(cheap size probe), `export_dataset` (paginated JSONL reader under a hard
per-response byte budget) and `export_summary` (config + counts + results as
JSON or Markdown, capped and self-reporting when it caps).

Checker notes (jaclang 0.16.1): `++>` returns a LIST — unwrap `(root ++> X())[0]`;
dict values are `any`, so `int(str(...))` when coercing; import native symbols
directly. os.walk dir pruning is done via list.clear()+extend (in-place, no slice
assignment). jobs.safe() gates the slug so it is always a shell/path-safe token.
"""

import json;
import os;
import shutil;
import fnmatch;
import datetime;
import jobs;
import paths;
import from pathlib { Path }
import from uuid { uuid4 }

def _now() -> str {
    return datetime.datetime.now(datetime.UTC).replace(tzinfo=None).isoformat() + "Z";
}

# --------------------------------------------------------------- scan config ---
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
glob _MAX_BYTES: int = 1048576;   # 1 MB — skip larger files
glob _MAX_FILES: int = 50000;     # walk cap — bail with a note beyond this

# ------------------------------------------------------------- export budget ---
# HARD per-response ceiling for `export_dataset` / `export_summary`. A curated
# dataset is unbounded (tens of MB is normal), and one endpoint in this repo once
# shipped 48 x 4MB base64 blobs in a single response — so the reader is PAGINATED
# and every response says, in-band, whether it stopped early (`eof` / `truncated`
# / `note`). Nothing is ever silently dropped.
glob _EXPORT_MAX_BYTES: int = 2000000;   # ~2 MB of JSONL text per response
glob _EXPORT_MAX_LINES: int = 2000;      # …or 2k rows, whichever trips first
glob _SUMMARY_MAX_ITEMS: int = 200;      # per-list cap inside export_summary
glob _COPY_CHUNK: int = 1048576;         # 1 MB streaming-copy chunk

# ------------------------------------------------------------------- views -----
"""One project as a card sees it: fields + a derived source count."""
obj JmsProjectView {
    has pid: str = "",
        name: str = "",
        slug: str = "",
        use_case: str = "",
        created: str = "",
        provider: str = "claude",
        model: str = "claude-sonnet-5",
        source_count: int = 0,
        group_id: str = "";
}

# ------------------------------------------------------------------- nodes -----
node JmsProject {
    has pid: str = "",
        name: str = "",
        slug: str = "",
        use_case: str = "",
        created: str = "",
        provider: str = "claude",
        model: str = "claude-sonnet-5",
        group_id: str = "";
}

node JmsSource {
    has sid: str = "",
        kind: str = "code",           # code | docs
        path: str = "",
        include: list[str] = [],
        exclude: list[str] = [],
        files: int = 0,
        est_tokens: int = 0,
        skipped: int = 0,
        ext_json: str = "",           # JSON dict {ext: count} — top-8 histogram
        scanned_at: str = "";
}

"""A GENERATE-stage dataset plan draft/approval, child of a JmsProject
(`project ++> JmsGenPlan`). The plan body itself is opaque JSON in `plan_json`
(shape: description/schema/mix/target_rows/system_prompt/grounding_notes) —
authored + mutated by jms_plan.sv.jac, which imports this type. Kept HERE (not in
jms_plan) so get_project can read plans without a circular import back into
jms_plan (which imports jms_projects). `version` is monotonic per project; at
most one plan is `approved` at a time."""
node JmsGenPlan {
    has version: int = 1,
        status: str = "draft",        # draft | approved
        provider: str = "",           # claude | mlx
        model: str = "",
        plan_json: str = "",
        created: str = "",
        approved_at: str = "";
}

"""A SYNTHESIZE-stage generation job, child of a JmsProject
(`project ++> JmsGenJob`). Mirrors the on-disk job under
<project>/jobs/<jid>/ (job.json / run.log / progress.json) — the FILES are the
live source of truth (they survive server restarts); the node is the graph
index get_project lists from, with rows_done/est_cost_usd/finished synced on
terminal transitions by jms_gen.sv.jac gen_status. Kept HERE (not in jms_gen)
for the same one-way-import reason as JmsGenPlan: get_project reads jobs
without importing jms_gen (which imports jms_projects)."""
node JmsGenJob {
    has jid: str = "",
        status: str = "running",      # running | completed | failed | stopped
        provider: str = "",           # claude | mlx
        model: str = "",
        target_rows: int = 0,
        max_rows: int = 0,
        plan_version: int = 1,
        est_cost_usd: float = 0.0,
        rows_done: int = 0,
        regen_of_json: str = "[]",
        started: str = "",
        finished: str = "",
        error: str = "";
}

"""A TRAIN-stage finetuning run, child of a JmsProject (`project ++> JmsTrainRun`).
Two backends: `local-mlx` (mlx_lm.lora LoRA under runs/<rid>/, jobs-engine
detached, one at a time behind the GLOBAL heavy GPU lock) and `spheron` (a remote
Spheron VM run delegated to cloudruns.sv.jac — the CloudRun node owns the VM
lifecycle; this node just carries `cloud_run_id` to proxy status through). Kept
HERE (not in jms_train) for the same one-way-import reason as JmsGenPlan/JmsGenJob:
get_project reads runs without importing jms_train (which imports jms_projects).
Live status + terminal node sync are jms_train.sv.jac train_status's job; the node
fields are the restart-surviving graph index. `adapter_path` is the local dir
mlx_lm writes / cloudruns pulls the adapter into. `cfg_json` snapshots the opts."""
node JmsTrainRun {
    has rid: str = "",
        backend: str = "local-mlx",   # local-mlx | spheron
        base_model: str = "",
        status: str = "running",      # running | completed | failed | stopped
        cfg_json: str = "",
        adapter_path: str = "",
        cloud_run_id: str = "",
        started: str = "",
        finished: str = "";
}

"""An EVAL-stage scoring run over a project's holdout, child of a JmsProject
(`project ++> JmsEvalRun`). Scores a completed local-mlx train run's adapter on
the materialized dataset/holdout.jsonl via a detached worker
(scripts/jms_eval_worker.jac) — the on-disk evals/<eid>/ dir (outputs.jsonl /
scores.jsonl / summary.json + the jobs-engine job.json/run.log) is the
restart-surviving source of truth; the node is the graph index synced on terminal
transitions by jms_eval.sv.jac eval_status. Kept HERE (not in jms_eval) for the
same one-way-import reason as JmsGenJob/JmsTrainRun: get_project lists evals
without importing jms_eval (which imports jms_projects). `metric` is judge (Claude
LLM-as-judge, 1-5) or similarity (difflib ratio → 1-5); mean_score/pass_rate/n are
filled from summary.json on completion."""
node JmsEvalRun {
    has eid: str = "",
        run_rid: str = "",
        metric: str = "judge",        # judge | similarity
        status: str = "running",      # running | completed | failed | stopped
        n: int = 0,
        mean_score: float = 0.0,
        pass_rate: float = 0.0,
        started: str = "",
        finished: str = "",
        error: str = "";
}

# --------------------------------------------------------------- fs helpers ----
"""<workspace_root>/jms-projects/<slug> — the project's on-disk home."""
def jms_project_dir(slug: str) -> Path {
    return paths.workspace_root() / "jms-projects" / slug;
}

"""Non-blank JSONL line count, 0 on missing/unreadable file."""
def _count_lines(p: Path) -> int {
    if not p.exists() { return 0; }
    try {
        return len([ln for ln in p.read_text().splitlines() if ln.strip()]);
    } except Exception {
        return 0;
    }
}

"""Non-blank line count by ITERATING the handle — never materializes the file in
memory, unlike `_count_lines` above (kept as-is: `get_project`'s row_stats depend
on its exact behavior). Used by the export/duplicate size probes, which are the
paths that can meet a multi-hundred-MB curated dataset."""
def _count_lines_stream(p: Path) -> int {
    if not p.exists() { return 0; }
    n = 0;
    try {
        fh: any = open(str(p), "r", encoding="utf-8", errors="replace");
        try {
            for raw in fh {
                if raw.strip() { n = n + 1; }
            }
        } finally {
            fh.close();
        }
    } except Exception {
        return 0;
    }
    return n;
}

"""Byte size of *p*, 0 when missing/unstattable."""
def _file_size(p: Path) -> int {
    try {
        return int(os.path.getsize(str(p)));
    } except Exception {
        return 0;
    }
}

"""Copy src → dst in 1 MB chunks through a `.tmp` sibling, then `os.replace()`.

Two properties this buys, both required by the brief: the file is NEVER read
whole into memory (an explicit chunk loop, so a 2 GB dataset costs 1 MB of RSS),
and a crash mid-copy leaves the `.tmp` behind rather than a truncated `dst` — the
rename is atomic on POSIX. Returns bytes written, or -1 when src does not exist
(or the copy failed, in which case dst is left exactly as it was)."""
def _copy_stream(src: Path, dst: Path) -> int {
    if not src.exists() { return -1; }
    tmp = Path(str(dst) + ".tmp");
    try {
        fin: any = open(str(src), "rb");
        try {
            fout: any = open(str(tmp), "wb");
            try {
                while True {
                    chunk: any = fin.read(_COPY_CHUNK);
                    if not chunk { break; }
                    fout.write(chunk);
                }
            } finally {
                fout.close();
            }
        } finally {
            fin.close();
        }
        # Size off the closed temp file (stat), not an accumulator — the handle is
        # typed `any` here, so len(chunk) is unusable to the checker.
        n = _file_size(tmp);
        os.replace(str(tmp), str(dst));
        return n;
    } except Exception {
        # Leave nothing half-written behind; dst is untouched either way.
        try { tmp.unlink(); } except Exception {}
        return -1;
    }
}

# ---------------------------------------------------------------- slug logic ---
glob _ALNUM: str = "abcdefghijklmnopqrstuvwxyz0123456789";

"""Lowercase, non-[a-z0-9] → '-', collapse repeats, trim. Guaranteed to be an
ASCII token jobs.safe() accepts (empty → 'project')."""
def _slugify(name: str) -> str {
    out = "";
    for ch in name.lower() {
        out = out + (ch if ch in _ALNUM else "-");
    }
    while "--" in out { out = out.replace("--", "-"); }
    out = out.strip("-");
    if not out { out = "project"; }
    return out;
}

def _slug_taken(slug: str) -> bool {
    for p in [root -->][?:JmsProject] {
        if p.slug == slug { return True; }
    }
    return False;
}

def _unique_slug(base: str) -> str {
    slug = base;
    n = 2;
    while _slug_taken(slug) {
        slug = f"{base}-{n}";
        n = n + 1;
    }
    return slug;
}

# ------------------------------------------------------------------- finders ---
def _find_project(pid: str) -> JmsProject | None {
    for p in [root -->][?:JmsProject] {
        if p.pid == pid { return p; }
    }
    return None;
}

def _find_source(project: JmsProject, sid: str) -> JmsSource | None {
    for s in [project -->][?:JmsSource] {
        if s.sid == sid { return s; }
    }
    return None;
}

def _sources_of(project: JmsProject) -> list[JmsSource] {
    return [s for s in [project -->][?:JmsSource]];
}

# ------------------------------------------------------------- plan readers ---
"""Every JmsGenPlan hanging off *project* (any order)."""
def _gen_plans_of(project: JmsProject) -> list[JmsGenPlan] {
    return [g for g in [project -->][?:JmsGenPlan]];
}

"""Parse one plan node into a client dict: the plan_json body merged with the
node's version/status/provider/model/created/approved_at. Garbage JSON → the
envelope fields only."""
def _plan_dict(g: JmsGenPlan) -> dict {
    parsed: dict = {};
    if g.plan_json {
        try { parsed = dict(json.loads(g.plan_json)); } except Exception { parsed = {}; }
    }
    parsed["version"] = g.version;
    parsed["status"] = g.status;
    parsed["provider"] = g.provider;
    parsed["model"] = g.model;
    parsed["created"] = g.created;
    parsed["approved_at"] = g.approved_at;
    return parsed;
}

"""All of *project*'s plans as dicts, newest (highest version) first."""
def _plans_newest_first(project: JmsProject) -> list[dict] {
    out: list[dict] = [];
    for g in _gen_plans_of(project) { out.append(_plan_dict(g)); }
    out.sort(key=lambda d: dict -> int { return int(str(d["version"])); }, reverse=True);
    return out;
}

"""The single plan worth carrying into a clone: the approved one if there is
one, otherwise the highest-version draft. None when the project has no plans.
# ponytail: one plan, not the whole version history — a clone is a fresh start,
# and the older drafts are only meaningful next to the runs that consumed them
# (which a clone deliberately does not copy). Ceiling: no "clone full history"."""
def _plan_to_clone(project: JmsProject) -> JmsGenPlan | None {
    plans = _gen_plans_of(project);
    if not plans { return None; }
    best = plans[0];
    for g in plans[1:] {
        g_ok = g.status == "approved";
        b_ok = best.status == "approved";
        if g_ok and not b_ok { best = g; }
        elif g_ok == b_ok and g.version > best.version { best = g; }
    }
    return best;
}

"""True when *project* has at least one approved plan (drives the GENERATE dot)."""
def _has_approved_plan(project: JmsProject) -> bool {
    for g in _gen_plans_of(project) {
        if g.status == "approved" { return True; }
    }
    return False;
}

# -------------------------------------------------------- gen-job readers -----
"""Every JmsGenJob hanging off *project* (any order)."""
def _gen_jobs_of(project: JmsProject) -> list[JmsGenJob] {
    return [j for j in [project -->][?:JmsGenJob]];
}

"""One gen job as get_project lists it: node fields + live rows_done read from
the job's progress.json while running. Full live status (log tail, __EXIT__
resolution, terminal sync) is jms_gen.sv.jac gen_status's job."""
def _gen_job_dict(p: JmsProject, j: JmsGenJob) -> dict {
    rows = j.rows_done;
    if j.status == "running" {
        pf = jms_project_dir(p.slug) / "jobs" / j.jid / "progress.json";
        if pf.exists() {
            try {
                prog = dict(json.loads(pf.read_text()));
                rows = int(str(prog.get("rows_done", rows)));
            } except Exception {}
        }
    }
    return {
        "jid": j.jid, "status": j.status, "provider": j.provider, "model": j.model,
        "target_rows": j.target_rows, "max_rows": j.max_rows,
        "plan_version": j.plan_version, "rows_done": rows,
        "est_cost_usd": j.est_cost_usd, "started": j.started,
        "finished": j.finished, "error": j.error
    };
}

# ------------------------------------------------------------ train readers ---
"""Every JmsTrainRun hanging off *project* (any order)."""
def _train_runs_of(project: JmsProject) -> list[JmsTrainRun] {
    return [r for r in [project -->][?:JmsTrainRun]];
}

"""True iff *adir* (an adapter dir) holds at least one *.safetensors file — the
"a real adapter landed on disk" test both backends share (mlx_lm writes
adapters.safetensors; cloudruns pulls adapter_model.safetensors)."""
def _adapter_on_disk(adir: str) -> bool {
    if not adir { return False; }
    d = Path(adir);
    if not d.is_dir() { return False; }
    for f in d.glob("*.safetensors") { return True; }
    return False;
}

"""One train run as get_project lists it: node fields + a live-ish `adapter_ready`
disk check. Full live status (job/cloud resolution + terminal node sync) is
jms_train.sv.jac train_status's job."""
def _train_run_dict(r: JmsTrainRun) -> dict {
    return {
        "rid": r.rid, "backend": r.backend, "base_model": r.base_model,
        "status": r.status, "adapter_path": r.adapter_path,
        "adapter_ready": _adapter_on_disk(r.adapter_path),
        "cloud_run_id": r.cloud_run_id,
        "started": r.started, "finished": r.finished
    };
}

"""A run counts as "done" for the stage dot when it completed AND its adapter is
on disk (a completed-but-unpulled spheron run stays in-progress)."""
def _has_done_train(project: JmsProject) -> bool {
    for r in _train_runs_of(project) {
        if r.status == "completed" and _adapter_on_disk(r.adapter_path) { return True; }
    }
    return False;
}

"""True iff a train run on *project* is still marked running (node-level; the dot
only needs the coarse signal, train_status does the live resolution)."""
def _any_running_train(project: JmsProject) -> bool {
    for r in _train_runs_of(project) {
        if r.status == "running" { return True; }
    }
    return False;
}

# ------------------------------------------------------------- eval readers ---
"""Every JmsEvalRun hanging off *project* (any order)."""
def _eval_runs_of(project: JmsProject) -> list[JmsEvalRun] {
    return [e for e in [project -->][?:JmsEvalRun]];
}

"""One eval run as get_project lists it: the node fields (rounded floats
client-side). Full live status (job resolution + summary.json read + terminal
node sync) is jms_eval.sv.jac eval_status's job."""
def _eval_run_dict(e: JmsEvalRun) -> dict {
    return {
        "eid": e.eid, "run_rid": e.run_rid, "metric": e.metric,
        "status": e.status, "n": e.n, "mean_score": e.mean_score,
        "pass_rate": e.pass_rate, "started": e.started,
        "finished": e.finished, "error": e.error
    };
}

# ------------------------------------------------------------------- shapes ----
def _project_view(p: JmsProject) -> JmsProjectView {
    return JmsProjectView(
        pid=p.pid, name=p.name, slug=p.slug, use_case=p.use_case,
        created=p.created, provider=p.provider, model=p.model,
        source_count=len(_sources_of(p)), group_id=p.group_id
    );
}

def _source_dict(s: JmsSource) -> dict {
    hist: dict = {};
    if s.ext_json {
        try { hist = dict(json.loads(s.ext_json)); } except Exception { hist = {}; }
    }
    # Pre-rendered "· .py 12 · .js 8" line so the client never has to iterate a
    # dict that crossed the RPC boundary (JS object, no stable key iteration).
    parts: list[str] = [];
    for k in hist {
        parts.append(f"{k} {int(str(hist[k]))}");
    }
    return {
        "sid": s.sid, "kind": s.kind, "path": s.path,
        "include": list(s.include), "exclude": list(s.exclude),
        "files": s.files, "est_tokens": s.est_tokens, "skipped": s.skipped,
        "ext_histogram": hist, "ext_line": " · ".join(parts), "scanned_at": s.scanned_at
    };
}

# -------------------------------------------------------------- the scanner ----
"""Decide whether *fname* (ext already lowered) is an included source file.
User *include* globs (fnmatch on the basename) override the kind default when
non-empty; user *exclude* globs always subtract."""
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

"""Fast stat-only walk of *path*: prunes default junk dirs, applies include/
exclude, skips >1MB + binary files, caps at 50k walked files. Returns
{files, est_tokens, skipped, ext_histogram (top 8), bailed}."""
def _scan_walk(path: str, kind: str, inc: list[str], exc: list[str]) -> dict {
    files = 0;
    est_tokens = 0;
    skipped = 0;
    walked = 0;
    bailed = False;
    hist: dict = {};
    for (dp, dns, fns) in os.walk(path) {
        keep = [d for d in dns if d not in _EX_DIRS];
        dns.clear();
        dns.extend(keep);
        for fn in fns {
            walked = walked + 1;
            if walked > _MAX_FILES {
                bailed = True;
                break;
            }
            ext = os.path.splitext(fn)[1].lower();
            if not _included(fn, ext, kind, inc, exc) {
                skipped = skipped + 1;
                continue;
            }
            full = os.path.join(dp, fn);
            size = 0;
            try {
                size = int(os.path.getsize(full));
            } except Exception {
                skipped = skipped + 1;
                continue;
            }
            if size > _MAX_BYTES {
                skipped = skipped + 1;
                continue;
            }
            files = files + 1;
            est_tokens = est_tokens + (size // 4);
            hist[ext] = int(str(hist.get(ext, 0))) + 1;
        }
        if bailed { break; }
    }
    # top-8 extensions by count
    pairs = sorted(hist.items(), key=lambda kv: any -> int { return int(str(kv[1])); }, reverse=True);
    top: dict = {};
    for kv in pairs[:8] {
        top[str(kv[0])] = int(str(kv[1]));
    }
    return {"files": files, "est_tokens": est_tokens, "skipped": skipped, "ext_histogram": top, "bailed": bailed};
}

# ---------------------------------------------------------------- endpoints ----
"""Create a project. Slug = slugified name (immutable fs identity), de-duplicated
on collision, and gated through jobs.safe(). Lays down the on-disk skeleton
(dataset/ sources/ jobs/ runs/ evals/). Name is display-only; `rename_project`
can change it later but the slug (and therefore the directory) never moves.
`group_id` optionally places the project in a JMS workspace ("" = ungrouped,
back-compat)."""
def create_project(name: str, use_case: str, group_id: str = "") -> JmsProjectView {
    base = _slugify(name);
    if not jobs.safe(base) { base = "project"; }
    slug = _unique_slug(base);
    d = jms_project_dir(slug);
    for sub in ["dataset", "sources", "jobs", "runs", "evals"] {
        (d / sub).mkdir(parents=True, exist_ok=True);
    }
    p = (root ++> JmsProject(
        pid=uuid4().hex[:12], name=name, slug=slug, use_case=use_case,
        created=_now(), provider="claude", model="claude-sonnet-5", group_id=group_id
    ))[0];
    write_project_snapshot(p.pid);
    return _project_view(p);
}

"""All of the caller's projects, newest-first. `group_id` != "" filters to
projects in that workspace; "" (default) returns every project, ungrouped or
not — unchanged back-compat behavior."""
def list_projects(group_id: str = "") -> list[JmsProjectView] {
    out: list[JmsProjectView] = [];
    for p in [root -->][?:JmsProject] {
        if group_id != "" and p.group_id != group_id { continue; }
        out.append(_project_view(p));
    }
    out.sort(key=lambda v: JmsProjectView -> str { return v.created; }, reverse=True);
    return out;
}

"""Full project detail: fields + sources + downstream-stage placeholders (filled
by later phases) + dataset row_stats + a per-stage state map. None → {}."""
def get_project(pid: str) -> dict {
    p = _find_project(pid);
    if p is None { return {}; }
    srcs: list[dict] = [];
    scanned = 0;
    for s in _sources_of(p) {
        srcs.append(_source_dict(s));
        if s.scanned_at { scanned = scanned + 1; }
    }
    dsdir = jms_project_dir(p.slug) / "dataset";
    row_stats: dict = {
        "raw": _count_lines(dsdir / "raw.jsonl"),
        "curated": _count_lines(dsdir / "train.jsonl")
    };
    plans = _plans_newest_first(p);
    gjobs: list[dict] = [];
    for j in _gen_jobs_of(p) { gjobs.append(_gen_job_dict(p, j)); }
    gjobs.sort(key=lambda d: dict -> str { return str(d["started"]); }, reverse=True);
    truns: list[dict] = [];
    for r in _train_runs_of(p) { truns.append(_train_run_dict(r)); }
    truns.sort(key=lambda d: dict -> str { return str(d["started"]); }, reverse=True);
    evals: list[dict] = [];
    for e in _eval_runs_of(p) { evals.append(_eval_run_dict(e)); }
    evals.sort(key=lambda d: dict -> str { return str(d["started"]); }, reverse=True);
    train_state = "empty";
    if _has_done_train(p) { train_state = "done"; }
    elif _any_running_train(p) { train_state = "in-progress"; }
    # Derived off the eval dicts already built above (no second graph scan): a
    # completed scoring run → done; one still scoring → in-progress; else empty.
    eval_state = "empty";
    for ed in evals {
        est = str(ed["status"]);
        if est == "completed" { eval_state = "done"; break; }
        if est == "running" { eval_state = "in-progress"; }
    }
    stage_state: dict = {
        "sources": "done" if scanned >= 1 else "empty",
        "generate": "done" if _has_approved_plan(p) else "empty",
        # train.jsonl materialized (non-empty) → curation done; raw rows exist but
        # no split yet → in-progress; nothing generated → empty.
        "curate": ("done" if int(str(row_stats["curated"])) > 0
                   else ("in-progress" if int(str(row_stats["raw"])) > 0 else "empty")),
        # a completed run with its adapter on disk → done; a run still going →
        # in-progress; otherwise empty.
        "train": train_state,
        # a completed eval run → done; one still scoring → in-progress; else empty.
        "eval": eval_state
    };
    return {
        "pid": p.pid, "name": p.name, "slug": p.slug, "use_case": p.use_case,
        "created": p.created, "provider": p.provider, "model": p.model,
        "sources": srcs,
        "plans": plans, "gen_jobs": gjobs, "train_runs": truns, "evals": evals,
        "row_stats": row_stats, "stage_state": stage_state
    };
}

"""Patch mutable fields (use_case / provider / model / group_id). `name` is
deliberately ignored here — renaming goes through `rename_project`, so an
existing caller that happens to pass a stale `name` key can never surprise-rename
a project. Returns the refreshed view, or a blank view if the pid is unknown /
not the caller's."""
def update_project(pid: str, fields: dict) -> JmsProjectView {
    p = _find_project(pid);
    if p is None { return JmsProjectView(); }
    if "use_case" in fields { p.use_case = str(fields["use_case"]); }
    if "provider" in fields { p.provider = str(fields["provider"]); }
    if "model" in fields { p.model = str(fields["model"]); }
    if "group_id" in fields { p.group_id = str(fields["group_id"]); }
    write_project_snapshot(p.pid);
    return _project_view(p);
}

"""Change a project's DISPLAY name. The slug — and therefore
`jms_project_dir(slug)` — is deliberately left alone.

Why no re-slug (the decision, spelled out): the slug is not a label, it is a
*resolved filesystem identity* that other records already point at by absolute
path. `JmsTrainRun.adapter_path` stores an absolute `.../jms-projects/<slug>/runs/
<rid>/...`; `jobs/<jid>/job.json` + `run.log`, `evals/<eid>/summary.json` and
`dataset/*.jsonl` are all addressed under the same prefix; and detached worker
processes (jms_gen / jms_train / jms_eval, plus the remote supervisor) hold those
paths OPEN for the life of a run. Moving the directory would (a) invalidate every
stored adapter_path with no back-reference to repair, and (b) yank the directory
out from under a live writer — the exact "corrupt a running job" failure the brief
forbids. A rename is a cosmetic act; it must not be able to destroy an artifact.
So: name changes, slug never does, and no directory is ever moved by ANY endpoint
in this module (the only fs removal remains delete_project's opt-in purge).

Blank/whitespace-only names are rejected (a nameless card is unusable); the name
is capped at 120 chars. Re-writes project.json so the on-disk snapshot the
generate/train workers read stays in sync. Blank view if the pid is unknown."""
def rename_project(pid: str, name: str) -> JmsProjectView {
    p = _find_project(pid);
    if p is None { return JmsProjectView(); }
    nm = name.strip();
    if not nm { return _project_view(p); }
    p.name = nm[:120];
    write_project_snapshot(p.pid);
    return _project_view(p);
}

"""Delete a project (+ its sources) from the graph. purge_files=True also removes
the on-disk project dir. False if unknown / not the caller's."""
def delete_project(pid: str, purge_files: bool = False) -> bool {
    p = _find_project(pid);
    if p is None { return False; }
    slug = p.slug;
    for s in _sources_of(p) { del s; }
    for g in _gen_plans_of(p) { del g; }
    for j in _gen_jobs_of(p) { del j; }
    for r in _train_runs_of(p) { del r; }
    for e in _eval_runs_of(p) { del e; }
    del p;
    if purge_files {
        shutil.rmtree(str(jms_project_dir(slug)), ignore_errors=True);
    }
    return True;
}

"""Attach a source dir to a project and scan it inline. Validates: absolute path,
existing directory, kind ∈ {code, docs}. Returns the scanned source dict, or
{"error": ...} on a validation failure."""
def add_source(pid: str, kind: str, path: str, `include: list[str] = [], `exclude: list[str] = []) -> dict {
    p = _find_project(pid);
    if p is None { return {"error": "unknown project"}; }
    if kind not in ["code", "docs"] { return {"error": "kind must be code or docs"}; }
    if not os.path.isabs(path) { return {"error": "path must be absolute"}; }
    if not os.path.isdir(path) { return {"error": "not a directory"}; }
    s = (p ++> JmsSource(
        sid=uuid4().hex[:12], kind=kind, path=path,
        include=list(`include), exclude=list(`exclude)
    ))[0];
    res = _apply_scan(s);
    write_project_snapshot(p.pid);
    return res;
}

"""Detach a source from a project. False if unknown."""
def remove_source(pid: str, sid: str) -> bool {
    p = _find_project(pid);
    if p is None { return False; }
    s = _find_source(p, sid);
    if s is None { return False; }
    del s;
    write_project_snapshot(p.pid);
    return True;
}

"""Re-run the stat walk for a source and persist the counts. Returns the source
dict (with a `bailed` flag when the 50k cap was hit), or {"error": ...}."""
def scan_source(pid: str, sid: str) -> dict {
    p = _find_project(pid);
    if p is None { return {"error": "unknown project"}; }
    s = _find_source(p, sid);
    if s is None { return {"error": "unknown source"}; }
    res = _apply_scan(s);
    write_project_snapshot(p.pid);
    return res;
}

"""Run _scan_walk on *s*, persist files/est_tokens/skipped/histogram/scanned_at
onto the node, and return the source dict + a bailed note."""
def _apply_scan(s: JmsSource) -> dict {
    r = _scan_walk(s.path, s.kind, list(s.include), list(s.exclude));
    s.files = int(str(r["files"]));
    s.est_tokens = int(str(r["est_tokens"]));
    s.skipped = int(str(r["skipped"]));
    s.ext_json = json.dumps(r["ext_histogram"]);
    s.scanned_at = _now();
    out = _source_dict(s);
    out["bailed"] = bool(r["bailed"]);
    return out;
}

"""Dump project.json (pid, slug, name, use_case, provider, model + every source's
kind/path/globs) into the project dir for the generate/train workers. Returns the
written path, or "" if the pid is unknown."""
def write_project_snapshot(pid: str) -> str {
    p = _find_project(pid);
    if p is None { return ""; }
    srcs: list[dict] = [];
    for s in _sources_of(p) {
        srcs.append({
            "sid": s.sid, "kind": s.kind, "path": s.path,
            "include": list(s.include), "exclude": list(s.exclude),
            "files": s.files, "est_tokens": s.est_tokens, "scanned_at": s.scanned_at
        });
    }
    snap: dict = {
        "pid": p.pid, "slug": p.slug, "name": p.name, "use_case": p.use_case,
        "provider": p.provider, "model": p.model, "sources": srcs,
        "written_at": _now()
    };
    d = jms_project_dir(p.slug);
    d.mkdir(parents=True, exist_ok=True);
    out = d / "project.json";
    out.write_text(json.dumps(snap, indent=2));
    return str(out);
}

# ------------------------------------------------------ duplicate / clone -----
"""Clone a project's CONFIG into a brand-new project. Nothing is moved, nothing
is overwritten, the source project is not touched at all.

What is cloned: use_case, provider, model, group_id, every JmsSource (path +
include/exclude globs + the last scan's counts, so the clone opens with SOURCES
already green instead of forcing a re-walk) and ONE JmsGenPlan (the approved one
if there is one, else the newest draft — see `_plan_to_clone`).

What is deliberately NOT cloned: raw.jsonl, curated rows, gen jobs, train runs +
their adapters, and eval runs. Those are gigabyte-scale, single-copy and
run-specific; a duplicate is "start again from the same recipe", not "double my
disk usage". `copy_curated=True` opts INTO copying just `dataset/train.jsonl` +
`dataset/holdout.jsonl`, streamed 1 MB at a time through a `.tmp` + `os.replace`
(`_copy_stream`) — never a read-whole-file — and the response reports the exact
bytes written so the UI can show what it cost. Adapters are never copyable here.

A fresh slug is minted from the new name (de-duplicated, jobs.safe()-gated) and a
fresh dir skeleton is laid down. {"error": ...} on an unknown pid."""
def duplicate_project(pid: str, name: str = "", copy_curated: bool = False) -> dict {
    src = _find_project(pid);
    if src is None { return {"error": "unknown project"}; }
    newname = name.strip() if name.strip() else (src.name + " copy");
    newname = newname[:120];
    base = _slugify(newname);
    if not jobs.safe(base) { base = "project"; }
    slug = _unique_slug(base);
    d = jms_project_dir(slug);
    for sub in ["dataset", "sources", "jobs", "runs", "evals"] {
        (d / sub).mkdir(parents=True, exist_ok=True);
    }
    p = (root ++> JmsProject(
        pid=uuid4().hex[:12], name=newname, slug=slug, use_case=src.use_case,
        created=_now(), provider=src.provider, model=src.model, group_id=src.group_id
    ))[0];
    # `++>` yields a LIST — every new node below unwraps with [0] for the same
    # reason (this repo has crashed on the un-unwrapped form four times).
    new_sids: list[str] = [];
    for s in _sources_of(src) {
        ns = (p ++> JmsSource(
            sid=uuid4().hex[:12], kind=s.kind, path=s.path,
            include=list(s.include), exclude=list(s.exclude),
            files=s.files, est_tokens=s.est_tokens, skipped=s.skipped,
            ext_json=s.ext_json, scanned_at=s.scanned_at
        ))[0];
        new_sids.append(ns.sid);
    }
    plan_copied = False;
    g = _plan_to_clone(src);
    if g is not None {
        ng = (p ++> JmsGenPlan(
            version=1, status=g.status, provider=g.provider, model=g.model,
            plan_json=g.plan_json, created=_now(),
            approved_at=(_now() if g.status == "approved" else "")
        ))[0];
        plan_copied = ng.version > 0;
    }
    copied: list[dict] = [];
    copied_bytes = 0;
    note = "";
    if copy_curated {
        sdir = jms_project_dir(src.slug) / "dataset";
        for fn in ["train.jsonl", "holdout.jsonl"] {
            n = _copy_stream(sdir / fn, d / "dataset" / fn);
            if n >= 0 {
                copied.append({"file": fn, "bytes": n});
                copied_bytes = copied_bytes + n;
            }
        }
        if not copied {
            note = "nothing copied — the source project has no materialized dataset yet";
        }
    }
    write_project_snapshot(p.pid);
    return {
        "pid": p.pid, "name": p.name, "slug": p.slug, "use_case": p.use_case,
        "created": p.created, "provider": p.provider, "model": p.model,
        "group_id": p.group_id, "source_count": len(new_sids),
        "from_pid": src.pid, "from_slug": src.slug,
        "plan_copied": plan_copied, "copied_curated": copy_curated,
        "copied_files": copied, "copied_bytes": copied_bytes, "note": note
    };
}

# ------------------------------------------------------------------ export ----
"""Cheap size probe for the curated dataset — what the DUPLICATE and EXPORT
controls quote BEFORE the user commits to anything. Sizes come from stat();
line counts iterate the handle (`_count_lines_stream`) rather than slurping.
Also echoes the export budget so the client never has to hardcode it.
{"error": ...} on an unknown pid."""
def dataset_export_info(pid: str) -> dict {
    p = _find_project(pid);
    if p is None { return {"error": "unknown project"}; }
    dsdir = jms_project_dir(p.slug) / "dataset";
    tr = dsdir / "train.jsonl";
    ho = dsdir / "holdout.jsonl";
    tb = _file_size(tr);
    hb = _file_size(ho);
    return {
        "pid": p.pid, "slug": p.slug,
        "train": {"exists": tr.exists(), "lines": _count_lines_stream(tr), "bytes": tb},
        "holdout": {"exists": ho.exists(), "lines": _count_lines_stream(ho), "bytes": hb},
        "total_bytes": tb + hb,
        "max_response_bytes": _EXPORT_MAX_BYTES,
        "max_response_lines": _EXPORT_MAX_LINES
    };
}

"""One PAGE of a curated JSONL file, for a client-side Blob download.

Hard response budget: at most `_EXPORT_MAX_LINES` rows or `_EXPORT_MAX_BYTES`
(~2 MB) of text, whichever trips first. The page ALWAYS says whether it stopped
early — `eof` False + `truncated` True + a human `note` + `next_offset` to
resume from. The caller loops until `eof`, so an arbitrarily large dataset is
still fully exportable; it just arrives in bounded chunks instead of one
48-blobs-in-a-response fireball.

The budget check is skipped for the FIRST row of a page, so a single row larger
than the whole budget still ships (`oversize_row` flags it) — without that the
loop could never advance past it. Blank lines are skipped. `offset` is a PHYSICAL
line offset (feed back `next_offset` verbatim; do not compute it yourself).
{"error": ...} for an unknown pid, a bad `which`, or a not-yet-materialized
file."""
def export_dataset(pid: str, which: str = "train", offset: int = 0) -> dict {
    p = _find_project(pid);
    if p is None { return {"error": "unknown project"}; }
    if which not in ["train", "holdout"] { return {"error": "which must be train or holdout"}; }
    f = jms_project_dir(p.slug) / "dataset" / (which + ".jsonl");
    if not f.exists() { return {"error": which + ".jsonl has not been materialized yet"}; }
    lines: list[str] = [];
    nbytes = 0;
    idx = 0;
    eof = True;
    try {
        fh: any = open(str(f), "r", encoding="utf-8", errors="replace");
        try {
            for raw in fh {
                if idx < offset { idx = idx + 1; continue; }
                ln = str(raw).rstrip("\r\n");
                if not ln.strip() { idx = idx + 1; continue; }
                if lines and (len(lines) >= _EXPORT_MAX_LINES
                              or nbytes + len(ln) + 1 > _EXPORT_MAX_BYTES) {
                    eof = False;
                    break;
                }
                lines.append(ln);
                nbytes = nbytes + len(ln) + 1;
                idx = idx + 1;
            }
        } finally {
            fh.close();
        }
    } except Exception as e {
        return {"error": "could not read " + which + ".jsonl: " + str(e)};
    }
    return {
        "which": which, "offset": offset, "next_offset": idx, "eof": eof,
        "lines": lines, "count": len(lines), "bytes": nbytes,
        "truncated": not eof,
        "oversize_row": len(lines) == 1 and nbytes > _EXPORT_MAX_BYTES,
        "max_response_bytes": _EXPORT_MAX_BYTES,
        "max_response_lines": _EXPORT_MAX_LINES,
        "filename": p.slug + "-" + which + ".jsonl",
        "note": "" if eof else "capped at the response budget — call again with offset=next_offset"
    };
}

"""Trim *items* to _SUMMARY_MAX_ITEMS, appending an explicit line to *notes* when
it actually trims. Capping is fine; capping SILENTLY is not."""
def _capped(items: list, label: str, notes: list[str]) -> list {
    if len(items) <= _SUMMARY_MAX_ITEMS { return items; }
    notes.append(
        label + ": newest " + str(_SUMMARY_MAX_ITEMS) + " of " + str(len(items)) + " shown (capped)"
    );
    return items[:_SUMMARY_MAX_ITEMS];
}

"""Render the summary dict as Markdown (tables for the run lists)."""
def _summary_md(s: dict) -> str {
    pr = dict(s["project"]);
    cn = dict(s["counts"]);
    ss = dict(s["stage_state"]);
    L: list[str] = [];
    L.append("# " + str(pr["name"]));
    L.append("");
    L.append("_" + str(pr["use_case"] or "no use case set") + "_");
    L.append("");
    L.append("| field | value |");
    L.append("| --- | --- |");
    for k in ["pid", "slug", "created", "provider", "model"] {
        L.append("| " + k + " | `" + str(pr[k]) + "` |");
    }
    L.append("| exported_at | `" + str(s["exported_at"]) + "` |");
    L.append("");
    L.append("## Pipeline");
    L.append("");
    L.append("| stage | state |");
    L.append("| --- | --- |");
    for k in ["sources", "generate", "curate", "train", "eval"] {
        L.append("| " + k + " | " + str(ss[k]) + " |");
    }
    L.append("");
    L.append("## Counts");
    L.append("");
    L.append("| what | n |");
    L.append("| --- | --- |");
    for k in ["sources", "raw_rows", "curated_rows", "plans", "gen_jobs", "train_runs", "evals"] {
        L.append("| " + k + " | " + str(cn[k]) + " |");
    }
    L.append("");
    L.append("## Sources");
    L.append("");
    srcs = list(s["sources"]);
    if not srcs { L.append("_none attached_"); }
    else {
        L.append("| kind | path | files | est. tokens |");
        L.append("| --- | --- | --- | --- |");
        for it in srcs {
            r = dict(it);
            L.append("| " + str(r["kind"]) + " | `" + str(r["path"]) + "` | "
                     + str(r["files"]) + " | " + str(r["est_tokens"]) + " |");
        }
    }
    L.append("");
    L.append("## Train runs");
    L.append("");
    truns = list(s["train_runs"]);
    if not truns { L.append("_none_"); }
    else {
        L.append("| rid | backend | base model | status | adapter | started |");
        L.append("| --- | --- | --- | --- | --- | --- |");
        for it in truns {
            r = dict(it);
            L.append("| `" + str(r["rid"]) + "` | " + str(r["backend"]) + " | `"
                     + str(r["base_model"]) + "` | " + str(r["status"]) + " | "
                     + ("yes" if r["adapter_ready"] else "no") + " | "
                     + str(r["started"])[:19] + " |");
        }
    }
    L.append("");
    L.append("## Evals");
    L.append("");
    evs = list(s["evals"]);
    if not evs { L.append("_none_"); }
    else {
        L.append("| eid | run | metric | status | n | mean | pass rate |");
        L.append("| --- | --- | --- | --- | --- | --- | --- |");
        for it in evs {
            r = dict(it);
            ms = float(str(r["mean_score"]));
            pr2 = float(str(r["pass_rate"]));
            L.append("| `" + str(r["eid"]) + "` | `" + str(r["run_rid"]) + "` | "
                     + str(r["metric"]) + " | " + str(r["status"]) + " | "
                     + str(r["n"]) + " | " + f"{ms:.3f}" + " | " + f"{pr2:.3f}" + " |");
        }
    }
    notes = list(s["notes"]);
    if notes {
        L.append("");
        L.append("## Export notes");
        L.append("");
        for n in notes { L.append("- " + str(n)); }
    }
    L.append("");
    return "\n".join(L);
}

"""A project's config + counts + run/eval results as ONE downloadable document.

`fmt` is "json" or "md". Returns {filename, mime, content, bytes, truncated,
notes} — the client blobs `content` straight to a download; nothing is
base64'd and no artifact bytes are inlined.

Size budget, three layers, all self-reporting: each run list is capped at
`_SUMMARY_MAX_ITEMS` (200) with a note naming the true total; the plan body (the
only unbounded field, since a plan carries a schema + system prompt) is included
only for the newest plan and is DROPPED entirely if the render still exceeds
`_EXPORT_MAX_BYTES`; and a final hard slice guarantees the response can never
exceed the budget, flagged by `truncated`. For the dataset ROWS themselves use
`export_dataset` — this endpoint never inlines them."""
def export_summary(pid: str, fmt: str = "json") -> dict {
    p = _find_project(pid);
    if p is None { return {"error": "unknown project"}; }
    if fmt not in ["json", "md"] { return {"error": "fmt must be json or md"}; }
    d = get_project(pid);
    notes: list[str] = [];
    srcs = list(d["sources"]);
    plans = list(d["plans"]);
    gjobs = list(d["gen_jobs"]);
    truns = list(d["train_runs"]);
    evals = list(d["evals"]);
    rs = dict(d["row_stats"]);
    if len(plans) > 1 {
        notes.append("plans: only the newest of " + str(len(plans)) + " is included in full");
    }
    summary: dict = {
        "project": {
            "pid": d["pid"], "name": d["name"], "slug": d["slug"],
            "use_case": d["use_case"], "created": d["created"],
            "provider": d["provider"], "model": d["model"]
        },
        "counts": {
            "sources": len(srcs), "raw_rows": rs["raw"], "curated_rows": rs["curated"],
            "plans": len(plans), "gen_jobs": len(gjobs),
            "train_runs": len(truns), "evals": len(evals)
        },
        "stage_state": d["stage_state"],
        "sources": _capped(srcs, "sources", notes),
        "plan": (plans[0] if plans else None),
        "gen_jobs": _capped(gjobs, "gen_jobs", notes),
        "train_runs": _capped(truns, "train_runs", notes),
        "evals": _capped(evals, "evals", notes),
        "exported_at": _now(),
        "notes": notes
    };
    content = json.dumps(summary, indent=2) if fmt == "json" else _summary_md(summary);
    if len(content) > _EXPORT_MAX_BYTES {
        # The plan body is the only field that can realistically blow the budget.
        notes.append("plan body omitted — the rendered summary exceeded the "
                     + str(_EXPORT_MAX_BYTES) + "-byte response budget");
        summary["plan"] = None;
        summary["notes"] = notes;
        content = json.dumps(summary, indent=2) if fmt == "json" else _summary_md(summary);
    }
    truncated = False;
    if len(content) > _EXPORT_MAX_BYTES {
        content = content[:_EXPORT_MAX_BYTES];
        truncated = True;
        notes.append("HARD-TRUNCATED at " + str(_EXPORT_MAX_BYTES) + " bytes — this document is incomplete");
    }
    return {
        "filename": str(d["slug"]) + "-summary." + ("json" if fmt == "json" else "md"),
        "mime": "application/json" if fmt == "json" else "text/markdown",
        "content": content, "bytes": len(content),
        "truncated": truncated, "notes": notes,
        "max_response_bytes": _EXPORT_MAX_BYTES
    };
}
