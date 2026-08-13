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
import importlib;

glob _S: dict = {
    "model": None,
    "tokenizer": None,
    "current_id": "",
    "load_seconds": 0.0,
    "lock": threading.Lock(),
};

"""Open-file headroom. The `jac start --dev` file watcher holds ~17.5k fds at
idle (see _raise_fd_limit for the measurement), so any soft limit under ~32k
leaves no room for a model load. macOS refuses setrlimit above
`kern.maxfilesperproc` (184320 on this box) and a finite hard limit caps us too,
so we walk this ladder and keep the first value that actually sticks."""
glob _FD_TARGET: int = 65536;
glob _FD_LADDER: list = [184320, 131072, 65536, 32768];

"""Bound on how long one request will wait for the single model lock.

Waiting forever is what turns ONE wedged request into a dead server: every queued
chat/warm request parks a worker thread on the lock, the server's thread pool
drains, and endpoints that never touch a model (list_chats, system_ram, ...)
start failing too. Time out and return a clean error instead. Generous because a
cold load of a large model legitimately takes minutes."""
glob _LOCK_TIMEOUT_S: float = 600.0;

def _now() -> float { return time.monotonic(); }

def _elapsed(t0: float) -> float { return time.monotonic() - t0; }

"""Raise this process's soft open-file limit toward the hard cap.

MEASURED ROOT CAUSE (live dev server, PID 28219, 2026-08-04). `jac start --dev`
makes jaclang schedule a watchdog observer over the WHOLE project —
`JacFileWatcher(watch_paths=[base])`, recursive, with NO ignore list
(jaclang/cli/commands/impl/execution.impl.jac). On macOS watchdog uses its
**kqueue** backend, which needs one open fd per watched file AND directory.
`lsof` on the live server: 17,481 fds at idle, 11,113 of them inside
`.jac/client/node_modules` (es-toolkit alone 3,976; @babel 1,144; recharts 910).
That is the app's fd floor before it serves a single request. A model load
(safetensors shards + tokenizer) then needs thousands more, and a process that
inherited a low soft limit (launchd's default is 256 — `launchctl limit maxfiles`)
dies with `[Errno 24] Too many open files`.

This is a CEILING RAISE, not a leak fix: the fds belong to jaclang's watcher and
this app cannot configure them away (`watch_paths` is hardcoded upstream, and the
Vite `server.watch.ignored` list in jac.toml is irrelevant — the Vite child
process holds only ~50 fds total; the leak is entirely on the Python side).
The durable mitigation is the `ulimit -n` in start.sh, which applies BEFORE the
process and its watcher exist. This in-process raise is the fallback for launches
that bypass start.sh.

A process may raise its own soft limit up to the hard limit without privileges.
macOS additionally refuses any value above `kern.maxfilesperproc`, so rather than
one fixed request (the old code asked for a flat 200000 and swallowed the failure
in a bare `except`) we walk a descending ladder and keep the first value that
sticks. Returns the effective soft limit; warns loudly instead of failing silent.
Never raises."""
def _raise_fd_limit() -> int {
    try {
        cur: any = resource.getrlimit(resource.RLIMIT_NOFILE);
        soft: any = cur[0];
        hard: any = cur[1];
    } except Exception as e {
        sys.stderr.write(f"[inference] WARNING: cannot read RLIMIT_NOFILE: {e}\n");
        return 0;
    }
    if soft >= _FD_TARGET {
        return int(soft);
    }
    for want in _FD_LADDER {
        if want <= soft {
            break;
        }
        if hard != resource.RLIM_INFINITY and want > hard {
            continue;
        }
        try {
            resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard));
            return int(want);
        } except Exception {
            continue;
        }
    }
    # Last resort: every ladder rung was above this process's hard limit, so take
    # the hard limit itself. Without this the function returns the ORIGINAL soft
    # limit while leaving free headroom on the table — e.g. a process stuck at
    # soft=2048/hard=4096 (see the mlx_lm clamp documented below) would keep 2048
    # even though 4096 is available for the asking.
    if hard != resource.RLIM_INFINITY and hard > soft {
        try {
            resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard));
            sys.stderr.write(
                f"[inference] WARNING: open-file soft limit raised only to the hard cap {hard}, below the {_FD_TARGET} this app needs. Something lowered this process's HARD limit (mlx_lm does exactly that — see _install_fd_guard); an unprivileged process cannot raise it back. Large model loads may fail with [Errno 24] Too many open files.\n"
            );
            return int(hard);
        } except Exception {}
    }
    sys.stderr.write(
        f"[inference] WARNING: open-file soft limit is {soft}, below the {_FD_TARGET} this app needs (the jac --dev file watcher alone holds ~17.5k fds). Local model loads will likely fail with [Errno 24] Too many open files. Raise it before launch: `ulimit -n 65536` (start.sh does this).\n"
    );
    return int(soft);
}

