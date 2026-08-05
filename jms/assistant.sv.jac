"""studio - in-app AI assistant: OpenAI key storage + unified provider listing.

Task A1 of the phase-2 grounded-assistant feature. Mirrors `jms_llm.sv.jac`'s
Anthropic-key pattern exactly, but for OpenAI, and adds a unified
`assistant_providers()` endpoint the assistant's model picker calls to list
local MLX + Claude + OpenAI together. Kept as its own module (rather than
extending jms_llm) so the pre-existing PLAN feature stays undisturbed.

Never echo the key: no endpoint returns it. `resolved_openai_key` is internal —
it decrypts the user key, else falls back to the OPENAI_API_KEY env var — and
is the single point the plaintext key exists (same discipline as
`jms_llm.resolved_anthropic_key`).
"""

import os;
import time;
import datetime;
import auth;
import crypto;
import models;
import inference;
import from jms_llm { resolved_anthropic_key, llm_status }
import from workspace { ui_layout }
import from jms_workspaces { jms_ui_layout }
import from jms_projects { JmsProjectView, list_projects, get_project }
import from jms_eval { list_jms_evals }
import from runs { list_runs }
import from evals { list_evals }
import from cloudruns { list_cloud_runs }
import from persistence { list_chats }

def _now() -> str {
    return datetime.datetime.now(datetime.UTC).replace(tzinfo=None).isoformat() + "Z";
}

# ------------------------------------------------------------------ key node ---
"""Per-user assistant provider settings. 0..1 off the caller's own root;
`openai_key` is encrypted at rest via crypto.encrypt (see crypto.sv.jac)."""
node OpenAiSettings {
    has openai_key: str = "",
        set_at: str = "";
}

"""The caller's OpenAiSettings, or None. Caller's root only (multi-tenant)."""
def _settings() -> OpenAiSettings | None {
    s = [root -->][?:OpenAiSettings];
    return s[0] if len(s) > 0 else None;
}

"""Resolve the OpenAI key: caller's stored (decrypted) key wins, else the
shared OPENAI_API_KEY env var, else "". The only place the plaintext key
exists — never surface this from an endpoint."""
def resolved_openai_key() -> str {
    s = _settings();
    if s is not None and s.openai_key { return str(crypto.decrypt(s.openai_key)); }
    return os.environ.get("OPENAI_API_KEY", "");
}

"""Where the resolved key comes from: user | env | none."""
def _key_source() -> str {
    s = _settings();
    if s is not None and s.openai_key { return "user"; }
    if os.environ.get("OPENAI_API_KEY", "") { return "env"; }
    return "none";
}

"""Masked tail (…last4) of the user-set key, or "" when not user-set. Decrypts
only to reveal the final 4 chars for the status badge — never the whole key."""
def _masked_tail() -> str {
    s = _settings();
    if s is None or not s.openai_key { return ""; }
    k = str(crypto.decrypt(s.openai_key));
    if len(k) <= 4 { return "…"; }
    return "…" + k[len(k) - 4:];
}

# ------------------------------------------------------------------ endpoints --
"""Store or replace the caller's OpenAI API key on their own root (encrypted).
Never echoes the key back. Returns {ok, source, error}."""
def set_openai_key(key: str) -> dict {
    k = key.strip();
    if not k { return {"ok": False, "source": _key_source(), "error": "empty key"}; }
    enc = crypto.encrypt(k);
    existing = _settings();
    if existing is not None {
        existing.openai_key = enc;
        existing.set_at = _now();
    } else {
        root ++> OpenAiSettings(openai_key=enc, set_at=_now());
    }
    return {"ok": True, "source": "user", "error": ""};
}

"""Delete the caller's stored key (falls back to the OPENAI_API_KEY env var)."""
def clear_openai_key() -> dict {
    s = _settings();
    if s is not None { s.openai_key = ""; s.set_at = ""; }
    return {"ok": True, "source": _key_source(), "error": ""};
}

