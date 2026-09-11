# Dataset Endpoints + Builder Pipeline Jobs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add dataset preview/ingest endpoints and builder pipeline job management to the Jac ML Studio FastAPI server.

**Architecture:** Two new service modules (`datasets.py`, `builders.py`) hold pure business logic; a single router file (`routers/data.py`) exports two FastAPI `APIRouter` instances (`/api/dataset` and `/api/builders`) that delegate to those modules. Tests use a `dataset_root` fixture built on top of the existing `fake_root` fixture in conftest.

**Tech Stack:** Python 3.11+, FastAPI, Pydantic, pytest, existing `procs.py` / `runlogs.py` / `config.py` modules.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `jac_ml_studio/server/datasets.py` | **Create** | PREVIEW_FILES list, APPEND_TARGETS dict, `stats()`, `list_files()`, `rows()`, `add_examples()` |
| `jac_ml_studio/server/builders.py` | **Create** | BUILDERS list, `run()`, `status()`, `all_status()` |
| `jac_ml_studio/server/routers/data.py` | **Create** | Two APIRouters (`dataset_router`, `builder_router`) wiring HTTP to service calls |
| `jac_ml_studio/server/app.py` | **Modify** | Import and include both routers from `routers.data` |
| `jac_ml_studio/server/tests/conftest.py` | **Modify** | Add `dataset_root` fixture writing all 9 preview files |
| `jac_ml_studio/server/tests/test_dataset_api.py` | **Create** | Full test suite for dataset endpoints |
| `jac_ml_studio/server/tests/test_builders_api.py` | **Create** | Full test suite for builder endpoints |

---

### Task 1: Extend conftest with `dataset_root` fixture

**Files:**
- Modify: `jac_ml_studio/server/tests/conftest.py`

- [ ] **Step 1: Read the current conftest to know where to insert**

The file ends at line 52. We will append the new fixture after `fake_scripts`.

- [ ] **Step 2: Add `dataset_root` fixture**

Append the following to `jac_ml_studio/server/tests/conftest.py`:

```python
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
```

- [ ] **Step 3: Run existing tests to confirm nothing is broken**

```bash
cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/.claude/worktrees/jac-ml-studio/jac_ml_studio/server
.venv/bin/pytest tests/ -q --tb=short
```

Expected: 157 passed, 1 skipped (same as before).

- [ ] **Step 4: Commit**

```bash
cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/.claude/worktrees/jac-ml-studio
git add jac_ml_studio/server/tests/conftest.py
git commit -m "test(mlstudio): add dataset_root fixture for Phase 3 tests"
```

---

### Task 2: Write failing tests for dataset endpoints

**Files:**
- Create: `jac_ml_studio/server/tests/test_dataset_api.py`

- [ ] **Step 1: Create the test file**

Create `jac_ml_studio/server/tests/test_dataset_api.py`:

```python
"""Tests for /api/dataset endpoints."""
import json
import pytest
from fastapi.testclient import TestClient


def make_client(dataset_root):
    from app import create_app
    return TestClient(create_app())


# ---------------------------------------------------------------------------
# /api/dataset/stats
# ---------------------------------------------------------------------------

def test_stats_sft_total(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/stats")
    assert r.status_code == 200
    data = r.json()
    # sft.jsonl has 2 rows, sft_auto.jsonl has 1 row
    assert data["sft_total"] == 3
    assert len(data["sft_files"]) == 2
    assert data["dpo_pairs"] == 1


def test_stats_splits(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/stats")
    splits = r.json()["splits"]
    assert splits["mlx_train"] == 2
    assert splits["mlx_valid"] == 1
    assert splits["dpo_train"] == 3
    assert splits["dpo_valid"] == 1
    assert splits["holdout"] == 1
    assert splits["graph_holdout"] == 1


def test_stats_by_difficulty(dataset_root):
    client = make_client(dataset_root)
    data = client.get("/api/dataset/stats").json()
    sft_file = data["sft_files"][0]  # sft.jsonl
    assert sft_file["path"] == "dataset/conversion/sft.jsonl"
    assert sft_file["total"] == 2
    assert sft_file["by_difficulty"]["easy"] == 1
    assert sft_file["by_difficulty"]["medium"] == 1


# ---------------------------------------------------------------------------
# /api/dataset/files
# ---------------------------------------------------------------------------

def test_files_lists_nine(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/files")
    assert r.status_code == 200
    files = r.json()["files"]
    assert len(files) == 9


def test_files_counts(dataset_root):
    client = make_client(dataset_root)
    files = client.get("/api/dataset/files").json()["files"]
    by_path = {f["path"]: f for f in files}
    assert by_path["dataset/conversion/sft.jsonl"]["count"] == 2
    assert by_path["dataset/conversion/sft_auto.jsonl"]["count"] == 1
    assert by_path["dataset/conversion/dpo.jsonl"]["count"] == 1


def test_files_has_labels(dataset_root):
    client = make_client(dataset_root)
    files = client.get("/api/dataset/files").json()["files"]
    labels = [f["label"] for f in files]
    assert "SFT idiomatic core" in labels
    assert "Holdout (function)" in labels


# ---------------------------------------------------------------------------
# /api/dataset/rows  — SFT
# ---------------------------------------------------------------------------

def test_rows_sft_kind(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/rows", params={"path": "dataset/conversion/sft.jsonl"})
    assert r.status_code == 200
    data = r.json()
    assert data["total"] == 2
    row = data["rows"][0]
    assert row["kind"] == "sft"


def test_rows_sft_python_jac_extracted(dataset_root):
    client = make_client(dataset_root)
    rows = client.get("/api/dataset/rows", params={"path": "dataset/conversion/sft.jsonl"}).json()["rows"]
    row = rows[0]
    assert "def add" in row["python"]
    assert "def add" in row["jac"]
    # No HTML spans — raw code strings only
    assert "<span" not in row["python"]
    assert "<span" not in row["jac"]


def test_rows_sft_no_html_anywhere(dataset_root):
    client = make_client(dataset_root)
    rows = client.get("/api/dataset/rows", params={"path": "dataset/conversion/sft.jsonl"}).json()["rows"]
    payload_str = json.dumps(rows)
    assert "<span" not in payload_str


def test_rows_sft_meta(dataset_root):
    client = make_client(dataset_root)
    rows = client.get("/api/dataset/rows", params={"path": "dataset/conversion/sft.jsonl"}).json()["rows"]
    assert rows[0]["difficulty"] == "easy"
    assert rows[1]["difficulty"] == "medium"


# ---------------------------------------------------------------------------
# /api/dataset/rows  — DPO
# ---------------------------------------------------------------------------

def test_rows_dpo(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/rows", params={"path": "dataset/conversion/dpo.jsonl"})
    assert r.status_code == 200
    data = r.json()
    row = data["rows"][0]
    assert row["kind"] == "dpo"
    assert "factorial" in row["chosen"]
    assert "factorial" in row["rejected"]
    assert "<span" not in row["chosen"]
    assert "<span" not in row["rejected"]


# ---------------------------------------------------------------------------
# /api/dataset/rows  — Holdout
# ---------------------------------------------------------------------------

def test_rows_holdout(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/rows", params={"path": "dataset/eval_holdout/conversion.jsonl"})
    assert r.status_code == 200
    row = r.json()["rows"][0]
    assert row["kind"] == "holdout"
    assert "add" in row["python"]
    assert row["name"] == "add"


# ---------------------------------------------------------------------------
# /api/dataset/rows  — paging
# ---------------------------------------------------------------------------

def test_rows_paging_offset(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/rows",
                   params={"path": "dataset/conversion/sft.jsonl", "offset": 1, "limit": 10})
    data = r.json()
    assert data["total"] == 2
    assert len(data["rows"]) == 1
    assert data["rows"][0]["idx"] == 1


def test_rows_limit_cap(dataset_root):
    """Limit is capped at 40."""
    client = make_client(dataset_root)
    r = client.get("/api/dataset/rows",
                   params={"path": "dataset/conversion/sft.jsonl", "limit": 200})
    assert r.status_code == 200


# ---------------------------------------------------------------------------
# /api/dataset/rows  — security
# ---------------------------------------------------------------------------

def test_rows_path_traversal_rejected(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/rows", params={"path": "../../etc/passwd"})
    assert r.status_code == 400


def test_rows_non_allowlisted_rejected(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/rows", params={"path": "dataset/conversion/secret.jsonl"})
    assert r.status_code == 400


# ---------------------------------------------------------------------------
# /api/dataset/examples (POST)
# ---------------------------------------------------------------------------

def test_add_examples_sft(dataset_root):
    client = make_client(dataset_root)
    line = json.dumps({"messages": [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"}]})
    r = client.post("/api/dataset/examples", json={"target": "sft", "text": line + "\n" + line})
    assert r.status_code == 200
    data = r.json()
    assert data["added"] == 2
    assert data["errors"] == []
    # total should be original 2 + 2 new = 4
    assert data["total"] == 4


def test_add_examples_stats_reflect(dataset_root):
    """After appending, /stats shows updated sft_total."""
    client = make_client(dataset_root)
    line = json.dumps({"messages": [{"role": "user", "content": "q"}, {"role": "assistant", "content": "a"}]})
    client.post("/api/dataset/examples", json={"target": "sft", "text": line})
    stats = client.get("/api/dataset/stats").json()
    assert stats["sft_total"] == 4  # 2 original + 1 sft_auto + 1 new


def test_add_examples_invalid_json_line(dataset_root):
    client = make_client(dataset_root)
    text = "not-json\n" + json.dumps({"messages": [{"role": "user", "content": "q"}, {"role": "assistant", "content": "a"}]})
    r = client.post("/api/dataset/examples", json={"target": "sft", "text": text})
    data = r.json()
    assert data["added"] == 1
    assert len(data["errors"]) == 1
    assert "not valid JSON" in data["errors"][0]


def test_add_examples_dpo_missing_rejected(dataset_root):
    client = make_client(dataset_root)
    line = json.dumps({"prompt": "p", "chosen": "c"})  # missing rejected
    r = client.post("/api/dataset/examples", json={"target": "dpo", "text": line})
    data = r.json()
    assert data["added"] == 0
    assert len(data["errors"]) == 1
    assert "DPO" in data["errors"][0]


def test_add_examples_bad_target(dataset_root):
    client = make_client(dataset_root)
    r = client.post("/api/dataset/examples", json={"target": "evil", "text": "{}"})
    assert r.status_code == 400
```