"""The real `resource.setrlimit`, captured before we shadow it below."""
glob _ORIG_SETRLIMIT: any = resource.setrlimit;

"""max() over rlimit values, treating RLIM_INFINITY as the largest. A plain
`max()` is wrong: RLIM_INFINITY is a sentinel, not a magnitude (it is -1 on
Linux), so it has to be tested for identity rather than compared."""
def _rlim_max(a: any, b: any) -> any {
    if a == resource.RLIM_INFINITY or b == resource.RLIM_INFINITY {
        return resource.RLIM_INFINITY;
    }
    return a if a > b else b;
}

"""Monotonic RLIMIT_NOFILE: a request may raise the ceiling, never lower it.

Merges the caller's (soft, hard) with the values already in force and keeps the
maximum of each, so a genuine raise still goes through untouched while a
lowering request degrades to a no-op. Non-NOFILE resources are passed straight
to the real setrlimit — this is a targeted guard, not a general veto. Exceptions
still propagate (the ladder in _raise_fd_limit depends on setrlimit raising when
a value is refused)."""
def _guarded_setrlimit(res: any, limits: any) {
    if res != resource.RLIMIT_NOFILE {
        _ORIG_SETRLIMIT(res, limits);
        return;
    }
    cur: any = resource.getrlimit(res);
    _ORIG_SETRLIMIT(
        res, (_rlim_max(cur[0], limits[0]), _rlim_max(cur[1], limits[1]))
    );
}

"""Install the monotonic guard. Returns True if RLIMIT_NOFILE is now protected.

MEASURED ROOT CAUSE #2 (2026-08-10). loaded_model() reported fd_boot_limit=65536
but fd_soft=2048 / fd_hard=4096 live, on a server that start_prod.sh had booted
with `ulimit -S -n 65536` (soft=65536 hard=unlimited, confirmed in the boot log).
Nothing forks or re-execs — the drop happens IN this process, at line 36 of
`mlx_lm/utils.py` (mlx_lm 0.31.3), which runs unconditionally at import:

    # For large models with lots of files
    resource.setrlimit(resource.RLIMIT_NOFILE, (2048, 4096))

Upstream means it as a RAISE — macOS hands launchd children a soft limit of 256
— but it is written as an unconditional SET, so any process that already raised
its own ceiling gets silently DOWNGRADED the first time anything touches mlx_lm.
That is the exact gap between fd_boot_limit (measured at this module's import,
before mlx) and fd_soft (measured live, after some request pulled mlx_lm in).

The damage cannot be undone after the fact: the clamp also drops the HARD limit
from unlimited to 4096, and an unprivileged process may only ever LOWER a hard
limit — re-raising fails with `ValueError: not allowed to raise maximum limit`
(verified on this box). So _raise_fd_limit() cannot repair it; the write has to
be intercepted before it lands.

Hence a `glob` initializer, ordered BEFORE _FD_BOOT_LIMIT and therefore before
any body-level `import from mlx_lm` in this module — the guard is in place from
server boot, and mlx_lm's clamp becomes a no-op here while still working
normally on a genuinely 256-limited process. Never raises: a failure to install
leaves the pre-existing behaviour, which is what we had before."""
def _install_fd_guard() -> bool {
    try {
        if getattr(resource.setrlimit, "__name__", "") == "_guarded_setrlimit" {
            return True;
        }
        resource.setrlimit = _guarded_setrlimit;
        return True;
    } except Exception as e {
        sys.stderr.write(
            f"[inference] WARNING: could not guard resource.setrlimit ({e}); importing mlx_lm will clamp this process to soft=2048/hard=4096 and large model loads may fail with [Errno 24] Too many open files.\n"
        );
        return False;
    }
}

