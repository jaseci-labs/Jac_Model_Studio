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


@pytest.fixture()
def results_root(fake_root):
    r = fake_root / "results"
    q = r / "qwen"; q.mkdir(parents=True)
    (q / "train.log").write_text(
        "Iter 1: Val loss 1.781\n"
        "Iter 10: Train loss 1.888, Learning Rate 3.000e-06, Tokens/sec 483.916\n"
        "Iter 20: Train loss 1.402, Learning Rate 3.000e-06, Tokens/sec 410.2\n")
    (q / "metrics.jsonl").write_text('{"step": 100, "test_pass_pct": 42}\n{"step": 200, "test_pass_pct": 61}\n')
    (q / "idiom-metrics.jsonl").write_text('{"step": 100, "avg_sim": 0.9}\n{"avg_sim": 0.85, "idiomatic": 3, "python_shaped": 9, "runs": 12, "total": 13}\n')
    (q / ".train.done").touch()
    g = r / "gemma"; g.mkdir()
    (g / "dpo").mkdir()
    (g / "dpo" / "train.log").write_text("Iter 5: loss 0.693, lr 1.000e-06, tok/s 120.5\n")
    (r / "comparison").mkdir()
    (r / "_builder").mkdir()
    (r / "stray.log").write_text("x")
    return r


@pytest.fixture()
def fake_scripts(fake_root):
    for s in ["run_probe.sh", "run_dpo.sh"]:
        p = fake_root / s
        p.write_text("#!/bin/bash\necho started $@\nenv | grep -E 'EVAL_EVERY|SUBSET|DPO_ITERS|BOGUS' || true\nexit 0\n")
        p.chmod(0o755)
    return fake_root
