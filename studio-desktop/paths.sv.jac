"""studio - canonical path resolution.

Single source of truth for studio_root, workspace_root, data_root, and jacgen
script paths. Overrides via JAC_STUDIO_WORKSPACE and JAC_STUDIO_DATA_ROOT; without
them both default to the parent of studio-desktop when 01-sft-dpo exists there
(jac_ml_studio repo layout).
"""

import os;
import from pathlib { Path }

glob JACGEN_REL: str = "01-sft-dpo/sft_dpo/jacgen";
glob _WORKSPACE_MARKER: str = "01-sft-dpo";

def studio_root() -> Path {
    return Path(os.path.dirname(os.path.abspath(__file__)));
}

def workspace_root() -> Path {
    env = os.environ.get("JAC_STUDIO_WORKSPACE", "");
    if env {
        return Path(env);
    }
    candidate = studio_root().parent;
    if (candidate / _WORKSPACE_MARKER).is_dir() {
        return candidate;
    }
    dr = os.environ.get("JAC_STUDIO_DATA_ROOT", "");
    if dr {
        return Path(dr);
    }
    return candidate;
}

def data_root() -> Path {
    env = os.environ.get("JAC_STUDIO_DATA_ROOT", "");
    if env {
        return Path(env);
    }
    return workspace_root();
}

def resolve(rel: str, scope: str = "workspace") -> Path {
    if scope == "data" {
        return data_root() / rel;
    }
    if scope == "studio" {
        return studio_root() / rel;
    }
    return workspace_root() / rel;
}

"""Relative path to a jacgen script (e.g. eval_probe.jac)."""
def jacgen_script(name: str) -> str {
    script = name if name.endswith(".jac") else f"{name}.jac";
    return f"{JACGEN_REL}/{script}";
}

"""Relative path to a jacgen builder stage (stage name without .jac)."""
def jacgen_stage(stage: str) -> str {
    return jacgen_script(stage);
}
