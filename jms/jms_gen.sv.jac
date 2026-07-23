"""studio - JMS GENERATE stage, SYNTHESIZE step: detached dataset-generation jobs.

The generation ENGINE: `start_gen` spawns `scripts/jms_gen_worker.jac` as a
detached `jac run` subprocess (jobs.spawn_detached + with_exit_marker — the
builders.sv.jac pattern) that synthesizes sft-chat training rows grounded in
chunks of the project's real source files, appending to
<project>/dataset/raw.jsonl. The worker is a standalone program with NO
auth/graph context: everything it needs arrives via env vars + two snapshots
written server-side before spawn — project.json (write_project_snapshot) and
plan.json (the approved plan, dumped as a sibling file; chosen over extending
the snapshot so the P3 snapshot shape stays untouched).

Job state lives in <project>/jobs/<jid>/{job.json, run.log, progress.json};
those files are the restart-surviving source of truth. The JmsGenJob node
(defined in jms_projects.sv.jac, same one-way-import precedent as JmsGenPlan)
is the graph index; gen_status syncs its fields on terminal transitions.

Providers: "claude" (worker calls the Anthropic REST API with the caller's
resolved key — passed via env, never persisted) and "mlx" (worker loads its own
mlx_lm copy of a local model — takes the GLOBAL heavy lock, jobs.heavy_acquire,
since this box has one GPU; the claude path deliberately does NOT).

`validate_row` is the pure sft-chat row validator — kept here so tests cover
it; the worker duplicates it minimally (workers can't import server modules).

Checker notes (jaclang 0.16.1): dict values are `any` → int(str(...)) /
float(str(...)); `++>` returns a list → unwrap [0].
"""

import json;
import os;
import shlex;
import shutil;
import sys;
import time;
import datetime;
import jobs;
import metrics;
import models;
import paths;
import jms_llm;
import jms_plan;
import from pathlib { Path }
import from uuid { uuid4 }
import from jms_projects {
    JmsProject, JmsGenJob,
    _find_project, _sources_of, _gen_jobs_of, jms_project_dir, write_project_snapshot
}

def _now() -> str {
    return datetime.datetime.now(datetime.UTC).replace(tzinfo=None).isoformat() + "Z";
}

# --------------------------------------------------------------- estimate -----
glob MAX_ROWS_CAP: int = 5000;        # hard product cap on target_rows
glob _TOK_OVERHEAD: int = 1200;       # system prompt + instruction, per batch
glob _TOK_PER_CHUNK: int = 3000;      # chunker aims for ~2500-3500 est tokens
glob _CHUNKS_PER_BATCH: int = 3;
glob _TOK_PER_ROW_OUT: int = 450;

"""Back-of-envelope cost preview for a generation run. Per-batch input ≈
overhead + 3 grounding chunks; output ≈ rows × ~450 tok. Priced via
jms_llm.price_for ($/Mtok) — mlx/unknown models price at zero. Estimate only."""
def estimate_gen(pid: str, provider: str, model: str, rows: int, batch_size: int = 8) -> dict {
    if batch_size < 1 { batch_size = 8; }
    batches = (rows + batch_size - 1) // batch_size if rows > 0 else 0;
    est_in = batches * (_TOK_OVERHEAD + _CHUNKS_PER_BATCH * _TOK_PER_CHUNK);
    est_out = rows * _TOK_PER_ROW_OUT;
    pr = jms_llm.price_for(model);
    cost = est_in / 1000000.0 * float(str(pr["in"])) + est_out / 1000000.0 * float(str(pr["out"]));
    return {
        "rows": rows, "batches": batches,
        "est_input_tokens": est_in, "est_output_tokens": est_out,
        "est_cost_usd": cost,
        "cap_ok": rows >= 1 and rows <= MAX_ROWS_CAP
    };
}

