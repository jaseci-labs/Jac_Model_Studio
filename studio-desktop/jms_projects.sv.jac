"""studio - JMS project management + source scanning (OSP graph, per-user).

The JMS product surface (frontend → JmsShell → JmsProject) is backed by a small
graph: `root ++> JmsProject ++> JmsSource`. Projects hang off the caller's OWN
root, so every read (`[root -->][?:JmsProject]`) is multi-tenant isolated for
free — same guarantee persistence.sv.jac / evals.sv.jac rely on.

A project owns an on-disk skeleton under <workspace_root>/jms-projects/<slug>/
(dataset/ sources/ jobs/ runs/ evals/); the slug is the filesystem identity and
is immutable after creation (name is display-only, unrenamable). Sources are
fast os.walk stat passes — no file contents read — producing file counts + a
bytes//4 token estimate + an extension histogram, capped at 50k files.

`write_project_snapshot` dumps project.json into the project dir for the later
generate/train workers to consume.

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
        source_count: int = 0;
}

# ------------------------------------------------------------------- nodes -----
node JmsProject {
    has pid: str = "",
        name: str = "",
        slug: str = "",
        use_case: str = "",
        created: str = "",
        provider: str = "claude",
        model: str = "claude-sonnet-5";
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

"""True when *project* has at least one approved plan (drives the GENERATE dot)."""
def _has_approved_plan(project: JmsProject) -> bool {
    for g in _gen_plans_of(project) {
        if g.status == "approved" { return True; }
    }
    return False;
}

# ------------------------------------------------------------------- shapes ----
def _project_view(p: JmsProject) -> JmsProjectView {
    return JmsProjectView(
        pid=p.pid, name=p.name, slug=p.slug, use_case=p.use_case,
        created=p.created, provider=p.provider, model=p.model,
        source_count=len(_sources_of(p))
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
(dataset/ sources/ jobs/ runs/ evals/). Name is display-only and cannot be
renamed later (the slug would drift from the directory)."""
def create_project(name: str, use_case: str) -> JmsProjectView {
    base = _slugify(name);
    if not jobs.safe(base) { base = "project"; }
    slug = _unique_slug(base);
    d = jms_project_dir(slug);
    for sub in ["dataset", "sources", "jobs", "runs", "evals"] {
        (d / sub).mkdir(parents=True, exist_ok=True);
    }
    p = (root ++> JmsProject(
        pid=uuid4().hex[:12], name=name, slug=slug, use_case=use_case,
        created=_now(), provider="claude", model="claude-sonnet-5"
    ))[0];
    write_project_snapshot(p.pid);
    return _project_view(p);
}

"""All of the caller's projects, newest-first."""
def list_projects() -> list[JmsProjectView] {
    out: list[JmsProjectView] = [];
    for p in [root -->][?:JmsProject] {
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
    stage_state: dict = {
        "sources": "done" if scanned >= 1 else "empty",
        "generate": "done" if _has_approved_plan(p) else "empty",
        "curate": "empty",
        "train": "empty",
        "eval": "empty"
    };
    return {
        "pid": p.pid, "name": p.name, "slug": p.slug, "use_case": p.use_case,
        "created": p.created, "provider": p.provider, "model": p.model,
        "sources": srcs,
        "plans": plans, "gen_jobs": [], "train_runs": [], "evals": [],
        "row_stats": row_stats, "stage_state": stage_state
    };
}

"""Patch mutable fields (use_case / provider / model). Name is NOT renamable — the
slug is the filesystem identity. Returns the refreshed view, or a blank view if
the pid is unknown / not the caller's."""
def update_project(pid: str, fields: dict) -> JmsProjectView {
    p = _find_project(pid);
    if p is None { return JmsProjectView(); }
    if "use_case" in fields { p.use_case = str(fields["use_case"]); }
    if "provider" in fields { p.provider = str(fields["provider"]); }
    if "model" in fields { p.model = str(fields["model"]); }
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