glob _FD_GUARD_OK: bool = _install_fd_guard();

"""Raise the fd ceiling ONCE at import (server boot), not only lazily before each
model load. The old code called _raise_fd_limit() solely from inside the load
paths — i.e. after boot had already spent the fd budget, by which point a starved
process fails on ANY open, not just the model's.

Done as a `glob` initializer rather than a `with entry` block on purpose: a glob
initializer is the same import-time mechanism `_S` above already relies on (it
calls threading.Lock() at import), so it needs no construct this server module
hasn't already proven. Also keeps the effective limit around for diagnostics."""
glob _FD_BOOT_LIMIT: int = _raise_fd_limit();

"""Residency key: the plain model_id when no adapter (so the base-model chat
residency used by Experiments Chat is untouched — empty adapter_path behaves
exactly as before), else model_id+"+"+adapter_path so an adapter-backed JMS chat
keys separately and switching between the two doesn't needlessly reload."""
def _reskey(model_id: str, adapter_path: str) -> str {
    return model_id if not adapter_path else model_id + "+" + adapter_path;
}

"""mlx_lm.load with an optional LoRA adapter (adapter_path="" → base only). Kept
in one place so both load paths pass the adapter identically. importlib
indirection (not `import from mlx_lm { load }` + a direct kwarg call) — the
adapter_path kwarg crashes the 0.16.1 checker's overload resolution, exactly as
scripts/jms_gen_worker.jac documents. Returns (model, tokenizer)."""
def _mlx_load(path: str, adapter_path: str) -> any {
    mod: any = importlib.import_module("mlx_lm");
    if adapter_path {
        return mod.load(path, adapter_path=adapter_path);
    }
    return mod.load(path);
}

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

"""Repair residency bookkeeping after a failed load. Call with the lock HELD.

If `_mlx_load` raises partway (e.g. OSError EMFILE from fd exhaustion), `_S` can
be left claiming a resident model whose `model`/`tokenizer` are missing — and the
next request would then happily "reuse" a None model and fail in a much more
confusing place. Deliberately does NOT unload a *healthy* resident model: a
mid-generation error (bad prompt, cancelled stream) must not cost a multi-minute
reload of a 30GB model. It only clears state that is already inconsistent."""
def _reconcile_locked() {
    if _S["model"] is None or _S["tokenizer"] is None {
        _S["current_id"] = "";
        _S["load_seconds"] = 0.0;
    }
}