"""Unified provider catalog for the assistant's model picker: local MLX +
Claude + OpenAI in one shape. Never returns any key. Shape:
{providers: [
  {id:"mlx",    label, requires_key, configured, models:[<available local ids>]},
  {id:"claude", label, requires_key, configured, models:[...]},
  {id:"openai", label, requires_key, configured, models:[...]}
]}."""
def assistant_providers() -> dict {
    mlx_models: list[str] = [];
    try {
        for m in models.list_models() {
            if m.available { mlx_models.append(m.id); }
        }
    } except Exception {}
    providers: list[dict] = [
        {
            "id": "mlx",
            "label": "Local (MLX)",
            "requires_key": False,
            "configured": True,
            "models": mlx_models
        },
        {
            "id": "claude",
            "label": "Claude (Anthropic)",
            "requires_key": True,
            "configured": resolved_anthropic_key() != "",
            "models": ["claude-sonnet-5", "claude-haiku-4-5"]
        },
        {
            "id": "openai",
            "label": "OpenAI",
            "requires_key": True,
            "configured": resolved_openai_key() != "",
            "models": ["gpt-4o", "gpt-4o-mini"]
        }
    ];
    return {"providers": providers};
}

# ================================================================================
# Task A2 — full-app-state context bundle: so the assistant "knows everything".
#
# `_collect_assistant_context()` fans out to every already-existing, cheap
# dict/list-returning server function across the app (Experiments + JMS
# workspaces, JMS projects incl. per-project stage_state/counts, JMS + classic
# train runs, JMS + standalone evals, cloud deployments, recent chat titles,
# configured LLM providers) and serializes them into ONE labeled plain-text
# digest. Best-effort: every source call is wrapped in its own try/except so
# one failing source (empty graph, missing file, etc.) can't blank out the
# whole bundle — a failed section just leaves a short "(unavailable: ...)"
# note instead of raising.
#
# Size caps mirror `jms_plan.sv.jac`'s grounding caps (`_MAX_GROUND_CHARS` /
# `_PER_FILE_CHARS`): each section is capped on its own so no single large
# section can eat the whole budget, and the assembled digest is hard-capped
# at `_MAX_GROUND_CHARS` with a "…(truncated)" marker. This deliberately does
# NOT read raw dataset/log FILE contents — only structured sv-call data — to
# keep the bundle bounded and fast; file-content grounding is a later
# refinement.
#
# NEVER includes secrets: `llm_status()` already masks provider keys — only
# its safe fields (id/label/requires_key/models/configured/source) are used
# here, never a key. `spheron.list_spheron_dispatches()` is intentionally
# NOT called: it refreshes each dispatch via a live Spheron API request
# (`spheron_instance` -> `_request`), which needs credentials and can be
# slow/error without them — not the cheap dict call this task wants.
# ================================================================================

glob _MAX_GROUND_CHARS: int = 30000;
glob _PER_FILE_CHARS: int = 2000;

"""Clip *s* to *limit* chars, appending a truncation marker if it was cut."""
def _clip(s: str, limit: int) -> str {
    if len(s) <= limit { return s; }
    return s[:limit] + "\n…(truncated)";
}

"""Best-effort `list_projects()` — used by every per-project section below so
one bad project (or an empty graph) can't kill the others."""
def _safe_projects() -> list[JmsProjectView] {
    try {
        return list_projects();
    } except Exception {
        return [];
    }
}

"""Every project's `get_project(pid)` detail, fetched ONCE for the whole digest:
pid -> {"detail": dict, "err": str}.

This is the cheap node-fields-only path. It replaces two per-project fan-outs that
each re-derived data get_project already carries: `_sec_jms_projects` called
get_project itself, and `_sec_jms_train_runs` called `jms_train.list_train_runs`,
which runs `train_status` per run — a FULL `metrics.parse_train_log` + 40-line tail
read of every run log (and a `cloudruns.run_status` poll for spheron runs). With
~10 projects x ~5 runs that was dozens of full log parses per chat message, for a
digest that only prints rid/backend/base_model/status/adapter_ready/started/
finished — all of which `jms_projects._train_run_dict` supplies from node fields.

TRADE-OFF (the only behavior change): `status` is now the node's stored status
rather than train_status's live re-resolution from the job file. No field is
dropped. The node is written by `_sync_terminal` on every train_status call, and
the TrainStage UI polls that constantly, so the node is current in practice; the
window where this differs is a run that terminated and has not been polled since.
Ordering is unchanged — get_project sorts train_runs by `started` descending,
exactly as list_train_runs did."""
def _project_details(projects: list[JmsProjectView]) -> dict[str, dict] {
    out: dict[str, dict] = {};
    for pv in projects {
        try {
            out[pv.pid] = {"detail": get_project(pv.pid), "err": ""};
        } except Exception as e {
            out[pv.pid] = {"detail": {}, "err": str(e)};
        }
    }
    return out;
}

