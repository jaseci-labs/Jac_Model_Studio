"""studio - JMS EVAL stage: score a trained adapter on its project's holdout.

The scoring ENGINE: `start_eval` spawns `scripts/jms_eval_worker.jac` as a
detached `jac run` subprocess (jobs.spawn_detached + with_exit_marker — the
jms_gen.sv.jac pattern) that, for every row of the project's materialized
dataset/holdout.jsonl, generates a completion from the run's base model + LoRA
adapter (its OWN mlx_lm copy — the server took the heavy GPU lock for it) and
scores generated-vs-reference. Two metrics:

  judge       Claude LLM-as-judge, 10 rows/call via the Anthropic REST API, a
              1-5 score + rationale per row grounded in the prompt. Needs a
              resolved Anthropic key; start_eval auto-falls-back to `similarity`
              (with a note) when no key is configured.
  similarity  difflib.SequenceMatcher(generated, reference).ratio() mapped to
              1-5 (round(ratio*4)+1) — offline, no key.

State lives under <project>/evals/<eid>/ (job.json / run.log the jobs engine
owns, plus the worker's outputs.jsonl / scores.jsonl / summary.json) — the FILES
are the restart-surviving source of truth. The JmsEvalRun node (defined in
jms_projects.sv.jac, same one-way-import precedent as JmsTrainRun) is the graph
index; eval_status syncs n/mean_score/pass_rate/finished on terminal transitions.

Only `local-mlx` completed runs (adapter on disk) are evaluable — a spheron run's
base_model is a free-text HF id with no local weights to load here.

Checker notes (jaclang 0.16.1): dict values are `any` → int(str(...)) /
float(str(...)); `++>` returns a list → unwrap [0]; live_status can return None.
"""

import json;
import os;
import shlex;
import shutil;
import sys;
import time;
import difflib;
import datetime;
import jobs;
import metrics;
import models;
import paths;
import jms_llm;
import from pathlib { Path }
import from uuid { uuid4 }
import from jms_projects {
    JmsProject, JmsTrainRun, JmsEvalRun,
    _find_project, _train_runs_of, _eval_runs_of, _adapter_on_disk, jms_project_dir
}

glob JUDGE_MODEL: str = "claude-sonnet-5";   # LLM-as-judge model (Anthropic)
glob PASS_SCORE: int = 4;                    # score >= this counts toward pass_rate

def _now() -> str {
    return datetime.datetime.now(datetime.UTC).replace(tzinfo=None).isoformat() + "Z";
}

# --------------------------------------------------------------- pure scoring --
"""difflib.SequenceMatcher(generated, reference).ratio() mapped to a 1-5 integer
score: round(ratio*4)+1 (ratio 0 → 1, 0.5 → 3, 1.0 → 5), clamped to [1,5]. Pure +
deterministic so jms_eval.test.jac covers the mapping; scripts/jms_eval_worker.jac
duplicates this minimally (as `_sim_score`) — workers can't import server modules,
keep the two in sync."""
def similarity_score(generated: str, reference: str) -> int {
    ratio = float(difflib.SequenceMatcher(None, generated, reference).ratio());
    s = int(round(ratio * 4.0)) + 1;
    if s < 1 { s = 1; }
    if s > 5 { s = 5; }
    return s;
}

"""Summary over a list of 1-5 scores: {n, mean_score, pass_rate} where pass_rate
is the share with score >= *pass_score*. Empty list → all zeros. Pure (tested);
the worker computes the same shape inline into summary.json — keep in sync."""
def summarize(scores: list[int], pass_score: int = 4) -> dict {
    n = len(scores);
    if n == 0 { return {"n": 0, "mean_score": 0.0, "pass_rate": 0.0}; }
    total = 0;
    passed = 0;
    for s in scores {
        total = total + s;
        if s >= pass_score { passed = passed + 1; }
    }
    return {
        "n": n,
        "mean_score": float(total) / float(n),
        "pass_rate": float(passed) / float(n)
    };
}

# ------------------------------------------------------------- file helpers ----
def _eval_dir(p: JmsProject, eid: str) -> Path {
    return jms_project_dir(p.slug) / "evals" / eid;
}

def _job_file(p: JmsProject, eid: str) -> Path {
    return _eval_dir(p, eid) / "job.json";
}

def _run_log(p: JmsProject, eid: str) -> Path {
    return _eval_dir(p, eid) / "run.log";
}

def _holdout_file(p: JmsProject) -> Path {
    return jms_project_dir(p.slug) / "dataset" / "holdout.jsonl";
}

