"""studio - JMS GENERATE stage, PLAN step: propose + edit + approve a dataset plan.

A dataset PLAN is the blueprint the later SYNTHESIZE step turns into rows: a
prose description, an example-type MIX (type_name / description / share_pct), a
target row count, a system prompt, and grounding notes. It is authored by an LLM
grounded in the project's use_case + a sample of its source files, then hand-
editable and approvable.

Two provider paths:
  • "claude" — byllm structured output. A per-call `Model` is built from the
    caller's resolved Anthropic key (jms_llm) and the chosen model, wired into
    `propose_plan ... by _plan_llm()`. The `by` clause evaluates `_plan_llm()`
    at call time, so `_PLAN_CFG` (a module glob mutated in place — no `global`
    needed, same trick as inference.sv `_S`) carries the runtime key/model in.
    Because that glob is process-wide, the write AND the propose_plan call are
    held under `_PLAN_LOCK` (inference.sv `_S["lock"]` pattern) so two tenants
    drafting at once cannot swap keys mid-call.
  • "mlx" — the resident local model (inference.stream_chat), prompted to reply
    ONLY JSON matching the schema, json-parsed with one retry on a parse miss.

Plans persist as `JmsGenPlan` nodes (defined in jms_projects.sv.jac so
get_project can read them WITHOUT importing this module — this module imports
jms_projects, a one-way edge that avoids the circular import that broke a mutual
`import` at runtime). version = max(existing)+1; at most one plan is approved.

Checker notes (jaclang 0.16.1): dict values are `any` → coerce with str()/helpers
before int()/float(); a docstring inside a `by llm` def is W0060 → describe the
LLM-visible surface with `sem`, not docstrings.
"""

import json;
import os;
import threading;
import datetime;
import inference;
import models;
import jms_llm;
import from byllm.lib { Model }
import from jms_projects {
    JmsProject, JmsSource, JmsGenPlan,
    _find_project, _sources_of, _gen_plans_of, _plan_dict, _plans_newest_first,
    _included, _EX_DIRS
}

def _now() -> str {
    return datetime.datetime.now(datetime.UTC).replace(tzinfo=None).isoformat() + "Z";
}

# ---------------------------------------------------------- grounding limits ---
glob _MAX_SAMPLE_FILES: int = 15;
glob _PER_FILE_CHARS: int = 2000;
glob _MAX_GROUND_CHARS: int = 30000;
glob _MAX_WALK: int = 20000;
glob _MAX_BYTES: int = 1048576;

# ================================================================= byllm ======
"""One example type in a dataset MIX."""
obj ExampleType {
    has type_name: str = "",
        description: str = "",
        share_pct: int = 0;
}

"""A synthetic-dataset plan for finetuning."""
obj DatasetPlan {
    has description: str = "",
        mix: list[ExampleType] = [],
        target_rows: int = 0,
        system_prompt: str = "",
        grounding_notes: str = "";
}

sem ExampleType = "One category of training example in the dataset, with a rough share of the total.";
sem ExampleType.type_name = "A short snake_case name for this example category, e.g. 'api_usage' or 'error_fix'.";
sem ExampleType.description = "One sentence: what the model learns from this category and what such an example looks like.";
sem ExampleType.share_pct = "This category's rough share of the dataset as an integer percent (the mix should sum to about 100).";

sem DatasetPlan = "A concrete plan for a supervised finetuning dataset (chat schema) tailored to the use case and grounded in the provided source samples.";
sem DatasetPlan.description = "A 2-4 sentence overview of the dataset: what capability it teaches and the overall strategy.";
sem DatasetPlan.mix = "3-6 complementary example categories that together cover the use case. Their share_pct values should roughly sum to 100.";
sem DatasetPlan.target_rows = "A sensible total number of training rows to synthesize (typically 200-2000 depending on scope).";
sem DatasetPlan.system_prompt = "The system prompt that every synthesized training example should be built around, phrased for the target model.";
sem DatasetPlan.grounding_notes = "Concrete notes tying the plan to the source samples: key APIs, patterns, idioms, or file kinds the examples should reflect.";

"""Runtime wiring for the per-call plan Model. Mutated IN PLACE by _draft_claude
before propose_plan runs; read back by _plan_llm() from inside the `by` clause.

MODULE-LEVEL and therefore SHARED BY EVERY REQUEST THREAD: the write and the
`by`-clause call that reads it back MUST both happen under _PLAN_LOCK, or two
concurrent drafts interleave and user A's Anthropic key/model is used for (and
billed to) user B's call. The key is also zeroed on the way out so it does not
sit in module state between requests."""
glob _PLAN_CFG: dict[str, str] = {"model_name": "", "api_key": ""};

"""Guards _PLAN_CFG for the whole write→propose_plan→return window."""
glob _PLAN_LOCK: any = threading.Lock();