def _sec_exp_workspaces() -> str {
    try {
        layout = ui_layout();
        lines: list[str] = [
            "=== WORKSPACES (Experiments) ===",
            "default: " + str(layout.get("default_workspace", ""))
        ];
        wss = layout.get("workspaces", []);
        if not wss { lines.append("(none)"); }
        for w in wss {
            secs = [s.label for s in w.sections] if w.sections else [];
            lines.append(f"- {w.id} \"{w.label}\" accent={w.accent} sections={secs}");
        }
        return _clip("\n".join(lines), _PER_FILE_CHARS);
    } except Exception as e {
        return "=== WORKSPACES (Experiments) ===\n(unavailable: " + str(e) + ")";
    }
}

def _sec_jms_workspaces() -> str {
    try {
        layout = jms_ui_layout();
        lines: list[str] = [
            "=== JMS WORKSPACES ===",
            "default: " + str(layout.get("default_workspace", ""))
        ];
        wss = layout.get("workspaces", []);
        if not wss { lines.append("(none)"); }
        for w in wss {
            lines.append(f"- {w.id} \"{w.label}\" accent={w.accent}");
        }
        return _clip("\n".join(lines), _PER_FILE_CHARS);
    } except Exception as e {
        return "=== JMS WORKSPACES ===\n(unavailable: " + str(e) + ")";
    }
}

"""JMS PROJECTS: name/use_case/provider+model/source_count/group from
list_projects(), plus stage_state + row_stats + source/plan/gen_job/train_run/
eval counts from get_project(pid) for each. A per-project failure (rare —
get_project is a pure graph read) only drops that project's detail line, not
the whole section."""
def _sec_jms_projects(projects: list[JmsProjectView], details: dict[str, dict]) -> str {
    lines: list[str] = ["=== JMS PROJECTS ==="];
    if not projects { lines.append("(none)"); }
    for pv in projects {
        entry: dict = dict(details.get(pv.pid, {}));
        derr = str(entry.get("err", ""));
        if derr {
            lines.append(f"- {pv.name} (pid={pv.pid}) (detail unavailable: {derr})");
            continue;
        }
        grp = pv.group_id if pv.group_id else "(none)";
        block: list[str] = [
            f"- {pv.name} (pid={pv.pid}) use_case={pv.use_case} "
            f"provider/model={pv.provider}/{pv.model} sources={pv.source_count} "
            f"group={grp}"
        ];
        detail: dict = dict(entry.get("detail", {}));
        if detail {
            stage_state = detail.get("stage_state", {});
            row_stats = detail.get("row_stats", {});
            block.append(
                f"    stage_state={stage_state} row_stats={row_stats} "
                f"sources={len(detail.get('sources', []))} "
                f"plans={len(detail.get('plans', []))} "
                f"gen_jobs={len(detail.get('gen_jobs', []))} "
                f"train_runs={len(detail.get('train_runs', []))} "
                f"evals={len(detail.get('evals', []))}"
            );
        }
        lines.append(_clip("\n".join(block), _PER_FILE_CHARS));
    }
    return _clip("\n".join(lines), _PER_FILE_CHARS * 6);
}

"""JMS TRAIN RUNS across every project: rid/backend/base_model/status/
adapter_ready/started/finished — same fields as before, now read off the
already-fetched `get_project(pid)["train_runs"]` (node fields, newest-first) so
the digest no longer pays a full training-log parse per run. See
`_project_details` for the one behavioral trade-off (node vs live status)."""
def _sec_jms_train_runs(projects: list[JmsProjectView], details: dict[str, dict]) -> str {
    lines: list[str] = ["=== JMS TRAIN RUNS ==="];
    any_rows = False;
    for pv in projects {
        entry: dict = dict(details.get(pv.pid, {}));
        derr = str(entry.get("err", ""));
        if derr {
            lines.append(f"- [{pv.name}] (unavailable: {derr})");
            continue;
        }
        detail: dict = dict(entry.get("detail", {}));
        for raw in list(detail.get("train_runs", [])) {
            r: dict = dict(raw);
            any_rows = True;
            lines.append(
                f"- [{pv.name}] rid={r.get('rid', '')} backend={r.get('backend', '')} "
                f"base_model={r.get('base_model', '')} status={r.get('status', '')} "
                f"adapter_ready={r.get('adapter_ready', False)} "
                f"started={r.get('started', '')} finished={r.get('finished', '')}"
            );
        }
    }
    if not any_rows { lines.append("(none)"); }
    return _clip("\n".join(lines), _PER_FILE_CHARS * 4);
}