"""Blocking load. Returns seconds spent (0.0 if already resident). Unloads any
prior model first — only one fits in 48GB. Used by the standalone warm path.
`adapter_path` (default "") loads a LoRA adapter on top of the base and keys the
residency separately — the empty-adapter path is byte-identical to before."""
def load_sync(model_id: str, path: str, adapter_path: str = "") -> float {
    # Bounded wait: an unbounded acquire() parks this worker thread forever if the
    # lock was ever leaked, which is how one bad request takes the whole server down.
    if not _S["lock"].acquire(timeout=_LOCK_TIMEOUT_S) {
        raise RuntimeError("model is busy: timed out waiting for the model lock");
    }
    try {
        _raise_fd_limit();
        key = _reskey(model_id, adapter_path);
        if _S["current_id"] == key {
            _S["load_seconds"] = 0.0;
            return 0.0;
        }
        if _S["current_id"] {
            _unload_locked();
        }
        t0 = _now();
        loaded: any = _mlx_load(path, adapter_path);
        _S["model"] = loaded[0];
        _S["tokenizer"] = loaded[1];
        _S["load_seconds"] = _elapsed(t0);
        _S["current_id"] = key;
        return _S["load_seconds"] as float;
    } except Exception as e {
        _reconcile_locked();
        raise e;
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

"""The fd-ceiling diagnostics, for the status payload below.

`_FD_BOOT_LIMIT` was previously computed at import and then thrown away —
verifying that the boot-time raise actually stuck meant running `lsof` against
the live pid. These three numbers make it answerable from the API instead:

- fd_boot_limit: what _raise_fd_limit() achieved at import (server boot).
- fd_soft / fd_hard: RLIMIT_NOFILE *right now*. fd_soft normally equals
  fd_boot_limit; a lower value means something dropped the limit after boot.
  fd_hard is the ceiling this process could still raise itself to, and is
  reported as -1 when it is RLIM_INFINITY (which is not JSON-representable).
- fd_target: the headroom this app wants; fd_soft below it is the warning state.
- fd_guard: whether the monotonic setrlimit guard installed (see
  _install_fd_guard). False means mlx_lm's import-time clamp is live and
  fd_soft/fd_hard will collapse to 2048/4096 on the first model touch.

fd_soft < fd_boot_limit used to be an unexplained mystery; it is now a concrete
assertion that the guard is missing or was installed too late.

Deliberately NOT a live open-fd count: there is no portable cheap probe.
`/proc/self/fd` is Linux-only (this is a macOS box) and walking `/dev/fd` would
stat ~17.5k watcher fds on every poll of a status endpoint. Limits are one
syscall. Never raises — diagnostics must not be able to break the status call."""
def _fd_info() -> dict {
    try {
        cur: any = resource.getrlimit(resource.RLIMIT_NOFILE);
        soft = int(cur[0]);
        hard = -1 if cur[1] == resource.RLIM_INFINITY else int(cur[1]);
    } except Exception {
        soft = 0;
        hard = 0;
    }
    return {
        "fd_boot_limit": _FD_BOOT_LIMIT,
        "fd_soft": soft,
        "fd_hard": hard,
        "fd_target": _FD_TARGET,
        "fd_guard": _FD_GUARD_OK
    };
}

"""Currently-resident model id + a ROUGH resident memory estimate in GB, plus
the fd-ceiling diagnostics (see _fd_info).

There is no cheap, exact "bytes this model occupies" probe, so we approximate
with the process peak RSS (ru_maxrss) — on a single-resident-model box that is
dominated by the loaded weights. Hundredths-of-GB via int div (round(x,2) is
broken in the checker). Returns 0.0 when nothing is loaded.

The fd keys are ADDITIVE — `id` and `resident_gb` keep their names, types and
meaning, so existing clients that destructure just those two are unaffected."""
def loaded_info() -> dict {
    out: dict = _fd_info();
    if not _S["current_id"] {
        out["id"] = "";
        out["resident_gb"] = 0.0;
        return out;
    }
    ru: any = resource.getrusage(resource.RUSAGE_SELF);
    rss = float(str(ru.ru_maxrss));
    out["id"] = _S["current_id"];
    out["resident_gb"] = _rss_to_gb(rss);
    return out;
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
    temperature: float, top_p: float, max_tokens: int, adapter_path: str = ""
) -> any {
    # Bounded wait — see load_sync. Yielding a clean error frame beats parking a
    # worker thread on the lock forever.
    if not _S["lock"].acquire(timeout=_LOCK_TIMEOUT_S) {
        yield {
            "kind": "error",
            "text": "model is busy: timed out waiting for the model lock"
        };
        return;
    }
    held = True;
    try {
        _raise_fd_limit();
        import from mlx_lm { stream_generate }
        import from mlx_lm.sample_utils { make_sampler }
        load_s = 0.0;
        key = _reskey(model_id, adapter_path);
        if _S["current_id"] != key {
            if _S["current_id"] { _unload_locked(); }
            t0 = _now();
            loaded: any = _mlx_load(path, adapter_path);
            _S["model"] = loaded[0];
            _S["tokenizer"] = loaded[1];
            load_s = _elapsed(t0);
            _S["current_id"] = key;
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
        # Release BEFORE yielding the terminal error frame. This generator holds
        # the lock across every yield, so if we yielded first and the consumer
        # stopped iterating on seeing the error (the natural thing to do), the
        # generator would stay SUSPENDED right here with the lock still held —
        # released only whenever GC got around to it. Every later model request
        # would queue behind it. Releasing first makes the error path safe no
        # matter what the consumer does with the frame.
        _reconcile_locked();
        _S["lock"].release();
        held = False;
        yield {"kind": "error", "text": str(e)};
    } finally {
        # GeneratorExit (client disconnect) is a BaseException, so it skips the
        # except block above and lands here with the lock still held — release it.
        if held {
            _S["lock"].release();
        }
    }
}
