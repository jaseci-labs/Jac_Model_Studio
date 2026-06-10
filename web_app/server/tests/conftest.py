import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest


@pytest.fixture()
def fake_root(tmp_path, monkeypatch):
    """A fake DATA_ROOT with two 'model' dirs on disk."""
    for name in ["models/qwen-jac-dpo-fused-q8", "models/gemma-jac-dpo-fused-q8"]:
        d = tmp_path / name
        d.mkdir(parents=True)
        (d / "weights.safetensors").write_bytes(b"x" * 1000)
    monkeypatch.setenv("JAC_STUDIO_DATA_ROOT", str(tmp_path))
    return tmp_path


@pytest.fixture(autouse=True)
def tmp_db_global(tmp_path, monkeypatch):
    monkeypatch.setenv("JAC_STUDIO_DB", str(tmp_path / "chats.db"))