"""JMS EVALS across every project: eid/metric/status/n/mean_score/pass_rate
from `list_jms_evals(pid)`."""
def _sec_jms_evals(projects: list[JmsProjectView]) -> str {
    lines: list[str] = ["=== JMS EVALS ==="];
    any_rows = False;
    for pv in projects {
        try {
            eval_rows = list_jms_evals(pv.pid);
        } except Exception as e {
            lines.append(f"- [{pv.name}] (unavailable: {e})");
            continue;
        }
        for ev in eval_rows {
            any_rows = True;
            lines.append(
                f"- [{pv.name}] eid={ev.get('eid', '')} metric={ev.get('metric', '')} "
                f"status={ev.get('status', '')} n={ev.get('n', 0)} "
                f"mean_score={ev.get('mean_score', 0)} pass_rate={ev.get('pass_rate', 0)}"
            );
        }
    }
    if not any_rows { lines.append("(none)"); }
    return _clip("\n".join(lines), _PER_FILE_CHARS * 4);
}

"""Classic (pre-JMS) SFT/DPO attempt runs from `runs.list_runs()`."""
def _sec_classic_runs() -> str {
    try {
        data = list_runs();
        lines: list[str] = ["=== CLASSIC RUNS (SFT/DPO) ==="];
        items = data.get("runs", []);
        if not items { lines.append("(none)"); }
        for r in items {
            lines.append(
                f"- {r.get('name', '')} has_sft={r.get('has_sft', False)} "
                f"has_dpo={r.get('has_dpo', False)} running={r.get('running', False)} "
                f"stages={r.get('stages', {})}"
            );
        }
        return _clip("\n".join(lines), _PER_FILE_CHARS * 3);
    } except Exception as e {
        return "=== CLASSIC RUNS (SFT/DPO) ===\n(unavailable: " + str(e) + ")";
    }
}

"""Standalone EvalRun list from `evals.list_evals()` (the classic-runs eval
surface, distinct from JMS per-project evals above)."""
def _sec_standalone_evals() -> str {
    try {
        data = list_evals();
        lines: list[str] = ["=== STANDALONE EVALS ==="];
        items = data.get("evals", []);
        if not items { lines.append("(none)"); }
        for ev in items {
            lines.append(
                f"- {ev.id} kind={ev.kind} model={ev.model} status={ev.status} "
                f"started={ev.started} finished={ev.finished}"
            );
        }
        return _clip("\n".join(lines), _PER_FILE_CHARS * 2);
    } except Exception as e {
        return "=== STANDALONE EVALS ===\n(unavailable: " + str(e) + ")";
    }
}

"""Cloud (Spheron) supervised deployments from `cloudruns.list_cloud_runs()`."""
def _sec_cloud_runs() -> str {
    try {
        data = list_cloud_runs();
        lines: list[str] = ["=== CLOUD DEPLOYMENTS ==="];
        items = data.get("runs", []);
        if not items { lines.append("(none)"); }
        for r in items {
            cost = r.get("cost", {});
            elapsed = cost.get("elapsed_usd", 0) if cost else 0;
            lines.append(
                f"- {r.get('name', '')} mode={r.get('mode', '')} "
                f"status={r.get('status', '')} phase={r.get('phase', '')} "
                f"hourly_rate={r.get('hourly_rate', 0)} elapsed_usd={elapsed}"
            );
        }
        return _clip("\n".join(lines), _PER_FILE_CHARS * 2);
    } except Exception as e {
        return "=== CLOUD DEPLOYMENTS ===\n(unavailable: " + str(e) + ")";
    }
}

