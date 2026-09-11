"""studio - canonical path resolution (single source of truth).

Three roots, all defaulting to the repo root so the app is self-contained:

- studio_root()    — this directory (code, prompts.json, remote/, scripts/).
- workspace_root() — base for the RELATIVE paths in studio.workspace.toml (model
                     dirs, dataset files). `JAC_STUDIO_WORKSPACE` overrides;
                     default = studio_root(). The toml is the ONLY place that
                     names external artifacts (e.g. ../model-experiments/...).
- data_root()      — everything JMS WRITES at runtime: results/, audit/,
                     projects/, examples/. `JAC_STUDIO_DATA_ROOT` overrides;
                     default = <studio_root>/data (gitignored).
"""

import os;
import sys;
import shutil;
import from pathlib { Path }

def studio_root() -> Path {
    return Path(os.path.dirname(os.path.abspath(__file__)));
}

def workspace_root() -> Path {
    env = os.environ.get("JAC_STUDIO_WORKSPACE", "");
    return Path(env) if env else studio_root();
}

def data_root() -> Path {
    env = os.environ.get("JAC_STUDIO_DATA_ROOT", "");
    return Path(env) if env else studio_root() / "data";
}

"""Shared results tree: per-user runs (users/<uid>/), the GPU heavy lock."""
def results_dir() -> Path {
    return data_root() / "results";
}

def audit_dir() -> Path {
    return data_root() / "audit";
}

"""JMS project homes: <data_root>/projects/<slug>/."""
def projects_dir() -> Path {
    return data_root() / "projects";
}

"""Resolve a path from studio.workspace.toml (relative to workspace_root, or
absolute as-is). scope "data" / "studio" pick the other roots."""
def resolve(rel: str, scope: str = "workspace") -> Path {
    if scope == "data" {
        return data_root() / rel;
    }
    if scope == "studio" {
        return studio_root() / rel;
    }
    return workspace_root() / rel;
}

"""Optional fallback: a `.venv/bin` in the repo root. Never required — only
used when it exists."""
def _legacy_venv_bin() -> Path {
    return studio_root() / ".venv" / "bin";
}

"""The `jac` executable for spawning workers: next to the running interpreter,
else on PATH, else the repo-root `.venv` if present. "" if none found."""
def jac_bin() -> str {
    cand = Path(sys.executable).parent / "jac";
    if cand.exists() { return str(cand); }
    w = shutil.which("jac");
    if w { return str(w); }
    lv = _legacy_venv_bin() / "jac";
    return str(lv) if lv.exists() else "";
}

"""PATH for detached tool subprocesses (mlx_lm.lora etc.): the running
interpreter's bin dir first, then the inherited PATH, then the repo-root
`.venv/bin` as a last-resort fallback when it exists."""
def tool_path() -> str {
    parts: list[str] = [str(Path(sys.executable).parent)];
    cur = os.environ.get("PATH", "");
    if cur { parts.append(cur); }
    lv = _legacy_venv_bin();
    if lv.is_dir() { parts.append(str(lv)); }
    return ":".join(parts);
}
