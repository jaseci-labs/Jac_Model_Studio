"""studio - model registry + data-root resolution.

Ports server/config.py. models/ is gitignored and resolves against
paths.data_root() (JAC_STUDIO_DATA_ROOT / workspace). `list_models` is the
client-facing endpoint; the rest are helpers used by chat/eval/train modules.
"""

import os;
import inference;
import paths;
import workspace;
import from pathlib { Path }

# Model registry, eval holdouts, and excluded run dirs now live in
# studio.workspace.toml (workspace_root > studio_root). See workspace.sv.jac.

"""One model as the client sees it: registry entry + on-disk availability."""
obj ModelView {
    has id: str = "",
        label: str = "",
        path: str = "",
        available: bool = False,
        size_gb: float = 0.0;
}

def data_root() -> Path {
    return paths.data_root();
}

def model_by_id(model_id: str) -> dict {
    for m in workspace.model_registry() {
        if m["id"] == model_id {
            return m;
        }
    }
    return {};
}

def model_path(m: dict) -> Path {
    return data_root() / str(m["path"]);
}

def model_available(m: dict) -> bool {
    return model_path(m).is_dir();
}

def results_dir() -> Path {
    # run_probe.sh / run_dpo.sh cd to the repo root and write under
    # model-experiments/01-sft-dpo/results/, so the studio must read the same tree.
    return data_root() / "model-experiments/01-sft-dpo" / "results";
}

def jac_bin() -> Path {
    return data_root() / ".venv" / "bin" / "jac";
}

# Memoized model-dir sizes. `list_models()` backs the chat model picker AND
# jms_llm.llm_status AND assistant.assistant_providers — all UI-polled — and each
# call used to rglob + stat every file in every multi-GB model dir. Key = the model
# directory's own absolute path + st_mtime_ns, as specified. Model dirs are
# immutable downloads: files land, the dir mtime bumps, and nothing touches them
# again. CAVEAT: a directory's mtime only tracks its DIRECT entries, so rewriting
# an existing nested file in place (without adding/removing a direct child) would
# not invalidate this entry. That does not happen for a downloaded model snapshot;
# if it ever does, restart the server.
glob _SIZE_CACHE: dict[str, float] = {};
glob _SIZE_CAP: int = 128;

"""On-disk size of a model dir in GB (2 dp), memoized on (dir path, dir mtime_ns).
round(x,2) is broken in the checker, so the cents are computed with int division."""
def dir_size_gb(p: Path) -> float {
    if not p.is_dir() { return 0.0; }
    key = "";
    try {
        key = str(p) + "|" + str(p.stat().st_mtime_ns);
    } except Exception { key = ""; }
    if key {
        hit = _SIZE_CACHE.get(key);
        if hit is not None { return float(hit); }
    }
    total = 0;
    for f in p.rglob("*") {
        if f.is_file() { total += f.stat().st_size; }
    }
    gb = int(total / 10_000_000) / 100.0;
    if key {
        if len(_SIZE_CACHE) > _SIZE_CAP { _SIZE_CACHE.clear(); }
        _SIZE_CACHE[key] = gb;
    }
    return gb;
}

def total_ram_gb() -> int {
    return round(os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE") / 1024 ** 3);
}

"""Total system RAM in GB — the sidebar memory gauge."""
def system_ram() -> int {
    return total_ram_gb();
}

"""The model registry with live on-disk availability + size — the chat model picker."""
def list_models() -> list[ModelView] {
    out: list[ModelView] = [];
    for m in workspace.model_registry() {
        avail = model_available(m);
        out.append(
            ModelView(
                id=str(m["id"]),
                label=str(m["label"]),
                path=str(m["path"]),
                available=avail,
                size_gb=dir_size_gb(model_path(m)) if avail else 0.0
            )
        );
    }
    return out;
}

"""The currently-resident model plus process fd health:
{id, resident_gb, fd_boot_limit, fd_soft, fd_hard, fd_target, fd_guard}. Drives the
model-pill LOADED badge and the sidebar MEM gauge. Empty id + 0.0 when nothing
is loaded.

The fd_* keys expose the open-file ceiling this process actually achieved at
boot (see inference._fd_info) so the fd-exhaustion fix is verifiable from the
API instead of needing `lsof` on the live pid. Additive only — id/resident_gb
are unchanged for existing callers."""
def loaded_model() -> dict {
    return inference.loaded_info();
}

"""Eagerly load (warm) a model so the next completion streams immediately. Blocks
until resident; the client shows elapsed via its own timer. Returns
{id, load_s, error} — error is "" on success, a message otherwise."""
def warm_model(model_id: str) -> dict {
    m = model_by_id(model_id);
    if not m {
        return {"id": model_id, "load_s": 0.0, "error": f"unknown model_id: {model_id}"};
    }
    if not model_available(m) {
        return {"id": model_id, "load_s": 0.0, "error": f"model not found on disk: {model_id}"};
    }
    # load_sync raises on a genuinely failed load (e.g. OSError [Errno 24] Too
    # many open files) and on model-lock timeout. Honour this function's stated
    # {id, load_s, error} contract instead of letting it escape as a 500 — a
    # failed warm must degrade to an error message for THIS request only.
    try {
        s = inference.load_sync(model_id, str(model_path(m)));
    } except Exception as e {
        return {"id": model_id, "load_s": 0.0, "error": str(e)};
    }
    return {"id": model_id, "load_s": s, "error": ""};
}
