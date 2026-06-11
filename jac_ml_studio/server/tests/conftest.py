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


@pytest.fixture()
def dataset_root(fake_root):
    """Populate fake_root with minimal valid content for all 9 PREVIEW_FILES."""
    import json

    def jl(path, rows):
        p = fake_root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("".join(json.dumps(r) + "\n" for r in rows))

    # SFT rows (sft.jsonl — 2 rows, with ```python + ```jac fences and meta)
    sft_row1 = {
        "messages": [
            {"role": "user", "content": "Convert this:\n```python\ndef add(a, b):\n    return a + b\n```\n"},
            {"role": "assistant", "content": "```jac\ndef add(a: int, b: int) -> int {\n    return a + b;\n}\n```\n"},
        ],
        "meta": {"difficulty": "easy", "generator": "gpt4", "source": "manual"},
    }
    sft_row2 = {
        "messages": [
            {"role": "user", "content": "Convert:\n```python\ndef greet(name):\n    return f'Hello {name}'\n```\n"},
            {"role": "assistant", "content": "```jac\ndef greet(name: str) -> str {\n    return f'Hello {name}';\n}\n```\n"},
        ],
        "meta": {"difficulty": "medium", "generator": "claude", "source": "auto"},
    }
    jl("dataset/conversion/sft.jsonl", [sft_row1, sft_row2])

    # sft_auto.jsonl — 1 row
    sft_auto_row = {
        "messages": [
            {"role": "user", "content": "```python\ndef square(x):\n    return x * x\n```\n"},
            {"role": "assistant", "content": "```jac\ndef square(x: int) -> int {\n    return x * x;\n}\n```\n"},
        ],
        "meta": {"difficulty": "easy", "generator": "auto", "source": "transpile"},
    }
    jl("dataset/conversion/sft_auto.jsonl", [sft_auto_row])

    # DPO row (dpo.jsonl — 1 row with jac fences in chosen/rejected)
    dpo_row = {
        "prompt": "Convert:\n```python\ndef factorial(n):\n    return 1 if n <= 1 else n * factorial(n - 1)\n```\n",
        "chosen": "```jac\ndef factorial(n: int) -> int {\n    return 1 if n <= 1 else n * factorial(n - 1);\n}\n```\n",
        "rejected": "```jac\ndef factorial(n) {\n    if n <= 1 { return 1; }\n    return n * factorial(n - 1);\n}\n```\n",
    }
    jl("dataset/conversion/dpo.jsonl", [dpo_row])

    # MLX split files
    mlx_train = {"messages": [{"role": "user", "content": "q"}, {"role": "assistant", "content": "a"}]}
    mlx_valid = {"messages": [{"role": "user", "content": "q2"}, {"role": "assistant", "content": "a2"}]}
    jl("dataset/mlx/train.jsonl", [mlx_train, mlx_train])
    jl("dataset/mlx/valid.jsonl", [mlx_valid])

    dpo_train = {"prompt": "p", "chosen": "c", "rejected": "r"}
    dpo_valid = {"prompt": "p2", "chosen": "c2", "rejected": "r2"}
    jl("dataset/mlx_dpo/train.jsonl", [dpo_train, dpo_train, dpo_train])
    jl("dataset/mlx_dpo/valid.jsonl", [dpo_valid])

    # Holdout rows
    holdout_row = {
        "func_name": "add",
        "python": "def add(a, b):\n    return a + b\n",
        "prompt": "Write a function add",
        "test_cases": [{"input": [1, 2], "expected": 3}],
    }
    graph_row = {
        "func_name": "build_graph",
        "python": "def build_graph():\n    pass\n",
        "prompt": "Build a graph",
        "test_cases": [],
    }
    jl("dataset/eval_holdout/conversion.jsonl", [holdout_row])
    jl("dataset/eval_holdout/graph_conversion.jsonl", [graph_row])

    return fake_root
