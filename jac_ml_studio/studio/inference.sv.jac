"""studio - single resident MLX model + token stream.

Ports server/model_manager.py + server/generate.py. 48GB box: exactly one model
in memory. Swap = drop refs + gc + mx.clear_cache(), then mlx_lm.load() the new
one. mlx imports are lazy (inside bodies) so server boot stays mlx-free until the
first load. Module globals hold the resident model; a threading.Lock serializes
load/generation (one at a time). Named `inference` (not `mlx`) to avoid shadowing
the real `mlx` python package.
"""

import gc;
import time;
import threading;

glob _model: any = None;
glob _tokenizer: any = None;
glob _current_id: str = "";
glob _load_seconds: float = 0.0;
glob _lock: any = threading.Lock();

def _unload_locked() -> None {
    global _model, _tokenizer, _current_id;
    _model = None;
    _tokenizer = None;
    _current_id = "";
    gc.collect();
    try {
        import mlx.core;
        mlx.core.clear_cache();
    } except Exception {}
}

"""Blocking load. Returns seconds spent (0.0 if already resident). Unloads any
prior model first — only one fits in 48GB."""
def load_sync(model_id: str, path: str) -> float {
    global _model, _tokenizer, _current_id, _load_seconds;
    with _lock {
        if _current_id == model_id {
            _load_seconds = 0.0;
            return 0.0;
        }
        if _current_id {
            _unload_locked();
        }
        import mlx_lm;
        t0 = time.monotonic();
        (_model, _tokenizer) = mlx_lm.load(path);
        _load_seconds = round(time.monotonic() - t0, 1);
        _current_id = model_id;
        return _load_seconds;
    }
}

def current_id() -> str {
    return _current_id;
}

def _build_prompt(messages: list[dict]) -> any {
    return _tokenizer.apply_chat_template(messages, add_generation_prompt=True);
}

"""Token stream for the resident model. Yields a dict per token: the new `text`
chunk plus running `tokens`/`tps`. Holds `_lock` for the whole generation so a
concurrent load can't swap the model mid-stream."""
def stream_tokens(
    messages: list[dict], temperature: float, top_p: float, max_tokens: int
) -> any {
    import mlx_lm;
    import mlx_lm.sample_utils;
    with _lock {
        sampler = mlx_lm.sample_utils.make_sampler(temp=temperature, top_p=top_p);
        ptoks = _build_prompt(messages);
        # Hoist the native generator into a local before iterating — a yield over
        # an inline native call crashes the type checker (jaclang 0.16.1).
        gen: any = mlx_lm.stream_generate(
            _model, _tokenizer, ptoks, max_tokens=max_tokens, sampler=sampler
        );
        for resp in gen {
            # Extract native attrs into locals before yielding — referencing them
            # inline in the yielded dict crashes the type checker (jaclang 0.16.1).
            txt: str = str(resp.text);
            ntok: any = resp.generation_tokens;
            ntps: any = resp.generation_tps;
            yield {"text": txt, "tokens": ntok, "tps": ntps};
        }
    }
}
