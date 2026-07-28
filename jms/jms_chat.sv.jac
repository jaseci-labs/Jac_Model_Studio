"""studio - JMS CHAT: stream a chat completion from a trained adapter (SSE).

Closes the JMS loop's chat half: talk to the LoRA adapter a project trained. This
is the exact frame protocol of chat.sv.jac `chat_stream` (so the client's SSE
fetch reader is reused verbatim) — it just resolves the base-model path + the
run's adapter_path and threads the adapter through inference.stream_chat, which
keys the resident model as `base+adapter` (see inference._reskey) so an
adapter-backed chat never evicts the Experiments Chat base-model residency.

RESOLUTION IS FROM DISK, not the graph. This is a generator/SSE endpoint, and the
jaclang streaming runtime does NOT bind the caller's root inside the generator
body (`[root -->]` sees the system root, not the user's) — every other SSE
endpoint here (chat_stream) only ever touches the GLOBAL model registry, never
per-user graph, so this is the first to hit it. Instead we scan the workspace's
jms-projects/*/project.json for the pid (a 12-hex uuid — an effectively
unguessable capability token) and read the run's own mlx_config.json (written by
jms_train for local-mlx runs only) for the base-model path + adapter dir. The
endpoint is still auth-gated (401 without a token); the pid is the object
capability. On this single-user desktop box the workspace is shared local storage,
so this matches how the rest of JMS treats it.

Only local-mlx runs are chattable: a spheron run writes no mlx_config.json and its
base weights aren't local, so it resolves to a clean SSE error frame — one that
NAMES the out-of-project dir its adapter was pulled into (read from the
runs/<rid>/remote.json pointer jms_train writes), so the dead end is legible
instead of looking like a missing run. The adapter must be on disk (a completed
run).

NO chat persistence — stateless completion; the client holds the transcript in
memory (YAGNI, per the plan).

Frames (identical to chat.sv.jac): {kind:"load",...} once, {kind:"token",...} per
token, {kind:"done",...} last, {kind:"error",text} on any guard/generation error.
"""

import json;
import paths;
import inference;
import from pathlib { Path }

"""True iff *adir* holds at least one *.safetensors adapter file (a real adapter
landed on disk) — mirrors jms_projects._adapter_on_disk without importing the
graph module."""
def _adapter_on_disk(adir: Path) -> bool {
    if not adir.is_dir() { return False; }
    for f in adir.glob("*.safetensors") { return True; }
    return False;
}

"""Why runs/<rid>/ carries no mlx_config.json, as a specific message. A spheron
run leaves a remote.json pointer there (written by jms_train._start_spheron)
naming the out-of-project dir cloudruns pulls its adapter into, so the error can
say WHERE the adapter is instead of "run not found"."""
def _no_mlx_config_error(run_dir: Path, rid: str) -> str {
    ptr = run_dir / "remote.json";
    if ptr.exists() {
        adir = "";
        try {
            adir = str(dict(json.loads(ptr.read_text())).get("adapter_path", ""));
        } except Exception { adir = ""; }
        tail = (" — adapter is at " + adir) if adir else "";
        return ("spheron runs cannot be chatted with yet: the adapter is HuggingFace PEFT "
                + "format and the base weights live on the VM, not this box" + tail);
    }
    if run_dir.is_dir() { return "run has no local MLX config (not a local-mlx run): " + rid; }
    return "unknown run: " + rid;
}

"""Resolve (pid, rid) → {ok, base_path, adapter_path, model_id, error} from disk.
Scans jms-projects/*/project.json for the pid, then reads runs/<rid>/mlx_config.json
(local-mlx runs only) for the base-model abs path + the adapter dir. See the module
docstring on why this is disk-based, not graph-based."""
def _resolve_run(pid: str, rid: str) -> dict {
    if not pid or not rid { return {"ok": False, "error": "missing pid/rid"}; }
    base = paths.workspace_root() / "jms-projects";
    if not base.is_dir() { return {"ok": False, "error": "unknown project"}; }
    for pj in base.glob("*/project.json") {
        proj: dict = {};
        try { proj = dict(json.loads(pj.read_text())); } except Exception { continue; }
        if str(proj.get("pid", "")) != pid { continue; }
        run_dir = pj.parent / "runs" / rid;
        cfg = run_dir / "mlx_config.json";
        if not cfg.exists() {
            return {"ok": False, "error": _no_mlx_config_error(run_dir, rid)};
        }
        c: dict = {};
        try { c = dict(json.loads(cfg.read_text())); } except Exception {
            return {"ok": False, "error": "unreadable run config"};
        }
        base_path = str(c.get("model", ""));
        adapter_dir = run_dir / "adapter";
        if not base_path or not Path(base_path).is_dir() {
            return {"ok": False, "error": "base model not available locally"};
        }
        if not _adapter_on_disk(adapter_dir) {
            return {"ok": False, "error": "adapter not found on disk for this run"};
        }
        return {
            "ok": True, "error": "",
            "base_path": base_path,
            "adapter_path": str(adapter_dir),
            "model_id": base_path   # residency key is base_path+adapter (see inference._reskey)
        };
    }
    return {"ok": False, "error": "unknown project"};
}

"""Stream a completion from a project run's base model + LoRA adapter. Same SSE
frame protocol as chat.sv.jac. Guard failures surface as a single error frame;
generation errors surface via inference.stream_chat's own error frame."""
def jms_chat_stream(
    pid: str, rid: str, messages: list[dict],
    temperature: float = 0.2, top_p: float = 0.9, max_tokens: int = 1024
) -> any {
    res = _resolve_run(pid, rid);
    if not bool(res["ok"]) {
        yield {"kind": "error", "text": str(res["error"])};
        return;
    }
    base_path = str(res["base_path"]);
    adapter_path = str(res["adapter_path"]);
    model_id = str(res["model_id"]);
    gen: any = inference.stream_chat(
        messages, model_id, base_path, temperature, top_p, max_tokens, adapter_path
    );
    for frame in gen {
        yield frame;
    }
}
