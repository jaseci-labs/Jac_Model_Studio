"""studio - single resident MLX model + token stream.

Ports server/model_manager.py + server/generate.py. 48GB box: exactly one model
in memory. Swap = drop refs + gc + mx.clear_cache(), then mlx_lm.load() the new
one. mlx imports are lazy (inside bodies) so server boot stays mlx-free until the
first load. A threading.Lock serializes load+generation so a concurrent request
can never swap the model mid-request (matches the old single-lock-across-request
design in app.py).

State shape: all resident-model state lives in ONE module-level `glob` dict
(`_S`). We mutate entries (`_S["model"] = ...`) rather than rebinding module
names, so NO `global` declaration is needed — and crucially the desktop app's
embedded Jac engine rejects the Python-style `global` statement, which broke the
desktop boot. Mutation needs no `global` on any engine version.

Checker notes (jaclang 0.16.1): native mlx submodules are `Unknown`, so import the
symbols directly and keep handles in `any` locals. `with _lock {}` rejects an
`any` context manager → acquire/release explicitly. `round(x, 1)` has no resolvable
overload and ANY `any`-typed local poisons arithmetic in the same function, so
elapsed time is computed in helpers with no `any` locals and rounded client-side.
"""

import gc;
import sys;
import time;
import threading;
import resource;

glob _S: dict = {
    "model": None,
    "tokenizer": None,
    "current_id": "",
    "load_seconds": 0.0,
    "lock": threading.Lock(),
};

def _now() -> float { return time.monotonic(); }

def _elapsed(t0: float) -> float { return time.monotonic() - t0; }

def _unload_locked() {
    _S["model"] = None;
    _S["tokenizer"] = None;
    _S["current_id"] = "";
    gc.collect();
    try {
        import from mlx.core { clear_cache }
        clear_cache();
    } except Exception {}
}

"""Blocking load. Returns seconds spent (0.0 if already resident). Unloads any
prior model first — only one fits in 48GB. Used by the standalone warm path."""
def load_sync(model_id: str, path: str) -> float {
    _S["lock"].acquire();
    try {
        if _S["current_id"] == model_id {
            _S["load_seconds"] = 0.0;
            return 0.0;
        }
        if _S["current_id"] {
            _unload_locked();
        }
        import from mlx_lm { load }
        t0 = _now();
        loaded: any = load(path);
        _S["model"] = loaded[0];
        _S["tokenizer"] = loaded[1];
        _S["load_seconds"] = _elapsed(t0);
        _S["current_id"] = model_id;
        return _S["load_seconds"] as float;
    } finally {
        _S["lock"].release();
    }
}

def current_id() -> str { return _S["current_id"] as str; }

"""Peak RSS → GB. ru_maxrss is bytes on macOS, kilobytes on Linux."""
def _rss_to_gb(rss: float) -> float {
    bytes_val = rss if sys.platform == "darwin" else rss * 1024.0;
    return int(bytes_val / 10_000_000.0) / 100.0;
}

"""Currently-resident model id + a ROUGH resident memory estimate in GB.

There is no cheap, exact "bytes this model occupies" probe, so we approximate
with the process peak RSS (ru_maxrss) — on a single-resident-model box that is
dominated by the loaded weights. Hundredths-of-GB via int div (round(x,2) is
broken in the checker). Returns 0.0 when nothing is loaded."""
def loaded_info() -> dict {
    if not _S["current_id"] {
        return {"id": "", "resident_gb": 0.0};
    }
    ru: any = resource.getrusage(resource.RUSAGE_SELF);
    rss = float(str(ru.ru_maxrss));
    return {"id": _S["current_id"], "resident_gb": _rss_to_gb(rss)};
}

def _build_prompt(messages: list[dict]) -> any {
    return _S["tokenizer"].apply_chat_template(messages, add_generation_prompt=True);
}

"""Stream a chat completion: loads the requested model if needed, then yields one
frame per token, holding the lock across the WHOLE load+generate so a concurrent
request can't swap the resident model mid-stream. Any failure surfaces as an
`{kind:"error"}` frame instead of crashing the generator.

Frames: {kind:"load",load_s,model_id} once, {kind:"token",token,text} per token,
{kind:"done",text,tokens,tps,load_s,gen_s} last, {kind:"error",text} on failure."""
def stream_chat(
    messages: list[dict], model_id: str, path: str,
    temperature: float, top_p: float, max_tokens: int
) -> any {
    _S["lock"].acquire();
    try {
        import from mlx_lm { load, stream_generate }
        import from mlx_lm.sample_utils { make_sampler }
        load_s = 0.0;
        if _S["current_id"] != model_id {
            if _S["current_id"] { _unload_locked(); }
            t0 = _now();
            loaded: any = load(path);
            _S["model"] = loaded[0];
            _S["tokenizer"] = loaded[1];
            load_s = _elapsed(t0);
            _S["current_id"] = model_id;
            _S["load_seconds"] = load_s;
        }
        yield {"kind": "load", "load_s": load_s, "model_id": model_id};
        sampler = make_sampler(temp=temperature, top_p=top_p);
        ptoks = _build_prompt(messages);
        gt0 = _now();
        # Hoist the native generator into a local before iterating — a yield over
        # an inline native call crashes the type checker (jaclang 0.16.1).
        gen: any = stream_generate(
            _S["model"], _S["tokenizer"], ptoks, max_tokens=max_tokens, sampler=sampler
        );
        acc = "";
        ntok: any = 0;
        ntps: any = 0.0;
        for resp in gen {
            # Extract native attrs into locals before yielding (checker crash).
            txt: str = str(resp.text);
            ntok = resp.generation_tokens;
            ntps = resp.generation_tps;
            acc += txt;
            yield {"kind": "token", "token": txt, "text": acc};
        }
        yield {
            "kind": "done", "text": acc, "tokens": ntok, "tps": ntps,
            "load_s": load_s, "gen_s": _elapsed(gt0)
        };
    } except Exception as e {
        yield {"kind": "error", "text": str(e)};
    } finally {
        _S["lock"].release();
    }
}