"""Build the Model the `by` clause delegates to — dynamic model_name + api_key
from _PLAN_CFG. Anthropic models are LiteLLM-routed via the 'anthropic/' prefix
(set by the caller)."""
def _plan_llm() -> Model {
    return Model(
        model_name=str(_PLAN_CFG["model_name"]),
        api_key=str(_PLAN_CFG["api_key"]),
        call_params={"temperature": 0.3, "max_tokens": 1500}
    );
}

def propose_plan(use_case: str, source_samples: str) -> DatasetPlan by _plan_llm();

sem propose_plan = "Design a supervised-finetuning dataset PLAN for the given use case, grounded in the provided source samples. Choose an example-type mix, a target row count, a system prompt, and grounding notes that reflect the actual code/docs shown.";
sem propose_plan.use_case = "What the finetuned model should become good at (the project's stated goal).";
sem propose_plan.source_samples = "Representative snippets from the project's own source files — ground the plan in these real APIs, idioms, and patterns.";

# ============================================================= grounding ======
"""First *n* chars of a text file, decoding errors replaced. "" on any failure."""
def _read_head(path: str, n: int) -> str {
    try {
        f: any = open(path, "r", encoding="utf-8", errors="replace");
        txt = f.read(n);
        f.close();
        return str(txt);
    } except Exception {
        return "";
    }
}

"""Absolute paths of the included, in-size source files under *s*, honoring the
same include/exclude/prune rules as the scanner. Capped at _MAX_WALK walked."""
def _source_files(s: JmsSource) -> list[str] {
    out: list[str] = [];
    inc = list(s.include);
    exc = list(s.exclude);
    walked = 0;
    for (dp, dns, fns) in os.walk(s.path) {
        keep = [d for d in dns if d not in _EX_DIRS];
        dns.clear();
        dns.extend(keep);
        for fn in fns {
            walked = walked + 1;
            if walked > _MAX_WALK { return out; }
            ext = os.path.splitext(fn)[1].lower();
            if not _included(fn, ext, s.kind, inc, exc) { continue; }
            full = os.path.join(dp, fn);
            try {
                if int(os.path.getsize(full)) > _MAX_BYTES { continue; }
            } except Exception { continue; }
            out.append(full);
        }
    }
    return out;
}

"""Evenly-spaced pick of up to *n* items (whole list when it already fits)."""
def _even_pick(items: list[str], n: int) -> list[str] {
    total = len(items);
    if total <= n { return items; }
    out: list[str] = [];
    step = total / n;
    i = 0;
    while len(out) < n {
        idx = int(i * step);
        if idx >= total { idx = total - 1; }
        out.append(items[idx]);
        i = i + 1;
    }
    return out;
}

"""Assemble the grounding text: evenly-spaced sample files across every source,
first ~_PER_FILE_CHARS chars each, total ≤ _MAX_GROUND_CHARS. Each block is
prefixed with the file's path so the model sees structure."""
def _collect_grounding(p: JmsProject) -> str {
    files: list[str] = [];
    for s in _sources_of(p) {
        for fp in _source_files(s) { files.append(fp); }
    }
    picked = _even_pick(files, _MAX_SAMPLE_FILES);
    parts: list[str] = [];
    total = 0;
    for fp in picked {
        head = _read_head(fp, _PER_FILE_CHARS);
        if not head.strip() { continue; }
        block = "### " + fp + "\n" + head + "\n";
        if total + len(block) > _MAX_GROUND_CHARS { break; }
        parts.append(block);
        total = total + len(block);
    }
    return "\n".join(parts);
}

# ========================================================= shape coercion =====
"""Best-effort int from an any-typed JSON value (handles 50, "50", 50.0, "50%")."""
def _to_int(v: any) -> int {
    try {
        s = str(v).strip().rstrip("%");
        return int(float(s));
    } except Exception {
        return 0;
    }
}

"""DatasetPlan obj → the canonical plan_json dict."""
def _dp_to_dict(dp: DatasetPlan) -> dict {
    mix: list[dict] = [];
    for e in dp.mix {
        mix.append({
            "type_name": str(e.type_name),
            "description": str(e.description),
            "share_pct": int(e.share_pct)
        });
    }
    return {
        "description": str(dp.description),
        "schema": "sft-chat",
        "mix": mix,
        "target_rows": int(dp.target_rows),
        "system_prompt": str(dp.system_prompt),
        "grounding_notes": str(dp.grounding_notes)
    };
}