"""Recent chat titles from `persistence.list_chats()` (default workspace —
newest-updated first; capped to the most recent 15)."""
def _sec_chat_history() -> str {
    try {
        chats = list_chats();
        lines: list[str] = ["=== RECENT CHATS ==="];
        if not chats { lines.append("(none)"); }
        for c in chats[:15] {
            lines.append(f"- \"{c.title}\" workspace={c.workspace} updated={c.updated_at}");
        }
        return _clip("\n".join(lines), _PER_FILE_CHARS);
    } except Exception as e {
        return "=== RECENT CHATS ===\n(unavailable: " + str(e) + ")";
    }
}

"""Configured LLM providers from `jms_llm.llm_status()` — safe fields only,
NEVER a key (llm_status already masks; this only reads id/label/requires_key/
models/configured/source)."""
def _sec_llm_providers() -> str {
    try {
        status = llm_status();
        lines: list[str] = [
            "=== LLM PROVIDERS ===",
            "anthropic configured=" + str(status.get("configured", False)) +
            " source=" + str(status.get("source", "none"))
        ];
        for p in status.get("providers", []) {
            lines.append(
                f"- {p.get('id', '')} \"{p.get('label', '')}\" "
                f"requires_key={p.get('requires_key', False)} "
                f"models={p.get('models', [])}"
            );
        }
        return _clip("\n".join(lines), _PER_FILE_CHARS);
    } except Exception as e {
        return "=== LLM PROVIDERS ===\n(unavailable: " + str(e) + ")";
    }
}

# Per-user digest memo. The digest is rebuilt on EVERY assistant message and every
# assistant_context() poll, and assembling it fans out across the whole app. Key =
# `auth.uid()` (the caller's own root jid) — never a bare filename or any key two
# tenants could share, so one user can never be served another's digest. TTL is
# deliberately short (10s): the digest is a live grounding snapshot, so it must go
# stale in seconds, not minutes. uid() is request-context only; if it is
# unavailable (e.g. a plain `jac run` script) the memo is bypassed entirely.
glob _CTX_TTL_S: float = 10.0;
glob _CTX_CACHE: dict[str, dict] = {};
glob _CTX_CACHE_CAP: int = 64;

"""Assemble the full-app-state grounding digest: every source above,
labeled + best-effort, joined and hard-capped at `_MAX_GROUND_CHARS`.

Memoized per user for `_CTX_TTL_S` seconds. `list_projects()` + each project's
`get_project()` are also fetched once per assembly and shared by the per-project
sections (they each used to re-scan on their own)."""
def _collect_assistant_context() -> str {
    ukey = "";
    try { ukey = auth.uid(); } except Exception { ukey = ""; }
    now = time.time();
    if ukey {
        hit = _CTX_CACHE.get(ukey);
        if hit is not None and (now - float(str(hit["at"]))) < _CTX_TTL_S {
            return str(hit["digest"]);
        }
    }

    projects = _safe_projects();
    details = _project_details(projects);
    sections: list[str] = [
        _sec_exp_workspaces(),
        _sec_jms_workspaces(),
        _sec_jms_projects(projects, details),
        _sec_jms_train_runs(projects, details),
        _sec_jms_evals(projects),
        _sec_classic_runs(),
        _sec_standalone_evals(),
        _sec_cloud_runs(),
        _sec_chat_history(),
        _sec_llm_providers()
    ];
    digest = _clip("\n\n".join(sections), _MAX_GROUND_CHARS);
    if ukey {
        if len(_CTX_CACHE) > _CTX_CACHE_CAP { _CTX_CACHE.clear(); }
        _CTX_CACHE[ukey] = {"at": now, "digest": digest};
    }
    return digest;
}

"""Debug endpoint for the full-app-state grounding digest the assistant is
primed with (Task A2 self-check calls this directly too). Never returns
secrets — see the module-level note above `_collect_assistant_context`."""
def assistant_context() -> str {
    return _collect_assistant_context();
}