- [ ] **Step 2: Run the new tests to confirm they all fail (module not found)**

```bash
cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/.claude/worktrees/jac-ml-studio/jac_ml_studio/server
.venv/bin/pytest tests/test_dataset_api.py -q --tb=line 2>&1 | head -30
```

Expected: ImportError or 404s — tests not passing yet.

---

### Task 3: Write failing tests for builder endpoints

**Files:**
- Create: `jac_ml_studio/server/tests/test_builders_api.py`

- [ ] **Step 1: Create the test file**

Create `jac_ml_studio/server/tests/test_builders_api.py`:

```python
"""Tests for /api/builders endpoints."""
import os
import time
import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def fake_jac(dataset_root):
    """Write a fake jac executable into dataset_root/.venv/bin/jac."""
    venv_bin = dataset_root / ".venv" / "bin"
    venv_bin.mkdir(parents=True, exist_ok=True)
    jac_path = venv_bin / "jac"
    jac_path.write_text("#!/bin/bash\necho \"ran $@\"\nexit 0\n")
    jac_path.chmod(0o755)
    return dataset_root


@pytest.fixture()
def fake_jac_slow(dataset_root):
    """A jac that sleeps for 5 seconds (simulates long-running job)."""
    venv_bin = dataset_root / ".venv" / "bin"
    venv_bin.mkdir(parents=True, exist_ok=True)
    jac_path = venv_bin / "jac"
    jac_path.write_text("#!/bin/bash\nsleep 5\necho \"ran $@\"\nexit 0\n")
    jac_path.chmod(0o755)
    return dataset_root


@pytest.fixture()
def fake_jac_fail(dataset_root):
    """A jac that exits with code 2 (simulates failing job)."""
    venv_bin = dataset_root / ".venv" / "bin"
    venv_bin.mkdir(parents=True, exist_ok=True)
    jac_path = venv_bin / "jac"
    jac_path.write_text("#!/bin/bash\necho \"error output\"\nexit 2\n")
    jac_path.chmod(0o755)
    return dataset_root


def make_client(root):
    from app import create_app
    return TestClient(create_app())


EXPECTED_STAGES = [
    "seed_conversion", "idiomatic_batch", "idiomatic_batch2", "idiomatic_batch3",
    "scale_conversion", "dpo_conversion", "build_manifest", "build_splits",
    "build_dpo_splits", "holdout", "graph_holdout", "dataset_stats", "verify_dataset",
]


# ---------------------------------------------------------------------------
# GET /api/builders
# ---------------------------------------------------------------------------

def test_all_builders_listed(fake_jac):
    client = make_client(fake_jac)
    r = client.get("/api/builders")
    assert r.status_code == 200
    data = r.json()
    assert "builders" in data
    stages = [b["stage"] for b in data["builders"]]
    assert stages == EXPECTED_STAGES


def test_all_builders_idle_initially(fake_jac):
    client = make_client(fake_jac)
    builders = client.get("/api/builders").json()["builders"]
    assert len(builders) == 13
    for b in builders:
        assert b["status"] == "idle"


# ---------------------------------------------------------------------------
# POST /api/builders/run
# ---------------------------------------------------------------------------

def test_run_dataset_stats(fake_jac):
    client = make_client(fake_jac)
    r = client.post("/api/builders/run", json={"stage": "dataset_stats"})
    assert r.status_code == 200
    data = r.json()
    assert data["stage"] == "dataset_stats"
    assert data["status"] in ("running", "done")


def test_run_then_poll_done(fake_jac):
    """Spawn a fast builder, poll until done or 3 s timeout."""
    client = make_client(fake_jac)
    client.post("/api/builders/run", json={"stage": "dataset_stats"})
    # Give the fast script time to finish
    deadline = time.monotonic() + 3.0
    status = "running"
    while time.monotonic() < deadline and status == "running":
        time.sleep(0.1)
        status = client.get("/api/builders/dataset_stats").json()["status"]
    assert status == "done"


def test_run_log_contains_ran(fake_jac):
    """The log tail should eventually contain 'ran' from the fake jac script."""
    client = make_client(fake_jac)
    client.post("/api/builders/run", json={"stage": "dataset_stats"})
    time.sleep(0.5)
    data = client.get("/api/builders/dataset_stats").json()
    assert "ran" in data.get("log_tail", "")


def test_run_unknown_stage(fake_jac):
    client = make_client(fake_jac)
    r = client.post("/api/builders/run", json={"stage": "not_a_stage"})
    assert r.status_code == 400


# ---------------------------------------------------------------------------
# GET /api/builders/{stage}
# ---------------------------------------------------------------------------

def test_get_stage_idle(fake_jac):
    client = make_client(fake_jac)
    r = client.get("/api/builders/build_splits")
    assert r.status_code == 200
    assert r.json()["status"] == "idle"


def test_get_unknown_stage(fake_jac):
    client = make_client(fake_jac)
    r = client.get("/api/builders/nonexistent")
    assert r.status_code == 400


# ---------------------------------------------------------------------------
# Already running guard
# ---------------------------------------------------------------------------

def test_already_running(fake_jac_slow):
    """Second run call while the job is still running returns 'already running'."""
    client = make_client(fake_jac_slow)
    client.post("/api/builders/run", json={"stage": "holdout"})
    r2 = client.post("/api/builders/run", json={"stage": "holdout"})
    assert r2.status_code == 200
    assert r2.json()["message"] == "already running"


# ---------------------------------------------------------------------------
# Failing jac binary
# ---------------------------------------------------------------------------

def test_failing_jac(fake_jac_fail):
    """A jac that exits 2 should eventually produce status 'failed'."""
    client = make_client(fake_jac_fail)
    client.post("/api/builders/run", json={"stage": "verify_dataset"})
    deadline = time.monotonic() + 3.0
    status = "running"
    while time.monotonic() < deadline and status == "running":
        time.sleep(0.1)
        status = client.get("/api/builders/verify_dataset").json()["status"]
    assert status == "failed"
```