"""Coerce an arbitrary parsed dict into the canonical plan shape with defaults —
used for the mlx JSON path and for update_plan validation."""
def _normalize_plan(raw: dict) -> dict {
    mix: list[dict] = [];
    mix_in: any = raw.get("mix", []);
    if isinstance(mix_in, list) {
        for it in mix_in {
            if isinstance(it, dict) {
                mix.append({
                    "type_name": str(it.get("type_name", "")),
                    "description": str(it.get("description", "")),
                    "share_pct": _to_int(it.get("share_pct", 0))
                });
            }
        }
    }
    return {
        "description": str(raw.get("description", "")),
        "schema": "sft-chat",
        "mix": mix,
        "target_rows": _to_int(raw.get("target_rows", 0)),
        "system_prompt": str(raw.get("system_prompt", "")),
        "grounding_notes": str(raw.get("grounding_notes", ""))
    };
}

# ============================================================ claude path ======
"""Draft via byllm/Anthropic. Wires _PLAN_CFG then runs propose_plan by _plan_llm.
Returns {ok, plan, error}.

The _PLAN_CFG write and the propose_plan call are ONE critical section under
_PLAN_LOCK — _PLAN_CFG is module state and `by _plan_llm()` reads it back at
call time, so an unguarded interleave bills user A's Anthropic key for user B's
draft. ponytail: a plain mutex, so concurrent claude drafts are SERIALIZED
(~30-60s each). Ceiling = one in-flight Anthropic plan draft per process; the
correct fix is threading key/model through propose_plan, but byllm puts every
parameter into the prompt, which would leak the API key to the model."""
def _draft_claude(p: JmsProject, model: str, grounding: str) -> dict {
    key = jms_llm.resolved_anthropic_key();
    if not key { return {"ok": False, "plan": {}, "error": "no Anthropic key configured — set one in the key modal"}; }
    _PLAN_LOCK.acquire();
    try {
        _PLAN_CFG["model_name"] = "anthropic/" + model;
        _PLAN_CFG["api_key"] = key;
        dp = propose_plan(p.use_case, grounding);
        return {"ok": True, "plan": _dp_to_dict(dp), "error": ""};
    } except Exception as e {
        return {"ok": False, "plan": {}, "error": "claude plan failed: " + str(e)[:240]};
    } finally {
        _PLAN_CFG["model_name"] = "";
        _PLAN_CFG["api_key"] = "";
        _PLAN_LOCK.release();
    }
}

# ============================================================== mlx path =======
"""Strict JSON instruction for the local model."""
def _mlx_prompt(use_case: str, grounding: str) -> str {
    schema = "{\"description\": str, \"mix\": [{\"type_name\": str, \"description\": str, \"share_pct\": int}], \"target_rows\": int, \"system_prompt\": str, \"grounding_notes\": str}";
    return "You design supervised-finetuning dataset plans.\n\n"
        + "USE CASE:\n" + use_case + "\n\n"
        + "SOURCE SAMPLES:\n" + grounding + "\n\n"
        + "Design a dataset plan: a description, a mix of 3-6 example categories "
        + "(each with type_name, description, and an integer share_pct summing to ~100), "
        + "a target_rows count, a system_prompt, and grounding_notes.\n\n"
        + "Reply with ONLY a single JSON object matching this schema, no prose, no code fence:\n"
        + schema;
}

"""Run the resident MLX model to completion, returning the full text ("" on an
error frame). Consumes inference.stream_chat."""
def _mlx_generate(model_id: str, path: str, prompt: str) -> str {
    msgs: list[dict] = [{"role": "user", "content": prompt}];
    acc = "";
    gen: any = inference.stream_chat(msgs, model_id, path, 0.3, 0.95, 1400);
    for frame in gen {
        kind = str(frame["kind"]);
        if kind == "token" { acc = str(frame["text"]); }
        if kind == "done" { acc = str(frame["text"]); }
        if kind == "error" { return ""; }
    }
    return acc;
}

"""Extract the first {...} JSON object from *txt* (tolerating code fences /
surrounding prose). None on parse failure."""
def _try_parse(txt: str) -> dict | None {
    t = txt.strip();
    a = -1;
    b = -1;
    for i in range(len(t)) {
        if t[i] == "{" { a = i; break; }
    }
    for i in range(len(t) - 1, -1, -1) {
        if t[i] == "}" { b = i; break; }
    }
    if a < 0 or b < 0 or b < a { return None; }
    try {
        val: any = json.loads(t[a:b + 1]);
        if isinstance(val, dict) { return dict(val); }
        return None;
    } except Exception {
        return None;
    }
}

