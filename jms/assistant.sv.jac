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
import datetime;
import crypto;
import models;
import inference;
import from jms_llm { resolved_anthropic_key, llm_status }
import from workspace { ui_layout }
import from jms_workspaces { jms_ui_layout }
import from jms_projects { list_projects, get_project }
import from jms_train { list_train_runs }
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
def _safe_projects() -> list {
    try {
        return list_projects();
    } except Exception {
        return [];
    }
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
def _sec_jms_projects() -> str {
    lines: list[str] = ["=== JMS PROJECTS ==="];
    projects = _safe_projects();
    if not projects { lines.append("(none)"); }
    for pv in projects {
        try {
            grp = pv.group_id if pv.group_id else "(none)";
            block: list[str] = [
                f"- {pv.name} (pid={pv.pid}) use_case={pv.use_case} "
                f"provider/model={pv.provider}/{pv.model} sources={pv.source_count} "
                f"group={grp}"
            ];
            detail = get_project(pv.pid);
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
        } except Exception as e {
            lines.append(f"- {pv.name} (pid={pv.pid}) (detail unavailable: {e})");
        }
    }
    return _clip("\n".join(lines), _PER_FILE_CHARS * 6);
}

"""JMS TRAIN RUNS across every project: rid/backend/base_model/status/
adapter_ready/started/finished from `list_train_runs(pid)`."""
def _sec_jms_train_runs() -> str {
    lines: list[str] = ["=== JMS TRAIN RUNS ==="];
    any_rows = False;
    for pv in _safe_projects() {
        try {
            run_rows = list_train_runs(pv.pid);
        } except Exception as e {
            lines.append(f"- [{pv.name}] (unavailable: {e})");
            continue;
        }
        for r in run_rows {
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
def _sec_jms_evals() -> str {
    lines: list[str] = ["=== JMS EVALS ==="];
    any_rows = False;
    for pv in _safe_projects() {
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

"""Assemble the full-app-state grounding digest: every source above,
labeled + best-effort, joined and hard-capped at `_MAX_GROUND_CHARS`."""
def _collect_assistant_context() -> str {
    sections: list[str] = [
        _sec_exp_workspaces(),
        _sec_jms_workspaces(),
        _sec_jms_projects(),
        _sec_jms_train_runs(),
        _sec_jms_evals(),
        _sec_classic_runs(),
        _sec_standalone_evals(),
        _sec_cloud_runs(),
        _sec_chat_history(),
        _sec_llm_providers()
    ];
    digest = "\n\n".join(sections);
    return _clip(digest, _MAX_GROUND_CHARS);
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
# ================================================================================

glob _ASSISTANT_PREAMBLE: str = (
    "You are the in-app assistant for Jac Model Studio. Answer using ONLY the "
    "live app state below plus the user's question. Be concrete; cite "
    "project/run/eval names. If the data doesn't contain the answer, say so.\n\n"
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

"""Grounded streaming chat over any provider. Same SSE frame protocol as
chat_stream: {kind:"load",load_s,model_id} once, {kind:"token",token,text} per
token, {kind:"done",text,tokens,tps,load_s,gen_s} last, {kind:"error",text} on
failure or an unrecognized provider."""
def assistant_stream(
    messages: list[dict], provider: str, model_id: str, context: str = "",
    temperature: float = 0.3, top_p: float = 0.9, max_tokens: int = 1536
) -> any {
    grounded = _grounded_messages(messages, context);

    if provider == "mlx" {
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
            # stream_chat guards load+generate in try/except and emits its own error frame.
            gen: any = inference.stream_chat(grounded, model_id, path, temperature, top_p, max_tokens);
            for frame in gen {
                yield frame;
            }
        } except Exception as e {
            yield {"kind": "error", "text": str(e)};
        }
        return;
    }

    if provider == "claude" or provider == "openai" {
        key = resolved_anthropic_key() if provider == "claude" else resolved_openai_key();
        if not key {
            yield {"kind": "error", "text": provider + " API key not set — add it in ⚙ KEYS"};
            return;
        }
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
            yield {"kind": "error", "text": str(e)};
        }
        return;
    }

    yield {"kind": "error", "text": f"unknown provider: {provider}"};
}