- [ ] **Step 2: Run the new tests to confirm they all fail**

```bash
cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/.claude/worktrees/jac-ml-studio/jac_ml_studio/server
.venv/bin/pytest tests/test_builders_api.py -q --tb=line 2>&1 | head -30
```

Expected: ImportError or 404s.

---

### Task 4: Implement `datasets.py`

**Files:**
- Create: `jac_ml_studio/server/datasets.py`

- [ ] **Step 1: Create `datasets.py`**

Create `jac_ml_studio/server/datasets.py`:

```python
"""Dataset stats / preview / ingest.

Ported from dashboard_app/services/dataset.sv.jac.
HTML highlighting (_hl/_tok_repl/HL_*) is intentionally NOT ported — all code
fields are returned as raw strings.
"""

import json
import re
from pathlib import Path

import config


# ---------------------------------------------------------------------------
# Allow-lists
# ---------------------------------------------------------------------------

PREVIEW_FILES: list[list[str]] = [
    ["dataset/conversion/sft.jsonl", "SFT idiomatic core"],
    ["dataset/conversion/sft_auto.jsonl", "SFT transpile volume"],
    ["dataset/conversion/dpo.jsonl", "DPO pairs"],
    ["dataset/mlx/train.jsonl", "MLX SFT train"],
    ["dataset/mlx/valid.jsonl", "MLX SFT valid"],
    ["dataset/mlx_dpo/train.jsonl", "MLX DPO train"],
    ["dataset/mlx_dpo/valid.jsonl", "MLX DPO valid"],
    ["dataset/eval_holdout/conversion.jsonl", "Holdout (function)"],
    ["dataset/eval_holdout/graph_conversion.jsonl", "Holdout (graph)"],
]

APPEND_TARGETS: dict[str, str] = {
    "sft": "dataset/conversion/sft.jsonl",
    "dpo": "dataset/conversion/dpo.jsonl",
}


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _abs(rel: str) -> Path:
    return config.data_root() / rel


def _allowed_preview(rel: str) -> bool:
    return any(pair[0] == rel for pair in PREVIEW_FILES)


def _line_count(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(1 for line in path.read_text().split("\n") if line.strip())


def _count_file(rel: str) -> dict:
    by_diff: dict = {}
    by_gen: dict = {}
    by_src: dict = {}
    total: int = 0
    p = _abs(rel)
    if p.exists():
        for line in p.read_text().split("\n"):
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            meta = rec.get("meta", {})
            diff = str(meta.get("difficulty", "?"))
            gen = str(meta.get("generator", "?"))
            src = str(meta.get("source", "?"))
            by_diff[diff] = by_diff.get(diff, 0) + 1
            by_gen[gen] = by_gen.get(gen, 0) + 1
            by_src[src] = by_src.get(src, 0) + 1
            total += 1
    return {
        "path": rel,
        "total": total,
        "by_difficulty": by_diff,
        "by_generator": by_gen,
        "by_source": by_src,
    }


def _fence(text: str, lang: str) -> str:
    """Extract the first fenced code block for *lang* from *text*.

    Falls back to the first fenced block of any language if the specific lang
    is not found.  Returns "" if no fence is found.
    """
    m = re.search(r"(?s)```" + lang + r"[^\n]*\n(.*?)```", text)
    if m:
        return m.group(1).strip()
    m2 = re.search(r"(?s)```[A-Za-z0-9]*\s*\n(.*?)```", text)
    if m2:
        return m2.group(1).strip()
    return ""


def _funcname(code: str) -> str:
    for pat in [r"def\s+(\w+)", r"walker\s+(\w+)", r"node\s+(\w+)", r"obj\s+(\w+)", r"class\s+(\w+)"]:
        m = re.search(pat, code)
        if m:
            return m.group(1)
    return ""


def _first_line(s: str) -> str:
    for ln in s.split("\n"):
        t = ln.strip()
        if t:
            return t[:90] + "…" if len(t) > 90 else t
    return ""


def _build_row(idx: int, rec: dict) -> dict:
    meta = rec.get("meta", {})
    diff = str(meta.get("difficulty", "—"))
    src = str(meta.get("source", rec.get("source", "—")))
    py = jc = chosen = rejected = prompt = raw = ""
    kind = "raw"
    nm = ""

    if "messages" in rec:
        kind = "sft"
        msgs = rec["messages"]
        usr = str(msgs[0].get("content", "")) if len(msgs) > 0 else ""
        ast = str(msgs[1].get("content", "")) if len(msgs) > 1 else ""
        py = _fence(usr, "python")
        jc = _fence(ast, "jac")
        if not jc:
            jc = ast.strip()
        prompt = re.sub(r"(?s)```.*?```", "", usr).strip()
        nm = _funcname(py) or _funcname(jc)
    elif "chosen" in rec:
        kind = "dpo"
        prompt = re.sub(r"(?s)```.*?```", "", str(rec.get("prompt", ""))).strip()
        chosen = _fence(str(rec["chosen"]), "jac") or str(rec["chosen"]).strip()
        rejected = _fence(str(rec["rejected"]), "jac") or str(rec["rejected"]).strip()
        py = _fence(str(rec.get("prompt", "")), "python")
        nm = _funcname(chosen) or _funcname(py)
    elif "python" in rec:
        kind = "holdout"
        py = str(rec["python"])
        prompt = str(rec.get("prompt", ""))
        nm = str(rec.get("func_name", "")) or _funcname(py)
    else:
        raw = json.dumps(rec, indent=2)

    preview = _first_line(py) or _first_line(prompt) or _first_line(jc) or _first_line(chosen) or _first_line(raw)

    return {
        "idx": idx,
        "name": nm or "—",
        "difficulty": diff,
        "source": src,
        "kind": kind,
        "preview": preview,
        "prompt": prompt,
        "python": py,
        "jac": jc,
        "chosen": chosen,
        "rejected": rejected,
        "raw": raw,
    }


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def stats() -> dict:
    """Dataset statistics: counts per SFT file, DPO pairs, split sizes."""
    sft_rels = ["dataset/conversion/sft.jsonl", "dataset/conversion/sft_auto.jsonl"]
    sft_files = []
    grand = 0
    for rel in sft_rels:
        fs = _count_file(rel)
        sft_files.append(fs)
        grand += fs["total"]
    splits = {
        "mlx_train": _line_count(_abs("dataset/mlx/train.jsonl")),
        "mlx_valid": _line_count(_abs("dataset/mlx/valid.jsonl")),
        "dpo_train": _line_count(_abs("dataset/mlx_dpo/train.jsonl")),
        "dpo_valid": _line_count(_abs("dataset/mlx_dpo/valid.jsonl")),
        "holdout": _line_count(_abs("dataset/eval_holdout/conversion.jsonl")),
        "graph_holdout": _line_count(_abs("dataset/eval_holdout/graph_conversion.jsonl")),
    }
    return {
        "sft_files": sft_files,
        "sft_total": grand,
        "dpo_pairs": _line_count(_abs("dataset/conversion/dpo.jsonl")),
        "splits": splits,
    }


def list_files() -> list[dict]:
    """List all preview-allowed files with their line counts."""
    return [
        {"path": pair[0], "label": pair[1], "count": _line_count(_abs(pair[0]))}
        for pair in PREVIEW_FILES
    ]


def rows(rel: str, offset: int, limit: int) -> dict:
    """Return a page of parsed DataRow dicts from the JSONL file at *rel*.

    Raises ValueError if *rel* is not in PREVIEW_FILES.
    Limit is capped at 40.
    """
    if not _allowed_preview(rel):
        raise ValueError(f"path not allowed: {rel!r}")
    cap = max(1, min(limit, 40))
    p = _abs(rel)
    if not p.exists():
        return {"rows": [], "total": 0}
    lines = [ln for ln in p.read_text().split("\n") if ln.strip()]
    total = len(lines)
    result = []
    i = offset
    while i < total and i < offset + cap:
        try:
            rec = json.loads(lines[i])
            result.append(_build_row(i, rec))
        except Exception:
            pass
        i += 1
    return {"rows": result, "total": total}


def add_examples(target: str, text: str) -> dict:
    """Append valid JSONL rows to *target* (key in APPEND_TARGETS).

    Validates each non-empty line as JSON with the required schema fields.
    Raises ValueError for unknown target keys.
    """
    if target not in APPEND_TARGETS:
        raise ValueError(f"unknown target: {target!r}")
    rel = APPEND_TARGETS[target]
    is_dpo = target == "dpo"
    valid = []
    errors = []
    n = 0
    for raw in text.split("\n"):
        if not raw.strip():
            continue
        n += 1
        try:
            rec = json.loads(raw)
        except Exception:
            errors.append(f"line {n}: not valid JSON")
            continue
        if is_dpo:
            if not all(k in rec for k in ("prompt", "chosen", "rejected")):
                errors.append(f"line {n}: DPO row needs prompt/chosen/rejected")
                continue
        else:
            if "messages" not in rec:
                errors.append(f"line {n}: SFT row needs a messages list")
                continue
        valid.append(json.dumps(rec))

    if valid:
        p = _abs(rel)
        p.parent.mkdir(parents=True, exist_ok=True)
        existing = p.read_text() if p.exists() else ""
        if existing and not existing.endswith("\n"):
            existing += "\n"
        p.write_text(existing + "\n".join(valid) + "\n")

    return {"added": len(valid), "errors": errors, "total": _line_count(_abs(rel))}
```