def _summary(p: JmsProject, eid: str) -> dict {
    sf = _eval_dir(p, eid) / "summary.json";
    if not sf.exists() { return {}; }
    try { return dict(json.loads(sf.read_text())); } except Exception { return {}; }
}

def _count_lines(pth: Path) -> int {
    if not pth.exists() { return 0; }
    try {
        return len([ln for ln in pth.read_text().splitlines() if ln.strip()]);
    } except Exception {
        return 0;
    }
}

# ----------------------------------------------------------------- finders ----
def _find_eval(p: JmsProject, eid: str) -> JmsEvalRun | None {
    for e in _eval_runs_of(p) {
        if e.eid == eid { return e; }
    }
    return None;
}

def _find_run(p: JmsProject, rid: str) -> JmsTrainRun | None {
    for r in _train_runs_of(p) {
        if r.rid == rid { return r; }
    }
    return None;
}

"""Where a non-local run's adapter actually lives: the node's synced adapter_path
if cloudruns already pulled it, else the pointer jms_train wrote at start
(<project>/runs/<rid>/remote.json), else "". Read-only."""
def _remote_adapter_path(p: JmsProject, r: JmsTrainRun) -> str {
    if r.adapter_path { return str(r.adapter_path); }
    ptr = jms_project_dir(p.slug) / "runs" / r.rid / "remote.json";
    if not ptr.exists() { return ""; }
    try {
        return str(dict(json.loads(ptr.read_text())).get("adapter_path", ""));
    } except Exception {
        return "";
    }
}

"""The evaluable run for *rid*: local-mlx, adapter on disk, not still training,
with a resolvable local base model. Returns {ok, base_path, adapter_path,
base_model, error}."""
def _resolve_run(p: JmsProject, rid: str) -> dict {
    r = _find_run(p, rid);
    if r is None { return {"ok": False, "error": "unknown run: " + rid}; }
    if r.backend != "local-mlx" {
        # ponytail: spheron runs are REJECTED, not evaluated — but with the two
        # concrete reasons and the adapter's real path, instead of a bare
        # "only local-mlx". Actually scoring one needs a PEFT→mlx adapter
        # conversion + the base weights pulled locally (see the report).
        adir = _remote_adapter_path(p, r);
        where = ("its adapter is at " + adir) if adir else "its adapter has not been pulled off the VM yet";
        why = "the adapter is HuggingFace PEFT format and this box's scorer loads mlx-format adapters only";
        bm = models.model_by_id(r.base_model);
        if not bm or not models.model_available(bm) {
            why = why + ", and its base model " + str(r.base_model) + " has no local weights here";
        }
        return {"ok": False, "error": "spheron runs cannot be evaluated yet — " + where + " (" + why + ")"};
    }
    if r.status == "running" {
        return {"ok": False, "error": "run is still training"};
    }
    if not r.adapter_path or not _adapter_on_disk(r.adapter_path) {
        return {"ok": False, "error": "run has no adapter on disk yet"};
    }
    m = models.model_by_id(r.base_model);
    if not m or not models.model_available(m) {
        return {"ok": False, "error": "base model not available locally: " + r.base_model};
    }
    return {
        "ok": True, "error": "",
        "base_path": str(models.model_path(m)),
        "adapter_path": str(r.adapter_path),
        "base_model": str(r.base_model)
    };
}

# --------------------------------------------------------------- jac binary ----
"""The studio server's own jac executable for spawning the worker (the venv
running this process), falling back to PATH. Mirrors jms_gen._jac_bin."""
def _jac_bin() -> str {
    cand = Path(sys.executable).parent / "jac";
    if cand.exists() { return str(cand); }
    w = shutil.which("jac");
    return str(w) if w else "";
}

# ------------------------------------------------------------- live resolve ----
"""Last FATAL line from the run-log tail, else a generic message."""
def _last_error(rl: Path) -> str {
    tail = metrics.tail(rl, 60);
    err = "";
    for ln in tail.split("\n") {
        if ln.strip().startswith("FATAL") { err = ln.strip(); }
    }
    if err { return err[:300]; }
    return "worker exited with an error — see the run log";
}

def _map_status(s: str) -> str {
    return "completed" if s == "done" else s;
}

"""Resolve the effective metric: `judge` with no resolvable Anthropic key
auto-falls-back to `similarity` and carries a note; everything else passes
through unchanged. Split out (pure but for the key read) so jms_eval.test.jac can
assert the fallback without spawning a worker. Returns {metric, note}."""
def _effective_metric(metric: str) -> dict {
    if metric == "judge" and not jms_llm.resolved_anthropic_key() {
        return {"metric": "similarity", "note": "no Anthropic key configured — fell back to the offline similarity metric"};
    }
    return {"metric": metric, "note": ""};
}

