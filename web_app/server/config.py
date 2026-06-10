"""Model registry + data-root resolution.

models/ and dataset/ are gitignored, so a worktree checkout does not contain
them — everything resolves against JAC_STUDIO_DATA_ROOT (the main checkout).
"""
import os
from pathlib import Path

DEFAULT_ROOT = "/Users/ayush/Downloads/JaseciLabs/DataGeneration"

MODELS = [
    {"id": "qwen-dpo", "label": "Qwen · DPO", "path": "models/qwen-jac-dpo-fused-q8"},
    {"id": "gemma-dpo", "label": "Gemma · DPO", "path": "models/gemma-jac-dpo-fused-q8"},
    {"id": "qwen-sft", "label": "Qwen · SFT", "path": "models/qwen-jac-fused-q8"},
    {"id": "gemma-sft", "label": "Gemma · SFT", "path": "models/gemma-jac-fused-q8"},
]


def data_root() -> Path:
    return Path(os.environ.get("JAC_STUDIO_DATA_ROOT", DEFAULT_ROOT))


def model_by_id(model_id: str) -> dict | None:
    for m in MODELS:
        if m["id"] == model_id:
            return m
    return None


def model_path(m: dict) -> Path:
    return data_root() / m["path"]


def model_available(m: dict) -> bool:
    return model_path(m).is_dir()


def dir_size_gb(p: Path) -> float:
    total = sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
    return round(total / 1e9, 2)


def total_ram_gb() -> float:
    return round(os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE") / 1e9)