- [ ] **Step 2: Run dataset tests (should still fail — router not wired yet)**

```bash
cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/.claude/worktrees/jac-ml-studio/jac_ml_studio/server
.venv/bin/pytest tests/test_dataset_api.py -q --tb=short 2>&1 | head -40
```

Expected: 404 Not Found errors (module exists but routes not wired).

---

### Task 5: Implement `builders.py`

**Files:**
- Create: `jac_ml_studio/server/builders.py`

- [ ] **Step 1: Create `builders.py`**

Create `jac_ml_studio/server/builders.py`:

```python
"""Builder pipeline job management.

Ported from dashboard_app/services/jobs.sv.jac (run_builder / builder_status /
BUILDERS list).
"""

import os
import shlex
import time
from pathlib import Path

import config
import procs
import runlogs


BUILDERS: list[str] = [
    "seed_conversion",
    "idiomatic_batch",
    "idiomatic_batch2",
    "idiomatic_batch3",
    "scale_conversion",
    "dpo_conversion",
    "build_manifest",
    "build_splits",
    "build_dpo_splits",
    "holdout",
    "graph_holdout",
    "dataset_stats",
    "verify_dataset",
]


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _job_file(stage: str) -> Path:
    return config.results_dir() / "_builder" / f".job-{stage}.json"


def _run_log(stage: str) -> Path:
    return config.results_dir() / "_builder" / f"run-{stage}.log"


def _build_status(stage: str, message: str = "") -> dict:
    jf = _job_file(stage)
    rl = _run_log(stage)
    job = procs.live_status(jf, rl)
    if job is None:
        return {
            "stage": stage,
            "status": "idle",
            "pid": 0,
            "started": "",
            "log_tail": runlogs.tail(rl, 40),
            "message": message,
        }
    return {
        "stage": stage,
        "status": job.get("status", "idle"),
        "pid": int(job.get("pid") or 0),
        "started": str(job.get("started", "")),
        "log_tail": runlogs.tail(rl, 40),
        "message": message,
    }


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def run(stage: str) -> dict:
    """Spawn `jac run srccurrent/jacgen/<stage>.jac` as a detached builder job.

    Raises ValueError if *stage* is not in BUILDERS.
    Returns a status dict with message="already running" if the job is live.
    """
    if stage not in BUILDERS:
        raise ValueError(f"unknown builder stage: {stage!r}")

    jf = _job_file(stage)
    rl = _run_log(stage)

    # Check if already running
    existing = procs.live_status(jf, rl)
    if existing and existing.get("status") == "running":
        return _build_status(stage, "already running")

    # Ensure output directory exists
    (config.results_dir() / "_builder").mkdir(parents=True, exist_ok=True)

    # TRUNCATE the runlog so a stale __EXIT__ marker from a previous run is erased.
    # Without this, live_status would immediately mark the new run as done/failed.
    rl.write_text("")

    # Build command: jac run srccurrent/jacgen/<stage>.jac
    target = f"srccurrent/jacgen/{shlex.quote(stage)}.jac"
    inner_cmd = f"{shlex.quote(str(config.jac_bin()))} run {target}"
    cmd = procs.with_exit_marker(inner_cmd, rl)

    # Prepend .venv/bin to PATH so the subprocess finds the right jac
    venv_bin = str(config.data_root() / ".venv" / "bin")
    env_overrides = {"PATH": f"{venv_bin}:{os.environ.get('PATH', '')}"}

    pid = procs.spawn_detached(
        cmd,
        runlog=rl,
        env=env_overrides,
        cwd=config.data_root(),
    )

    now = time.strftime("%Y-%m-%d %H:%M:%S")
    procs.write_job(jf, {
        "name": stage,
        "mode": "builder",
        "pid": pid,
        "status": "running",
        "started": now,
        "cmd": inner_cmd,
    })

    return _build_status(stage, "started")


def status(stage: str) -> dict:
    """Return live status for *stage*.

    Raises ValueError if *stage* is not in BUILDERS.
    Returns status "idle" when no job file exists.
    """
    if stage not in BUILDERS:
        raise ValueError(f"unknown builder stage: {stage!r}")
    return _build_status(stage)


def all_status() -> list[dict]:
    """Return live status for all builder stages, in BUILDERS order."""
    return [_build_status(s) for s in BUILDERS]
```