"""Draft via the resident local MLX model. One retry on a JSON parse miss.
Returns {ok, plan, error}."""
def _draft_mlx(p: JmsProject, model: str, grounding: str) -> dict {
    m = models.model_by_id(model);
    if not m { return {"ok": False, "plan": {}, "error": "unknown local model: " + model}; }
    if not models.model_available(m) { return {"ok": False, "plan": {}, "error": "local model not on disk: " + model}; }
    path = str(models.model_path(m));
    prompt = _mlx_prompt(p.use_case, grounding);
    txt = _mlx_generate(model, path, prompt);
    parsed = _try_parse(txt);
    if parsed is None {
        txt2 = _mlx_generate(model, path, prompt + "\n\nYour previous reply was not valid JSON. Reply ONLY the JSON object.");
        parsed = _try_parse(txt2);
    }
    if parsed is None { return {"ok": False, "plan": {}, "error": "local model did not return valid JSON"}; }
    return {"ok": True, "plan": _normalize_plan(parsed), "error": ""};
}

# ============================================================== endpoints ======
"""Highest existing plan version for *p* (0 when none)."""
def _next_version(p: JmsProject) -> int {
    mx = 0;
    for g in _gen_plans_of(p) {
        if g.version > mx { mx = g.version; }
    }
    return mx + 1;
}

def _find_plan(p: JmsProject, version: int) -> JmsGenPlan | None {
    for g in _gen_plans_of(p) {
        if g.version == version { return g; }
    }
    return None;
}

"""Author a new dataset-plan draft (BLOCKING; the claude path is a network call,
the mlx path loads/runs a resident model — expect ~30-60s). *provider* is
'claude' or 'mlx'; *model* is the provider's model id. Persists the result as a
new JmsGenPlan draft at version max+1. Returns {ok, plan, error}; on failure the
plan is not persisted."""
def draft_plan(pid: str, provider: str, model: str) -> dict {
    p = _find_project(pid);
    if p is None { return {"ok": False, "plan": {}, "error": "unknown project"}; }
    grounding = _collect_grounding(p);
    res: dict = {};
    if provider == "claude" {
        res = _draft_claude(p, model, grounding);
    } elif provider == "mlx" {
        res = _draft_mlx(p, model, grounding);
    } else {
        return {"ok": False, "plan": {}, "error": "unknown provider: " + provider};
    }
    if not bool(res["ok"]) {
        return {"ok": False, "plan": {}, "error": str(res["error"])};
    }
    plan = dict(res["plan"]);
    g = (p ++> JmsGenPlan(
        version=_next_version(p), status="draft", provider=provider, model=model,
        plan_json=json.dumps(plan), created=_now()
    ))[0];
    return {"ok": True, "plan": _plan_dict(g), "error": ""};
}

"""All of a project's plans as parsed dicts, newest (highest version) first."""
def get_plans(pid: str) -> list[dict] {
    p = _find_project(pid);
    if p is None { return []; }
    return _plans_newest_first(p);
}

"""Replace a DRAFT plan's body from an edited plan_json string (normalized to the
canonical shape). Approved plans are immutable. Returns {ok, plan, error}."""
def update_plan(pid: str, version: int, plan_json: str) -> dict {
    p = _find_project(pid);
    if p is None { return {"ok": False, "plan": {}, "error": "unknown project"}; }
    g = _find_plan(p, version);
    if g is None { return {"ok": False, "plan": {}, "error": "unknown plan version"}; }
    if g.status != "draft" { return {"ok": False, "plan": {}, "error": "only draft plans are editable"}; }
    parsed: any = None;
    try {
        parsed = json.loads(plan_json);
    } except Exception {
        return {"ok": False, "plan": {}, "error": "invalid plan JSON"};
    }
    if not isinstance(parsed, dict) { return {"ok": False, "plan": {}, "error": "plan JSON must be an object"}; }
    g.plan_json = json.dumps(_normalize_plan(dict(parsed)));
    return {"ok": True, "plan": _plan_dict(g), "error": ""};
}

"""Approve a plan version: mark it approved (with a timestamp) and demote any
other approved plan back to draft, so at most one plan is ever approved."""
def approve_plan(pid: str, version: int) -> dict {
    p = _find_project(pid);
    if p is None { return {"ok": False, "plan": {}, "error": "unknown project"}; }
    g = _find_plan(p, version);
    if g is None { return {"ok": False, "plan": {}, "error": "unknown plan version"}; }
    for other in _gen_plans_of(p) {
        if other.version != version and other.status == "approved" {
            other.status = "draft";
            other.approved_at = "";
        }
    }
    g.status = "approved";
    g.approved_at = _now();
    return {"ok": True, "plan": _plan_dict(g), "error": ""};
}

"""The current approved plan for a project as a dict, or None. Helper for the
later SYNTHESIZE step."""
def latest_approved(pid: str) -> dict | None {
    p = _find_project(pid);
    if p is None { return None; }
    approved: list[dict] = [];
    for g in _gen_plans_of(p) {
        if g.status == "approved" { approved.append(_plan_dict(g)); }
    }
    if not approved { return None; }
    approved.sort(key=lambda d: dict -> int { return int(str(d["version"])); }, reverse=True);
    return approved[0];
}