# ================================================================================
# Task A3 — grounded streaming chat over MLX / Claude / OpenAI.
#
# `assistant_stream` prepends the full-app-state grounding digest (Task A2) as a
# system message, then dispatches by `provider`. Same SSE frame protocol as
# `chat.sv.jac:chat_stream` — {kind:"load",...} once, {kind:"token",...} per
# token, {kind:"done",...} last, {kind:"error",...} on failure — so the client
# reuses the exact same raw-fetch-reader plumbing for either endpoint.
#
# mlx branch: mirrors chat_stream's model resolution (model_by_id + model_path +
# model_available) verbatim, then delegates to inference.stream_chat with the
# grounded message list. NOT runtime-testable in this worktree — mlx isn't
# installed in the serving venv here — correctness is by construction (same
# calls chat_stream already makes, which IS exercised at integration).
#
# claude/openai branches call litellm directly (installed in the serving venv)
# rather than byllm (jms_plan.sv.jac's approach for the PLAN feature) because
# byllm has no token-streaming API — litellm.completion(..., stream=True) does.
# Never yields the resolved key in any frame.
#
# SHAPE (do not collapse back into one function): `assistant_stream` is a PLAIN
# function that resolves grounding + the provider key and RETURNS one of the
# `_stream_*` generators. Only that split runs the graph reads inside the
# caller's request context — a `yield` in the endpoint itself defers the whole
# body to a context with no user root, which is what made a configured Anthropic
# key invisible and Claude permanently unreachable. See assistant_stream's
# docstring.
#
# No error frame ever carries a raw exception: `_clean_error` logs the detail
# server-side and returns short, actionable copy (the transcript used to receive
# Python errno strings straight from inference.stream_chat / litellm).
# ================================================================================

glob _ASSISTANT_PREAMBLE: str = (
    "You are Claude, the in-app copilot for Jac Model Studio. You proactively "
    "help users act inside the app.\n"
    "OPERATING RULES:\n"
    "1. Context: read the current workspace + project from the LIVE APP STATE "
    "below. If neither is stated there or by the user, assume the 'main' "
    "workspace and the 'Test' project.\n"
    "2. Intent: infer what the user wants — train, evaluate, generate, or "
    "change settings.\n"
    "3. Action: propose exactly ONE specific, executable step inside Jac Model "
    "Studio — name the exact stage, button, or field and value (e.g. 'open the "
    "EVALS stage', 'Start a new training run', 'set learning rate to 0.01'). "
    "Every suggestion must be doable in the app; never suggest external tools, "
    "shells, or files.\n"
    "4. Confirm: in one line, confirm the step matches their intent, or ask ONE "
    "clarifying question if the request is ambiguous (e.g. which model).\n"
    "5. Concise: one suggestion per reply. No long explanations, no options "
    "list. Ground every claim in the live app state below; if it isn't there, "
    "say so plainly rather than guessing.\n\n"
    "=== HOW TO ACT ===\n"
    "You can DRIVE the app, not just describe. When the user wants to go "
    "somewhere or do something, write your one-line confirmation, then on a NEW "
    "line emit EXACTLY ONE action block, nothing after it:\n"
    "<<DO>>{\"action\":\"...\",...}<</DO>>\n"
    "Valid actions (emit at most one, only when the user asked to act). Pick ONE "
    "concrete value per field — NEVER copy an option list like a|b|c verbatim:\n"
    "- navigate — move the UI. Fields: \"surface\" = exactly one of experiments, "
    "jms, hub; \"workspace\" = an id or label from live state (optional); "
    "\"stage\" = one of chat, data, train, evals, cloud, results (optional).\n"
    "  Example: <<DO>>{\"action\":\"navigate\",\"surface\":\"experiments\","
    "\"workspace\":\"03\",\"stage\":\"train\"}<</DO>>\n"
    "- start_training — Fields: \"name\", \"mode\" = sft OR dpo, \"model_id\" "
    "(optional).\n"
    "  Example: <<DO>>{\"action\":\"start_training\",\"name\":\"my-run\",\"mode\":"
    "\"sft\",\"model_id\":\"qwen-base\"}<</DO>>\n"
    "- create_eval — Fields: \"kind\" (from live state), \"model_id\" (optional), "
    "\"holdout\" = function OR graph (optional), \"limit\" (int, optional).\n"
    "  Example: <<DO>>{\"action\":\"create_eval\",\"kind\":\"function\"}<</DO>>\n"
    "- set_setting — Fields: \"wid\" (jms workspace id) plus any of "
    "\"default_model\", \"accent\", \"label\".\n"
    "  Example: <<DO>>{\"action\":\"set_setting\",\"wid\":\"1\",\"default_model\":"
    "\"qwen-dpo\"}<</DO>>\n"
    "Do NOT put the action block inside a markdown code fence (no ``` around "
    "it) — emit the <<DO>>...<</DO>> line as plain text.\n"
    "Rules: use ids/labels that appear in the live state below (never invent "
    "them). Emit an action ONLY for a clear act request; for a pure question, "
    "answer in prose with no block. The app auto-runs navigate and asks the user "
    "to confirm training/eval/settings, so you never need to ask permission "
    "yourself — just emit the block. Use GitHub-flavored markdown in prose "
    "(headings, **bold**, `code`, fenced ```code```, - lists).\n\n"
    "=== LIVE APP STATE ===\n"
);

