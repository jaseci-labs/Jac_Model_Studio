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
import from jms_llm { resolved_anthropic_key }

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
