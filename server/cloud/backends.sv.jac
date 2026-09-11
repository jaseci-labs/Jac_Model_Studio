"""studio - training backend registry.

Declarative job specs are rendered into detached-process launch plans
(cmd, cwd, env) by per-backend templates in studio.workspace.toml.

Job spec shape (dict):
  backend: str   optional — defaults to [backends].default
  method:  str   required — sft | dpo
  vars:    dict  template placeholders (run_name, model_id, config_file, …)
  opts:    dict  env-var overrides (filtered by the method's env_keys)

The consumer (cloudruns.sv.jac) builds a spec and calls render(); it keeps
ownership of job files, log paths, and resume logic — this module only knows how
to turn a spec into a shell command.
"""

import os;
import from server.core { jobs }
import from server.core { paths }
import from server.core { workspace }
import from pathlib { Path }

"""Resolve a cwd scope string to an absolute Path."""
def _cwd_for(scope: str) -> Path {
    if scope == "data" { return paths.data_root(); }
    if scope == "studio" { return paths.studio_root(); }
    return paths.workspace_root();
}

"""Substitute {placeholders} in *template* from *tpl_vars*. A placeholder with no
matching key is left VERBATIM in the output — callers must supply every var their
backend's template names."""
def _apply_template(template: str, tpl_vars: dict) -> str {
    out = template;
    for k in tpl_vars {
        key = str(k);
        out = out.replace("{" + key + "}", str(tpl_vars[k]));
    }
    return out;
}

"""Env keys for *method* — method env_keys, else train.sft_keys/dpo_keys."""
def _env_keys(method: str, method_cfg: dict) -> list[str] {
    raw = method_cfg.get("env_keys");
    if isinstance(raw, list) {
        return [str(x) for x in (raw as list)];
    }
    if method == "sft" { return workspace.sft_keys(); }
    if method == "dpo" { return workspace.dpo_keys(); }
    return [];
}

"""Method table for one backend (method keys only — skip label/description)."""
def _methods(backend_cfg: dict) -> dict {
    out: dict = {};
    for k in backend_cfg {
        if k in ["label", "description", "cwd_default"] { continue; }
        v = backend_cfg[k];
        if isinstance(v, dict) { out[str(k)] = dict(v); }
    }
    return out;
}

"""Render a job spec into {cmd, cwd, env, backend, method, ignored_opts}."""
def render(spec: dict) -> dict {
    backend_name = str(spec.get("backend", workspace.training_backend_default()));
    method = str(spec.get("method", ""));
    if not method { raise ValueError("job spec missing method"); }

    backend_cfg = workspace.training_backend(backend_name);
    if not backend_cfg {
        raise ValueError("unknown backend: " + backend_name);
    }
    methods = _methods(backend_cfg);
    if method not in methods {
        raise ValueError("backend " + backend_name + " has no method " + method);
    }
    method_cfg: dict = dict(methods[method]);
    template = str(method_cfg.get("template", ""));
    if not template {
        raise ValueError("no template for " + backend_name + "." + method);
    }

    tpl_vars: dict = {};
    raw_vars = spec.get("vars");
    if isinstance(raw_vars, dict) { tpl_vars = dict(raw_vars); }

    opts: dict = {};
    raw_opts = spec.get("opts");
    if isinstance(raw_opts, dict) { opts = dict(raw_opts); }

    keys = _env_keys(method, method_cfg);
    env_overrides: dict = {};
    for k in keys {
        if k in opts {
            val = str(opts[k]);
            if jobs.safe(val) { env_overrides[k] = val; }
        }
    }
    ignored: list[str] = [str(k) for k in opts if str(k) not in keys];

    cwd_default = str(backend_cfg.get("cwd_default", "data"));
    cwd_from_method = method_cfg.get("cwd", cwd_default);
    cwd_scope = str(spec.get("cwd_scope", cwd_from_method));
    cwd = _cwd_for(cwd_scope);

    venv_bin = str(cwd / ".venv" / "bin");
    if (cwd / ".venv" / "bin").is_dir() {
        env_overrides["PATH"] = f"{venv_bin}:{os.environ.get('PATH', '')}";
    }

    cmd = _apply_template(template, tpl_vars);
    return {
        "cmd": cmd,
        "cwd": str(cwd),
        "cwd_scope": cwd_scope,
        "env": env_overrides,
        "backend": backend_name,
        "method": method,
        "ignored_opts": ignored
    };
}