# ------------------------------------------------------------- row validator ---
"""True iff *row* is a well-formed sft-chat training row: a `messages` list of
≥2 dicts, each with a non-empty content; role `system` allowed only first, the
rest strictly user/assistant with no two consecutive messages sharing a role;
the last message must be an assistant turn.
DUPLICATED (minimally, as _valid_row) in scripts/jms_gen_worker.jac — workers
are standalone `jac run` programs and cannot import server modules. Keep the
two in sync."""
def validate_row(row: dict) -> bool {
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

# ------------------------------------------------------------ job file paths ---
def _jobs_dir(p: JmsProject, jid: str) -> Path {
    return jms_project_dir(p.slug) / "jobs" / jid;
}

def _job_file(p: JmsProject, jid: str) -> Path {
    return _jobs_dir(p, jid) / "job.json";
}

def _run_log(p: JmsProject, jid: str) -> Path {
    return _jobs_dir(p, jid) / "run.log";
}

def _progress_file(p: JmsProject, jid: str) -> Path {
    return _jobs_dir(p, jid) / "progress.json";
}

def _read_progress(p: JmsProject, jid: str) -> dict {
    pf = _progress_file(p, jid);
    if not pf.exists() { return {}; }
    try {
        return dict(json.loads(pf.read_text()));
    } except Exception {
        return {};
    }
}

# ----------------------------------------------------------------- finders ----
def _find_job(p: JmsProject, jid: str) -> JmsGenJob | None {
    for j in _gen_jobs_of(p) {
        if j.jid == jid { return j; }
    }
    return None;
}

def _latest_job(p: JmsProject) -> JmsGenJob | None {
    all_jobs = _gen_jobs_of(p);
    if not all_jobs { return None; }
    best = all_jobs[0];
    for j in all_jobs {
        if j.started > best.started { best = j; }
    }
    return best;
}

# --------------------------------------------------------------- jac binary ----
"""The STUDIO server's own jac executable for spawning the worker — the venv
running this process (sys.executable-adjacent), falling back to PATH. NOT
models.jac_bin(), which is the DATA venv's jac (a different environment)."""
def _jac_bin() -> str {
    cand = Path(sys.executable).parent / "jac";
    if cand.exists() { return str(cand); }
    w = shutil.which("jac");
    return str(w) if w else "";
}

# ------------------------------------------------------------- live resolve ----
"""Last FATAL line from the run log tail, else a generic message."""
def _last_error(rl: Path) -> str {
    tail = metrics.tail(rl, 60);
    err = "";
    for ln in tail.split("\n") {
        if ln.strip().startswith("FATAL") { err = ln.strip(); }
    }
    if err { return err[:300]; }
    return "worker exited with an error — see the run log";
}

"""jobs.live_status "done" → "completed"; everything else passes through."""
def _map_status(s: str) -> str {
    return "completed" if s == "done" else s;
}

"""Resolve *j*'s live state from job.json/run.log/progress.json (builders
pattern) and sync the node on a terminal transition (incl. releasing the heavy
lock for mlx holders — heavy_acquire also self-heals, this is just prompt).
Returns the job dict WITHOUT the log tail (gen_status adds it)."""
def _resolve(p: JmsProject, j: JmsGenJob) -> dict {
    jf = _job_file(p, j.jid);
    rl = _run_log(p, j.jid);
    live = jobs.live_status(jf, rl);
    status = j.status;
    if live is not None { status = _map_status(str(live.get("status", j.status))); }
    prog = _read_progress(p, j.jid);
    rows_done = j.rows_done;
    if "rows_done" in prog { rows_done = int(str(prog["rows_done"])); }
    cost = j.est_cost_usd;
    if "est_cost_usd" in prog { cost = float(str(prog["est_cost_usd"])); }
    batches = int(str(prog.get("batches", 0)));
    if j.status == "running" and status != "running" {
        j.status = status;
        j.rows_done = rows_done;
        j.est_cost_usd = cost;
        j.finished = _now();
        if status == "failed" { j.error = _last_error(rl); }
        if j.provider == "mlx" { jobs.heavy_release("gen:" + j.jid); }
    }
    return {
        "jid": j.jid, "status": status, "provider": j.provider, "model": j.model,
        "target_rows": j.target_rows, "max_rows": j.max_rows,
        "plan_version": j.plan_version, "rows_done": rows_done,
        "batches": batches, "est_cost_usd": cost,
        "last_batch_at": str(prog.get("last_batch_at", "")),
        "started": j.started, "finished": j.finished, "error": j.error
    };
}

# --------------------------------------------------------------- endpoints ----
"""Fire a generation job. Refuses when: no approved plan, no scanned source,
another gen job already running on this project, claude without a resolvable
Anthropic key, mlx without an on-disk model, target over the product cap, or
the GPU (mlx) is busy with another heavy job. Writes project.json + plan.json
snapshots, then spawns the detached worker. `regen_of` (row _ids) switches the
worker to regeneration mode — target/max are ignored beyond that count (wired
now; the curation phase owns the button). Returns {ok, jid, status, error}."""
def start_gen(
    pid: str, provider: str, model: str,
    target_rows: int, max_rows: int, batch_size: int = 8,
    regen_of: list[str] = []
) -> dict {
    p = _find_project(pid);
    if p is None { return {"ok": False, "jid": "", "error": "unknown project"}; }
    if provider not in ["claude", "mlx"] {
        return {"ok": False, "jid": "", "error": "unknown provider: " + provider};
    }
    plan = jms_plan.latest_approved(pid);
    if plan is None {
        return {"ok": False, "jid": "", "error": "no approved plan — approve one in the PLAN tab first"};
    }
    scanned = False;
    for s in _sources_of(p) {
        if s.scanned_at { scanned = True; }
    }
    if not scanned {
        return {"ok": False, "jid": "", "error": "no scanned source — add one in the SOURCES stage first"};
    }
    for other in _gen_jobs_of(p) {
        if other.status == "running" {
            live = jobs.live_status(_job_file(p, other.jid), _run_log(p, other.jid));
            if live is not None and str(live.get("status", "")) == "running" {
                return {"ok": False, "jid": "", "error": "a generation job is already running: " + other.jid};
            }
        }
    }
    regen = [str(r) for r in regen_of if str(r)];
    if not regen {
        if target_rows < 1 { return {"ok": False, "jid": "", "error": "target_rows must be at least 1"}; }
        if target_rows > MAX_ROWS_CAP {
            return {"ok": False, "jid": "", "error": f"target_rows over the {MAX_ROWS_CAP} cap"};
        }
        # max_rows is the HARD cap and may sit below target (the worker stops at
        # min(target, max)); only default it when unset.
        if max_rows < 1 { max_rows = target_rows; }
    }
    if batch_size < 1 or batch_size > 32 { batch_size = 8; }
    key = "";
    mlx_path = "";
    if provider == "claude" {
        key = jms_llm.resolved_anthropic_key();
        if not key {
            return {"ok": False, "jid": "", "error": "no Anthropic key configured — set one in the key modal"};
        }
    } else {
        m = models.model_by_id(model);
        if not m { return {"ok": False, "jid": "", "error": "unknown local model: " + model}; }
        if not models.model_available(m) {
            return {"ok": False, "jid": "", "error": "local model not on disk: " + model};
        }
        mlx_path = str(models.model_path(m));
    }
    jac = _jac_bin();
    if not jac { return {"ok": False, "jid": "", "error": "jac binary not found for the worker"}; }

    jid = uuid4().hex[:12];
    jf = _job_file(p, jid);
    rl = _run_log(p, jid);
    _jobs_dir(p, jid).mkdir(parents=True, exist_ok=True);
    # Snapshots the graph-less worker reads instead of the graph.
    write_project_snapshot(pid);
    (jms_project_dir(p.slug) / "plan.json").write_text(json.dumps(plan, indent=2));
    # One heavy local job at a time (shared GPU) — mlx only; claude is network-bound.
    if provider == "mlx" {
        grab = jobs.heavy_acquire("gen:" + jid, jf, rl);
        if not grab["ok"] {
            return {"ok": False, "jid": "", "error": "GPU busy: " + str(grab["busy_with"]) + " is running"};
        }
    }
    pr = jms_llm.price_for(model);
    env: dict = {
        "JMS_PROJECT_DIR": str(jms_project_dir(p.slug)),
        "JMS_JOB_ID": jid,
        "JMS_PROVIDER": provider,
        "JMS_MODEL": model,
        "JMS_TARGET_ROWS": str(target_rows),
        "JMS_MAX_ROWS": str(max_rows),
        "JMS_BATCH": str(batch_size),
        "JMS_REGEN_OF": ",".join(regen),
        "JMS_PRICE_IN": str(float(str(pr["in"]))),
        "JMS_PRICE_OUT": str(float(str(pr["out"])))
    };
    if provider == "claude" { env["ANTHROPIC_API_KEY"] = key; }
    if provider == "mlx" { env["JMS_MLX_MODEL_PATH"] = mlx_path; }
    rl.write_text("");   # erase any stale __EXIT__ marker
    inner = f"{shlex.quote(jac)} run scripts/jms_gen_worker.jac";
    cmd = jobs.with_exit_marker(inner, rl);
    child = 0;
    try {
        child = jobs.spawn_detached(cmd, rl, env, paths.studio_root());
    } except Exception as e {
        if provider == "mlx" { jobs.heavy_release("gen:" + jid); }
        return {"ok": False, "jid": "", "error": "spawn failed: " + str(e)[:200]};
    }
    jobs.write_job(jf, {
        "name": f"gen-{jid}", "mode": "jms_gen", "pid": child,
        "status": "running", "started": time.strftime("%Y-%m-%d %H:%M:%S"),
        "cmd": inner
    });
    p ++> JmsGenJob(
        jid=jid, status="running", provider=provider, model=model,
        target_rows=target_rows, max_rows=max_rows,
        plan_version=int(str(plan["version"])),
        regen_of_json=json.dumps(regen), started=_now()
    );
    return {"ok": True, "jid": jid, "status": "running", "error": ""};
}

"""Live status of one gen job (jid "" → the latest): job dict + a 40-line log
tail. Resolves from job.json/run.log/progress.json so it survives server
restarts; syncs the node on terminal transitions."""
def gen_status(pid: str, jid: str = "") -> dict {
    p = _find_project(pid);
    if p is None { return {"error": "unknown project"}; }
    j = _find_job(p, jid) if jid else _latest_job(p);
    if j is None { return {"error": "no generation jobs yet"}; }
    out = _resolve(p, j);
    out["log_tail"] = metrics.tail(_run_log(p, j.jid), 40);
    out["error"] = j.error;
    return out;
}

"""SIGTERM a running gen job's process group (jobs.stop). The worker finishes
its in-flight file write and dies; status → stopped. Returns the fresh status."""
def stop_gen(pid: str, jid: str) -> dict {
    p = _find_project(pid);
    if p is None { return {"error": "unknown project"}; }
    j = _find_job(p, jid);
    if j is None { return {"error": "unknown job: " + jid}; }
    jobs.stop(_job_file(p, jid), _run_log(p, jid));
    return gen_status(pid, jid);
}

"""All of a project's gen jobs, newest first, live-resolved (no log tails)."""
def list_gen_jobs(pid: str) -> list[dict] {
    p = _find_project(pid);
    if p is None { return []; }
    out: list[dict] = [];
    for j in _gen_jobs_of(p) { out.append(_resolve(p, j)); }
    out.sort(key=lambda d: dict -> str { return str(d["started"]); }, reverse=True);
    return out;
}