"""Resolve *e*'s live state from job.json/run.log/summary.json and sync the node
on a terminal transition (fills n/mean_score/pass_rate, releases the heavy lock).
Returns the eval dict WITHOUT the log tail (eval_status adds it)."""
def _resolve(p: JmsProject, e: JmsEvalRun) -> dict {
    jf = _job_file(p, e.eid);
    rl = _run_log(p, e.eid);
    live = jobs.live_status(jf, rl);
    status = e.status;
    if live is not None { status = _map_status(str(live.get("status", e.status))); }
    summ = _summary(p, e.eid);
    n = e.n;
    mean = e.mean_score;
    prate = e.pass_rate;
    if summ {
        n = int(str(summ.get("n", n)));
        mean = float(str(summ.get("mean_score", mean)));
        prate = float(str(summ.get("pass_rate", prate)));
    }
    if e.status == "running" and status != "running" {
        e.status = status;
        e.n = n;
        e.mean_score = mean;
        e.pass_rate = prate;
        e.finished = _now();
        if status == "failed" { e.error = _last_error(rl); }
        jobs.heavy_release("jmseval:" + e.eid);
    }
    return {
        "eid": e.eid, "run_rid": e.run_rid, "metric": e.metric, "status": status,
        "n": n, "mean_score": mean, "pass_rate": prate,
        "started": e.started, "finished": e.finished, "error": e.error
    };
}

# --------------------------------------------------------------- endpoints ----
"""Score a completed local-mlx run's adapter on the project's holdout. Guards:
holdout.jsonl exists non-empty, metric ∈ {judge, similarity}, the run is
evaluable (local-mlx + adapter on disk + resolvable base). `judge` needs a
resolved Anthropic key — with none, it AUTO-FALLS-BACK to `similarity` and
returns a `note`. `limit=0` scores every holdout row. Grabs the global heavy GPU
lock (the worker loads its own mlx copy), then spawns the detached worker.
Returns {ok, eid, run, note, error}."""
def start_eval(pid: str, rid: str, metric: str = "judge", limit: int = 0) -> dict {
    p = _find_project(pid);
    if p is None { return {"ok": False, "eid": "", "error": "unknown project"}; }
    if metric not in ["judge", "similarity"] {
        return {"ok": False, "eid": "", "error": "metric must be judge or similarity"};
    }
    if _count_lines(_holdout_file(p)) == 0 {
        return {"ok": False, "eid": "", "error": "no holdout rows — materialize a holdout split first (CURATE stage)"};
    }
    rr = _resolve_run(p, rid);
    if not bool(rr["ok"]) {
        return {"ok": False, "eid": "", "error": str(rr["error"])};
    }

    eff = _effective_metric(metric);
    metric = str(eff["metric"]);
    note = str(eff["note"]);
    key = "";
    if metric == "judge" { key = jms_llm.resolved_anthropic_key(); }
    lim = limit;
    if lim < 0 { lim = 0; }

    jac = _jac_bin();
    if not jac { return {"ok": False, "eid": "", "error": "jac binary not found for the worker"}; }

    eid = uuid4().hex[:12];
    ed = _eval_dir(p, eid);
    ed.mkdir(parents=True, exist_ok=True);
    jf = _job_file(p, eid);
    rl = _run_log(p, eid);

    # One heavy local job at a time (shared GPU) — the worker loads its own mlx copy.
    grab = jobs.heavy_acquire("jmseval:" + eid, jf, rl);
    if not grab["ok"] {
        return {"ok": False, "eid": "", "error": "GPU busy: " + str(grab["busy_with"]) + " is running"};
    }

    env: dict = {
        "JMS_EVAL_DIR": str(ed),
        "JMS_MODEL_PATH": str(rr["base_path"]),
        "JMS_ADAPTER_PATH": str(rr["adapter_path"]),
        "JMS_HOLDOUT": str(_holdout_file(p)),
        "JMS_METRIC": metric,
        "JMS_LIMIT": str(lim),
        "JMS_JUDGE_MODEL": JUDGE_MODEL,
        "JMS_PASS_SCORE": str(PASS_SCORE)
    };
    if metric == "judge" { env["ANTHROPIC_API_KEY"] = key; }

    rl.write_text("");   # erase any stale __EXIT__ marker
    inner = f"{shlex.quote(jac)} run scripts/jms_eval_worker.jac";
    cmd = jobs.with_exit_marker(inner, rl);
    child = 0;
    try {
        child = jobs.spawn_detached(cmd, rl, env, paths.studio_root());
    } except Exception as ex {
        jobs.heavy_release("jmseval:" + eid);
        return {"ok": False, "eid": "", "error": "spawn failed: " + str(ex)[:200]};
    }
    jobs.write_job(jf, {
        "name": f"eval-{eid}", "mode": "jms_eval", "pid": child,
        "status": "running", "started": time.strftime("%Y-%m-%d %H:%M:%S"),
        "cmd": inner
    });
    p ++> JmsEvalRun(
        eid=eid, run_rid=rid, metric=metric, status="running", started=_now()
    );
    return {"ok": True, "eid": eid, "run": eval_status(pid, eid), "note": note, "error": ""};
}