"""Prepend a system message carrying the grounding preamble + the full-app-state
digest, then the caller's own messages, unmodified."""
def _grounded_messages(messages: list[dict], context: str) -> list[dict] {
    # Prefer a context assembled by the CALLER (client) in a normal request:
    # this generator's body runs deferred, OUTSIDE the authenticated user-root,
    # so _collect_assistant_context() reads an empty graph here. The client
    # fetches assistant_context() first (correct root) and passes it in. Fall
    # back to the in-generator collect only if the caller passed nothing.
    ground = context if context else _collect_assistant_context();
    preamble = _ASSISTANT_PREAMBLE + ground;
    # Fold the grounding into the FIRST user turn rather than a system message:
    # some local chat templates (e.g. Gemma) reject a `system` role outright
    # (TemplateError: System role not supported). Prepending to the user turn
    # is universal across MLX (qwen/gemma), Claude, and OpenAI.
    out: list[dict] = [];
    injected = False;
    for m in messages {
        if (not injected) and str(m["role"]) == "user" {
            out.append({"role": "user", "content": preamble + "\n\n--- USER QUESTION ---\n" + str(m["content"])});
            injected = True;
        } else {
            out.append(m as dict);
        }
    }
    if not injected {
        out.append({"role": "user", "content": preamble});
    }
    return out;
}

"""Display name for a provider id, for user-facing error copy."""
def _provider_label(provider: str) -> str {
    if provider == "claude" { return "Claude"; }
    if provider == "openai" { return "OpenAI"; }
    return "The local model";
}

"""The 'no key configured' copy, matching how the rest of the app phrases it
(GenerateStage: "Set an Anthropic key (⚙ KEYS, top bar) to draft with Claude.")."""
def _no_key_message(provider: str) -> str {
    if provider == "claude" {
        return "Set an Anthropic key (⚙ KEYS, top bar) to chat with Claude.";
    }
    return "Set an OpenAI key (⚙ KEYS, top bar) to chat with OpenAI.";
}

"""Clean, user-facing text for a failure — NEVER the raw exception.

The chat transcript used to receive `str(e)` verbatim (a Python errno/traceback
string: internals leaked into the UI, and unreadable for the user). The detail
now goes to the studio log only; the caller gets a short actionable line."""
def _clean_error(provider: str, detail: str) -> str {
    print("[assistant_stream] " + provider + " failed: " + detail);
    low = detail.lower();
    label = _provider_label(provider);
    if ("authentication" in low or "api key" in low or "api_key" in low
        or "401" in low or "unauthorized" in low or "permission" in low) {
        return label + " rejected the configured API key — update it in ⚙ KEYS.";
    }
    if "rate limit" in low or "ratelimit" in low or "429" in low {
        return label + " is rate-limited right now — try again in a moment.";
    }
    if ("timeout" in low or "timed out" in low or "connection" in low
        or "network" in low) {
        return "Could not reach " + label + " — check the connection and try again.";
    }
    if provider == "mlx" {
        return "The local model failed to run — see the studio log for details.";
    }
    return label + " request failed — see the studio log for details.";
}

"""One-frame error stream. Lets the dispatcher below stay a plain (non-generator)
function while still handing back a valid SSE generator."""
def _error_stream(text: str) -> any {
    yield {"kind": "error", "text": text};
}

