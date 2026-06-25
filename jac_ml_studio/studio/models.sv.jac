"""studio - model registry + data-root resolution.

Ports server/config.py. models/ and dataset/ are gitignored and resolve against
JAC_STUDIO_DATA_ROOT (the main checkout). `list_models` is the client-facing
endpoint; the rest are helpers used by chat/eval/train modules.
"""

import os;
import from pathlib { Path }

glob DEFAULT_ROOT: str = "/Volumes/ExtremePro/JaseciLabs/DataGeneration";

glob MODELS: list[dict] = [
    {"id": "qwen-dpo", "label": "Qwen · DPO", "path": "models/qwen-jac-dpo-fused-q8"},
    {"id": "gemma-dpo", "label": "Gemma · DPO", "path": "models/gemma-jac-dpo-fused-q8"},
    {"id": "qwen-sft", "label": "Qwen · SFT", "path": "models/qwen-jac-fused-q8"},
    {"id": "gemma-sft", "label": "Gemma · SFT", "path": "models/gemma-jac-fused-q8"}
];

"""One model as the client sees it: registry entry + on-disk availability."""
obj ModelView {
    has id: str = "",
        label: str = "",
        path: str = "",
        available: bool = False;
}

def data_root() -> Path {
    return Path(os.environ.get("JAC_STUDIO_DATA_ROOT", DEFAULT_ROOT));
}

def model_by_id(model_id: str) -> dict {
    for m in MODELS {
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

def total_ram_gb() -> int {
    return round(os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE") / 1024 ** 3);
}

"""Total system RAM in GB — the sidebar memory gauge."""
def:pub system_ram() -> int {
    return total_ram_gb();
}

"""The model registry with live on-disk availability — the chat model picker."""
def:pub list_models() -> list[ModelView] {
    out: list[ModelView] = [];
    for m in MODELS {
        out.append(
            ModelView(
                id=str(m["id"]),
                label=str(m["label"]),
                path=str(m["path"]),
                available=model_available(m)
            )
        );
    }
    return out;
}