- [ ] **Step 2: Run builder tests (should still fail — router not wired)**

```bash
cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/.claude/worktrees/jac-ml-studio/jac_ml_studio/server
.venv/bin/pytest tests/test_builders_api.py -q --tb=short 2>&1 | head -30
```

Expected: 404 Not Found.

---

### Task 6: Implement `routers/data.py` and wire into `app.py`

**Files:**
- Create: `jac_ml_studio/server/routers/data.py`
- Modify: `jac_ml_studio/server/app.py`

- [ ] **Step 1: Create `routers/data.py`**

Create `jac_ml_studio/server/routers/data.py`:

```python
"""APIRouters for /api/dataset and /api/builders endpoints."""

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

import builders
import datasets

# ---------------------------------------------------------------------------
# Dataset router  (/api/dataset)
# ---------------------------------------------------------------------------

dataset_router = APIRouter(prefix="/api/dataset")


class ExamplesRequest(BaseModel):
    target: str
    text: str


@dataset_router.get("/stats")
def get_stats():
    return datasets.stats()


@dataset_router.get("/files")
def get_files():
    return {"files": datasets.list_files()}


@dataset_router.get("/rows")
def get_rows(path: str, offset: int = 0, limit: int = 25):
    try:
        return datasets.rows(path, offset, limit)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@dataset_router.post("/examples")
def post_examples(body: ExamplesRequest):
    try:
        return datasets.add_examples(body.target, body.text)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


# ---------------------------------------------------------------------------
# Builder router  (/api/builders)
# ---------------------------------------------------------------------------

builder_router = APIRouter(prefix="/api/builders")


class RunRequest(BaseModel):
    stage: str


@builder_router.get("")
def get_all_builders():
    return {"builders": builders.all_status()}


@builder_router.post("/run")
def post_run(body: RunRequest):
    try:
        return builders.run(body.stage)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@builder_router.get("/{stage}")
def get_builder_status(stage: str):
    try:
        return builders.status(stage)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
```