"""Live status of one eval: node/summary fields + a 40-line log tail. Resolves
from job.json/run.log/summary.json so it survives server restarts; syncs the node
on terminal transitions."""
def eval_status(pid: str, eid: str) -> dict {
    p = _find_project(pid);
    if p is None { return {"error": "unknown project"}; }
    e = _find_eval(p, eid);
    if e is None { return {"error": "unknown eval: " + eid}; }
    out = _resolve(p, e);
    out["log_tail"] = metrics.tail(_run_log(p, eid), 40);
    return out;
}

"""A page of merged rows from outputs.jsonl + scores.jsonl, sliced
[offset:offset+cap] (cap 100). Each row: {idx, prompt_messages, prompt_excerpt,
reference, generated, score, rationale}. `total` is the outputs row count."""
def eval_rows(pid: str, eid: str, offset: int = 0, limit: int = 20) -> dict {
    p = _find_project(pid);
    if p is None { return {"rows": [], "total": 0}; }
    e = _find_eval(p, eid);
    if e is None { return {"rows": [], "total": 0}; }
    ed = _eval_dir(p, eid);
    outputs: list[dict] = [];
    of = ed / "outputs.jsonl";
    if of.exists() {
        for ln in of.read_text().splitlines() {
            if not ln.strip() { continue; }
            try { outputs.append(dict(json.loads(ln))); } except Exception {}
        }
    }
    scores: dict = {};
    sf = ed / "scores.jsonl";
    if sf.exists() {
        for ln in sf.read_text().splitlines() {
            if not ln.strip() { continue; }
            try {
                sd = dict(json.loads(ln));
                scores[str(sd.get("idx", ""))] = sd;
            } except Exception {}
        }
    }
    total = len(outputs);
    cap = max(1, min(limit, 100));
    rows: list[dict] = [];
    i = max(0, offset);
    while i < total and i < offset + cap {
        o = outputs[i];
        idx = str(o.get("idx", i));
        pm: any = o.get("prompt_messages", []);
        pm_list: list = list(pm) if isinstance(pm, list) else [];
        excerpt = "";
        for msg in pm_list {
            if isinstance(msg, dict) {
                excerpt = str(dict(msg).get("content", ""));
            }
        }
        sc = dict(scores.get(idx, {})) if idx in scores else {};
        rows.append({
            "idx": idx,
            "prompt_messages": pm_list,
            "prompt_excerpt": excerpt[:400],
            "reference": str(o.get("reference", "")),
            "generated": str(o.get("generated", "")),
            "score": int(str(sc.get("score", 0))) if sc else 0,
            "rationale": str(sc.get("rationale", "")) if sc else ""
        });
        i = i + 1;
    }
    return {"rows": rows, "total": total};
}

"""SIGTERM a running eval job's process group (jobs.stop) + release the heavy
lock. Returns the fresh status."""
def stop_eval_run(pid: str, eid: str) -> dict {
    p = _find_project(pid);
    if p is None { return {"error": "unknown project"}; }
    e = _find_eval(p, eid);
    if e is None { return {"error": "unknown eval: " + eid}; }
    jobs.stop(_job_file(p, eid), _run_log(p, eid));
    jobs.heavy_release("jmseval:" + eid);
    return eval_status(pid, eid);
}

"""All of a project's evals, newest first, live-resolved (no log tails). Named
`list_jms_evals` (not `list_evals`) to avoid colliding with evals.sv.jac's
top-level `list_evals` at endpoint registration."""
def list_jms_evals(pid: str) -> list[dict] {
    p = _find_project(pid);
    if p is None { return []; }
    out: list[dict] = [];
    for e in _eval_runs_of(p) { out.append(_resolve(p, e)); }
    out.sort(key=lambda d: dict -> str { return str(d["started"]); }, reverse=True);
    return out;
}