"""Local MLX branch: mirrors chat_stream's model resolution, then delegates to
inference.stream_chat. stream_chat surfaces its own failures as an
`{kind:"error", text: str(e)}` frame — that text is a RAW Python error (e.g.
"[Errno 24] Too many open files"), so it is rewritten here before it can reach
the transcript."""
def _stream_local(
    grounded: list[dict], model_id: str,
    temperature: float, top_p: float, max_tokens: int
) -> any {
    try {
        m = models.model_by_id(model_id);
        if not m {
            yield {"kind": "error", "text": f"unknown model_id: {model_id}"};
            return;
        }
        if not models.model_available(m) {
            yield {"kind": "error", "text": f"model not found on disk: {model_id}"};
            return;
        }
        path = str(models.model_path(m));
        gen: any = inference.stream_chat(grounded, model_id, path, temperature, top_p, max_tokens);
        for frame in gen {
            f: dict = dict(frame);
            if str(f.get("kind", "")) == "error" {
                yield {"kind": "error", "text": _clean_error("mlx", str(f.get("text", "")))};
            } else {
                yield f;
            }
        }
    } except Exception as e {
        yield {"kind": "error", "text": _clean_error("mlx", str(e))};
    }
}

"""Claude / OpenAI branch. `key` is resolved by the caller IN the request context
(see `assistant_stream`) and never leaves this process."""
def _stream_api(
    grounded: list[dict], provider: str, model_id: str, key: str,
    temperature: float, max_tokens: int
) -> any {
    model_str = ("anthropic/" if provider == "claude" else "openai/") + model_id;
    try {
        import litellm;
        yield {"kind": "load", "load_s": 0.0, "model_id": model_id};
        resp: any = litellm.completion(
            model=model_str, messages=grounded, stream=True,
            api_key=key, max_tokens=max_tokens, temperature=temperature
        );
        text = "";
        ntok = 0;
        for chunk in resp {
            delta: any = chunk.choices[0].delta.content;
            if delta is None {
                continue;
            }
            text += str(delta);
            ntok += 1;
            yield {"kind": "token", "token": delta, "text": text};
        }
        yield {
            "kind": "done", "text": text, "tokens": ntok, "tps": 0,
            "load_s": 0, "gen_s": 0
        };
    } except Exception as e {
        yield {"kind": "error", "text": _clean_error(provider, str(e))};
    }
}

"""Grounded streaming chat over any provider. Same SSE frame protocol as
chat_stream: {kind:"load",load_s,model_id} once, {kind:"token",token,text} per
token, {kind:"done",text,tokens,tps,load_s,gen_s} last, {kind:"error",text} on
failure, a missing key, or an unrecognized provider.

THIS FUNCTION MUST NOT CONTAIN `yield`. That is the whole point of the split:
jac-scale runs a function endpoint inside the caller's request context
(`ExecutionManager.execute_function_sync` -> `_begin_request_context(root_id)`)
and resets that context in its `finally` — but a generator's BODY only runs
later, when the StreamingResponse iterates it. So a `yield` here would defer
every graph read to a context with no user root: `resolved_anthropic_key()` read
an EMPTY graph and returned "", and Claude answered "API key not set" even for a
user whose key was configured (verified live) — i.e. picking Claude could never
work unless the ANTHROPIC_API_KEY env var happened to be set. It never silently
fell back to MLX, but it never reached Claude either.

Keeping this body generator-free runs the key + grounding resolution IN the
request context and hands back an inner generator, which jac-scale still detects
(`isgenerator(result)`) and wraps in the same SSE StreamingResponse. Same reason
`_grounded_messages` prefers a client-supplied `context`."""
def assistant_stream(
    messages: list[dict], provider: str, model_id: str, context: str = "",
    temperature: float = 0.3, top_p: float = 0.9, max_tokens: int = 1536
) -> any {
    grounded = _grounded_messages(messages, context);

    if provider == "mlx" {
        return _stream_local(grounded, model_id, temperature, top_p, max_tokens);
    }

    if provider == "claude" or provider == "openai" {
        # Same key-status source of truth the picker's `configured` flag uses
        # (assistant_providers -> resolved_*_key). Refuse BEFORE dispatching so
        # an unconfigured provider can never quietly land on another backend.
        key = resolved_anthropic_key() if provider == "claude" else resolved_openai_key();
        if not key {
            return _error_stream(_no_key_message(provider));
        }
        return _stream_api(grounded, provider, model_id, key, temperature, max_tokens);
    }

    return _error_stream(f"unknown provider: {provider}");
}