- [ ] **Step 2: Wire routers into `app.py`**

In `jac_ml_studio/server/app.py`, find the existing router include block near the bottom of `create_app()`:

```python
    app.include_router(routers.runs.router)
    app.include_router(routers.train.router)
```

Add two lines after it (and add the import at the top with the other router imports):

Add to imports at top (after `import routers.train`):
```python
import routers.data
```

Add to `create_app()` body (after the existing `include_router` calls):
```python
    app.include_router(routers.data.dataset_router)
    app.include_router(routers.data.builder_router)
```

The full import block should look like:
```python
import routers.runs
import routers.train
import routers.data
```

And the include block:
```python
    app.include_router(routers.runs.router)
    app.include_router(routers.train.router)
    app.include_router(routers.data.dataset_router)
    app.include_router(routers.data.builder_router)
```

- [ ] **Step 3: Run the full test suite**

```bash
cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/.claude/worktrees/jac-ml-studio/jac_ml_studio/server
.venv/bin/pytest tests/ -q --tb=short
```

Expected: All tests pass (157 original + new dataset + builder tests).

- [ ] **Step 4: Fix any failures**

Common failure modes to watch for:
- `test_already_running`: The fake_jac_slow script sleeps 5s. If `live_status` sees `__EXIT__` from a previous test's log file (stale), the guard won't trigger. Verify the runlog is truncated before each spawn (done in `builders.run()`).
- `test_run_log_contains_ran`: If polling too quickly the log may not have flushed. The 0.5s sleep in the test should be enough for the fast script.
- `test_add_examples_stats_reflect`: `sft_total` should be 4 (2 from sft.jsonl + 1 from sft_auto.jsonl + 1 new). Verify the fixture matches.

