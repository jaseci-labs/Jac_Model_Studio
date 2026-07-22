"""studio - JMS LLM provider config: Anthropic key storage + provider catalog.

The JMS dataset-PLAN step delegates to either a hosted Claude model (byllm →
Anthropic) or a resident local MLX model. This module owns the *provider*
concern: the caller's per-user Anthropic key (encrypted at rest exactly like
`SpheronCred`, on their OWN root so it is multi-tenant isolated), the resolved
key used by the plan worker, the provider/model catalog the client picks from,
and a tiny $/Mtok price table for the plan-cost estimate.

Never echo the key: no endpoint returns it. `llm_status` shows only a masked
tail (last 4) when the key is user-set. `resolved_anthropic_key` is internal —
it decrypts the user key, else falls back to the ANTHROPIC_API_KEY env var — and
is the single point the plaintext key exists, inside the request that spends on
it (same discipline as spheron.sv.jac `_api_key`).
"""

import os;
import datetime;
import crypto;
import models;

def _now() -> str {
    return datetime.datetime.now(datetime.UTC).replace(tzinfo=None).isoformat() + "Z";
}

# -------------------------------------------------------------- price table ----
"""Hosted-model pricing in USD per million tokens ({in, out}). Local MLX / unknown
models are free → price_for returns zeros. Estimate-only; keep in sync with the
provider's public rate card."""
glob PRICES: dict[str, dict[str, float]] = {
    "claude-sonnet-5": {"in": 3.0, "out": 15.0},
    "claude-haiku-4-5": {"in": 1.0, "out": 5.0}
};

"""{in, out} $/Mtok for *model*, or zeros for an mlx/unknown model."""
def price_for(model: str) -> dict {
    if model in PRICES {
        p = PRICES[model];
        return {"in": float(p["in"]), "out": float(p["out"])};
    }
    return {"in": 0.0, "out": 0.0};
}

# ------------------------------------------------------------------ key node ---
"""Per-user JMS provider settings. 0..1 off the caller's own root; `anthropic_key`
is encrypted at rest via crypto.encrypt (see crypto.sv.jac)."""
node JmsSettings {
    has anthropic_key: str = "",
        set_at: str = "";
}

"""The caller's JmsSettings, or None. Caller's root only (multi-tenant)."""
def _settings() -> JmsSettings | None {
    s = [root -->][?:JmsSettings];
    return s[0] if len(s) > 0 else None;
}

"""Resolve the Anthropic key: caller's stored (decrypted) key wins, else the
shared ANTHROPIC_API_KEY env var, else "". The only place the plaintext key
exists — called inside the plan request that spends on it. Never surface this
from an endpoint."""
def resolved_anthropic_key() -> str {
    s = _settings();
    if s is not None and s.anthropic_key { return str(crypto.decrypt(s.anthropic_key)); }
    return os.environ.get("ANTHROPIC_API_KEY", "");
}

"""Where the resolved key comes from: user | env | none."""
def _key_source() -> str {
    s = _settings();
    if s is not None and s.anthropic_key { return "user"; }
    if os.environ.get("ANTHROPIC_API_KEY", "") { return "env"; }
    return "none";
}

"""Masked tail (…last4) of the user-set key, or "" when not user-set. Decrypts
only to reveal the final 4 chars for the status badge — never the whole key."""
def _masked_tail() -> str {
    s = _settings();
    if s is None or not s.anthropic_key { return ""; }
    k = str(crypto.decrypt(s.anthropic_key));
    if len(k) <= 4 { return "…"; }
    return "…" + k[len(k) - 4:];
}

# ------------------------------------------------------------------ endpoints --
"""Store or replace the caller's Anthropic API key on their own root (encrypted).
Never echoes the key back. Returns {ok, source, error}."""
def set_anthropic_key(api_key: str) -> dict {
    k = api_key.strip();
    if not k { return {"ok": False, "source": _key_source(), "error": "empty key"}; }
    enc = crypto.encrypt(k);
    existing = _settings();
    if existing is not None {
        existing.anthropic_key = enc;
        existing.set_at = _now();
    } else {
        root ++> JmsSettings(anthropic_key=enc, set_at=_now());
    }
    return {"ok": True, "source": "user", "error": ""};
}

"""Delete the caller's stored key (falls back to the ANTHROPIC_API_KEY env var)."""
def clear_anthropic_key() -> dict {
    s = _settings();
    if s is not None { s.anthropic_key = ""; s.set_at = ""; }
    return {"ok": True, "source": _key_source(), "error": ""};
}

"""Provider/model catalog + credential status for the JMS key modal and plan
picker. Never returns the key itself. Shape:
{configured, source: user|env|none, masked, providers: [
  {id:"claude", label, requires_key, models:[...]},
  {id:"mlx",    label, requires_key, models:[<available local ids>]}
]}."""
def llm_status() -> dict {
    src = _key_source();
    mlx_models: list[str] = [];
    try {
        for m in models.list_models() {
            if m.available { mlx_models.append(m.id); }
        }
    } except Exception {}
    providers: list[dict] = [
        {
            "id": "claude",
            "label": "Claude (Anthropic)",
            "requires_key": True,
            "models": ["claude-sonnet-5", "claude-haiku-4-5"]
        },
        {
            "id": "mlx",
            "label": "Local (MLX)",
            "requires_key": False,
            "models": mlx_models
        }
    ];
    return {
        "configured": src != "none",
        "source": src,
        "masked": _masked_tail(),
        "providers": providers
    };
}