- [ ] **Step 5: Commit all new files**

```bash
cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/.claude/worktrees/jac-ml-studio
git add jac_ml_studio/server/datasets.py \
        jac_ml_studio/server/builders.py \
        jac_ml_studio/server/routers/data.py \
        jac_ml_studio/server/app.py \
        jac_ml_studio/server/tests/conftest.py \
        jac_ml_studio/server/tests/test_dataset_api.py \
        jac_ml_studio/server/tests/test_builders_api.py
git commit -m "feat(mlstudio): dataset endpoints + builder pipeline jobs"
```

---

## Self-Review

### Spec coverage

| Spec requirement | Task |
|---|---|
| PREVIEW_FILES 9 entries (dataset.sv.jac:59-69) | Task 4 |
| APPEND_TARGETS dict `{sft:..., dpo:...}` | Task 4 |
| `stats()` → sft_files/sft_total/dpo_pairs/splits | Task 4 |
| `list_files()` → {path,label,count} × 9 | Task 4 |
| `rows()` DataRow with python/jac/chosen/rejected/raw raw strings (no HTML) | Task 4 |
| `rows()` ValueError for non-allowlisted path | Task 4 |
| `rows()` limit cap 40 | Task 4 |
| `add_examples()` validates JSON + schema per target | Task 4 |
| `add_examples()` ensure trailing newline before append | Task 4 |
| `add_examples()` returns {added, errors, total} | Task 4 |
| BUILDERS ordered list 13 entries | Task 5 |
| `run()` job file `.job-<stage>.json` in results/_builder | Task 5 |
| `run()` runlog truncated before spawn (stale __EXIT__ fix) | Task 5 |
| `run()` already running guard | Task 5 |
| `run()` cmd = `<jac_bin> run srccurrent/jacgen/<stage>.jac` | Task 5 |
| `run()` env PATH prepended with data_root()/.venv/bin | Task 5 |
| `run()` with_exit_marker | Task 5 |
| `status()` → live_status + tail; missing → "idle" | Task 5 |
| `all_status()` → ordered list | Task 5 |
| GET /api/dataset/stats | Task 6 |
| GET /api/dataset/files | Task 6 |
| GET /api/dataset/rows?path&offset&limit (ValueError → 400) | Task 6 |
| POST /api/dataset/examples (bad target → 400) | Task 6 |
| GET /api/builders | Task 6 |
| POST /api/builders/run (ValueError → 400) | Task 6 |
| GET /api/builders/{stage} (unknown → 400) | Task 6 |
| Wire both routers in app.py | Task 6 |
| conftest dataset_root fixture with all 9 files | Task 1 |
| test: stats counts match fixture | Task 2 |
| test: files lists 9 w/ counts | Task 2 |
| test: rows sft kind/python/jac extracted | Task 2 |
| test: no `<span` in payload | Task 2 |
| test: rows dpo chosen/rejected | Task 2 |
| test: rows holdout kind | Task 2 |
| test: paging offset/limit/total | Task 2 |
| test: path traversal → 400 | Task 2 |
| test: non-allowlisted → 400 | Task 2 |
| test: append 2 valid sft lines → added 2 | Task 2 |
| test: stats reflect after append | Task 2 |
| test: invalid json line → errors | Task 2 |
| test: dpo missing rejected → error | Task 2 |
| test: bad target → 400 | Task 2 |
| test: GET /api/builders → 13 stages idle | Task 3 |
| test: POST run dataset_stats → running/done | Task 3 |
| test: poll status → done, log has "ran" | Task 3 |
| test: unknown stage → 400 | Task 3 |
| test: already running → message "already running" | Task 3 |
| test: failing jac (exit 2) → failed | Task 3 |
| fake jac binary fixture | Task 3 |

All requirements accounted for. No placeholders. Type names are consistent: `_build_row` returns `dict` throughout (spec says "plain strings, no HTML" — DataRow in the jac source had `py_html`/`jac_html` etc., our Python version uses `python`/`jac`/`chosen`/`rejected`/`raw` as raw strings). The `all_status` field name `stage` is used consistently in `_build_status` and in all tests.
