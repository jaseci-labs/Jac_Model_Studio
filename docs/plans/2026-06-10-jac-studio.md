# Jac Studio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Local chatbot web app ("Jac Studio") to demo the four fine-tuned Gemma/Qwen MLX models with streaming chat, curated prompts, sampling controls, per-response stats, and sequential compare mode.

**Architecture:** Two processes under `web_app/`: a FastAPI server (`web_app/server/`, port 8400) that is the single owner of MLX model state (one resident model, swap = unload→load) and streams tokens over SSE; and a Next.js + shadcn UI (`web_app/ui/`, port 3000) that talks only to the server. Chat history in SQLite. Everything binds 127.0.0.1.

**Tech Stack:** Python 3.14, FastAPI, uvicorn, mlx-lm, sqlite3 (stdlib), pytest, httpx · Next.js (App Router, TS), Tailwind v4, shadcn/ui.

**Spec:** `docs/superpowers/specs/2026-06-10-jac-studio-chatbot-design.md`

---

## Execution context

- **Worktree:** create via `superpowers:using-git-worktrees` off `probe-harness-and-graph-tier`, branch `jac-studio`.
- **Gotcha:** `models/`, `adapters/`, `dataset/` are gitignored → they do NOT exist in the worktree. All code reads them from `JAC_STUDIO_DATA_ROOT`, default `/Users/ayush/Downloads/JaseciLabs/DataGeneration` (the main checkout). Never use relative paths to reach models or the holdout.
- `web_app/test/` already exists (brainstorm mockups) — leave it alone. Add `web_app/test/.superpowers/` to `.gitignore`.
- Server venv: `web_app/server/.venv` (own venv; do not touch repo root `.venv`).
- All `pytest` commands below run from `web_app/server/` using `.venv/bin/pytest`.

## File structure

```
web_app/
  start.sh                  # boots server + ui, Ctrl-C kills both
  smoke.sh                  # curls both ports after boot
  README.md
  server/
    requirements.txt
    config.py               # data root, model registry, sizes, RAM
    model_manager.py        # resident-model singleton, load/unload
    generate.py             # prompt building + real mlx token stream
    sse.py                  # SSE event framing helpers
    db.py                   # SQLite chats/messages
    app.py                  # create_app() + all routes
    prompts.json            # generated curated prompts (committed)
    scripts/build_prompts.py
    tests/
      conftest.py
      test_config.py
      test_model_manager.py
      test_chat_sse.py
      test_db.py
      test_chats_api.py
      test_load_api.py
      test_prompts.py
  ui/                       # create-next-app scaffold
    app/layout.tsx          # dark html class, fonts, metadata
    app/page.tsx            # assembles shell
    app/globals.css         # monochrome theme + schematic utilities
    lib/api.ts              # types + REST + SSE stream client
    lib/use-studio.ts       # all app state + send/compare logic
    components/sidebar.tsx
    components/model-pill.tsx
    components/thread.tsx   # messages, code blocks, stats lines
    components/composer.tsx # input + category chips
    components/rail.tsx     # prompt library, sliders, last-run stats
    components/offline.tsx  # backend-down panel
```

---

### Task 1: Server scaffold, config, `/api/models`

**Files:**
- Create: `web_app/server/requirements.txt`
- Create: `web_app/server/config.py`
- Create: `web_app/server/app.py`
- Create: `web_app/server/tests/conftest.py`
- Test: `web_app/server/tests/test_config.py`

- [ ] **Step 1: Create venv and install deps**

```bash
cd web_app/server
cat > requirements.txt <<'EOF'
fastapi>=0.115
uvicorn>=0.32
mlx-lm>=0.21
pytest>=8
httpx>=0.27
EOF
python3 -m venv .venv
.venv/bin/pip install -U pip
.venv/bin/pip install -r requirements.txt
```

Expected: installs cleanly (mlx-lm is the slow one).

- [ ] **Step 2: Write failing tests for config**

`web_app/server/tests/conftest.py`:

```python
import os
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
```

`web_app/server/tests/test_config.py`:

```python
import config


def test_registry_has_four_models():
    ids = [m["id"] for m in config.MODELS]
    assert ids == ["qwen-dpo", "gemma-dpo", "qwen-sft", "gemma-sft"]


def test_model_by_id():
    assert config.model_by_id("qwen-dpo")["label"] == "Qwen · DPO"
    assert config.model_by_id("nope") is None


def test_data_root_env_override(fake_root):
    assert config.data_root() == fake_root


def test_model_path_and_availability(fake_root):
    m = config.model_by_id("qwen-dpo")
    assert config.model_path(m) == fake_root / "models/qwen-jac-dpo-fused-q8"
    assert config.model_available(m) is True
    assert config.model_available(config.model_by_id("qwen-sft")) is False


def test_dir_size_gb(fake_root):
    m = config.model_by_id("qwen-dpo")
    assert config.dir_size_gb(config.model_path(m)) == round(1000 / 1e9, 2)


def test_total_ram_gb_positive():
    assert config.total_ram_gb() > 0
```

- [ ] **Step 3: Run tests, verify they fail**

Run: `.venv/bin/pytest tests/test_config.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'config'`

- [ ] **Step 4: Implement `config.py`**

```python
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
```

- [ ] **Step 5: Run tests, verify they pass**

Run: `.venv/bin/pytest tests/test_config.py -v`
Expected: 6 PASS

- [ ] **Step 6: Write failing test for `/api/models`**

Append to `web_app/server/tests/test_config.py`:

```python
from fastapi.testclient import TestClient

import app as app_module


def test_models_endpoint(fake_root):
    client = TestClient(app_module.create_app())
    r = client.get("/api/models")
    assert r.status_code == 200
    body = r.json()
    assert [m["id"] for m in body["models"]] == ["qwen-dpo", "gemma-dpo", "qwen-sft", "gemma-sft"]
    assert body["models"][0]["available"] is True
    assert body["models"][2]["available"] is False
    assert body["loaded"] is None
    assert body["ram_gb"] > 0
    assert body["resident_gb"] is None
```

Run: `.venv/bin/pytest tests/test_config.py::test_models_endpoint -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app'`

- [ ] **Step 7: Implement minimal `app.py`**

```python
from fastapi import FastAPI

import config


def create_app(loader=None, stream_fn=None) -> FastAPI:
    app = FastAPI(title="Jac Studio")
    app.state.loader = loader
    app.state.stream_fn = stream_fn

    @app.get("/api/models")
    def models():
        out = []
        for m in config.MODELS:
            avail = config.model_available(m)
            out.append({
                "id": m["id"],
                "label": m["label"],
                "available": avail,
                "size_gb": config.dir_size_gb(config.model_path(m)) if avail else None,
            })
        return {
            "models": out,
            "loaded": None,
            "ram_gb": config.total_ram_gb(),
            "resident_gb": None,
        }

    return app


app = create_app()
```

(`loaded`/`resident_gb` get wired to the real manager in Task 2.)

- [ ] **Step 8: Run all tests, verify pass**

Run: `.venv/bin/pytest -v`
Expected: 7 PASS

- [ ] **Step 9: Commit**

```bash
git add web_app/server
git commit -m "feat(studio): server scaffold, model registry, /api/models"
```

---

### Task 2: ModelManager (resident model, load/unload)

**Files:**
- Create: `web_app/server/model_manager.py`
- Modify: `web_app/server/app.py` (wire manager into create_app + /api/models)
- Test: `web_app/server/tests/test_model_manager.py`

- [ ] **Step 1: Write failing tests**

`web_app/server/tests/test_model_manager.py`:

```python
from model_manager import ModelManager


def make_loader(calls):
    def loader(path):
        calls.append(path)
        return ("MODEL:" + path, "TOK:" + path)
    return loader


def test_load_sets_state():
    calls = []
    mgr = ModelManager(loader=make_loader(calls))
    secs = mgr.load_sync("qwen-dpo", "/fake/qwen")
    assert mgr.current_id == "qwen-dpo"
    assert mgr.model == "MODEL:/fake/qwen"
    assert mgr.tokenizer == "TOK:/fake/qwen"
    assert secs >= 0.0
    assert calls == ["/fake/qwen"]


def test_load_same_model_is_noop():
    calls = []
    mgr = ModelManager(loader=make_loader(calls))
    mgr.load_sync("qwen-dpo", "/fake/qwen")
    mgr.load_sync("qwen-dpo", "/fake/qwen")
    assert calls == ["/fake/qwen"]


def test_swap_unloads_first():
    calls = []
    mgr = ModelManager(loader=make_loader(calls))
    mgr.load_sync("qwen-dpo", "/fake/qwen")
    mgr.load_sync("gemma-dpo", "/fake/gemma")
    assert mgr.current_id == "gemma-dpo"
    assert calls == ["/fake/qwen", "/fake/gemma"]


def test_unload_clears_state():
    mgr = ModelManager(loader=make_loader([]))
    mgr.load_sync("qwen-dpo", "/fake/qwen")
    mgr.unload()
    assert mgr.current_id is None
    assert mgr.model is None
    assert mgr.tokenizer is None
```

- [ ] **Step 2: Run tests, verify fail**

Run: `.venv/bin/pytest tests/test_model_manager.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'model_manager'`

- [ ] **Step 3: Implement `model_manager.py`**

```python
"""Single resident MLX model. 48GB box: exactly one model in memory.

Swap = drop references + gc + mx.clear_cache(), then mlx_lm.load() the new one.
The loader is injectable so tests never touch mlx.
"""
import asyncio
import gc
import time


def _mlx_loader(path: str):
    import mlx_lm  # lazy: keep test imports mlx-free
    return mlx_lm.load(path)


class ModelManager:
    def __init__(self, loader=None):
        self._loader = loader or _mlx_loader
        self.current_id: str | None = None
        self.model = None
        self.tokenizer = None
        self.load_seconds: float = 0.0
        self.lock = asyncio.Lock()  # one load/generation at a time

    def unload(self) -> None:
        self.model = None
        self.tokenizer = None
        self.current_id = None
        gc.collect()
        try:
            import mlx.core as mx
            mx.clear_cache()
        except ImportError:
            pass

    def load_sync(self, model_id: str, path: str) -> float:
        """Blocking. Returns seconds spent loading (0.0 if already resident)."""
        if self.current_id == model_id:
            return 0.0
        if self.current_id is not None:
            self.unload()
        t0 = time.monotonic()
        self.model, self.tokenizer = self._loader(path)
        self.load_seconds = round(time.monotonic() - t0, 1)
        self.current_id = model_id
        return self.load_seconds
```

- [ ] **Step 4: Run tests, verify pass**

Run: `.venv/bin/pytest tests/test_model_manager.py -v`
Expected: 4 PASS

- [ ] **Step 5: Wire manager into app**

In `app.py`, replace `create_app` state setup and the `loaded`/`resident_gb` fields:

```python
from fastapi import FastAPI

import config
from model_manager import ModelManager


def create_app(loader=None, stream_fn=None) -> FastAPI:
    app = FastAPI(title="Jac Studio")
    app.state.manager = ModelManager(loader=loader)
    app.state.stream_fn = stream_fn

    @app.get("/api/models")
    def models():
        mgr = app.state.manager
        out = []
        resident_gb = None
        for m in config.MODELS:
            avail = config.model_available(m)
            size = config.dir_size_gb(config.model_path(m)) if avail else None
            if m["id"] == mgr.current_id:
                resident_gb = size
            out.append({"id": m["id"], "label": m["label"], "available": avail, "size_gb": size})
        return {
            "models": out,
            "loaded": mgr.current_id,
            "ram_gb": config.total_ram_gb(),
            "resident_gb": resident_gb,
        }

    return app


app = create_app()
```

- [ ] **Step 6: Add loaded-state test, run all**

Append to `tests/test_config.py`:

```python
def test_models_endpoint_reports_loaded(fake_root):
    a = app_module.create_app(loader=lambda p: ("m", "t"))
    client = TestClient(a)
    a.state.manager.load_sync("qwen-dpo", str(fake_root / "models/qwen-jac-dpo-fused-q8"))
    body = client.get("/api/models").json()
    assert body["loaded"] == "qwen-dpo"
    assert body["resident_gb"] is not None
```

Run: `.venv/bin/pytest -v`
Expected: all PASS

- [ ] **Step 7: Commit**

```bash
git add web_app/server
git commit -m "feat(studio): ModelManager with injectable loader, loaded state in /api/models"
```

---

### Task 3: SSE framing, prompt building, `/api/chat` streaming

**Files:**
- Create: `web_app/server/sse.py`
- Create: `web_app/server/generate.py`
- Modify: `web_app/server/app.py`
- Test: `web_app/server/tests/test_chat_sse.py`

- [ ] **Step 1: Write failing tests**

`web_app/server/tests/test_chat_sse.py`:

```python
import json

from fastapi.testclient import TestClient

import app as app_module
from generate import build_prompt
from sse import sse


class FakeTok:
    def __init__(self):
        self.seen = None

    def apply_chat_template(self, messages, add_generation_prompt=False):
        self.seen = (messages, add_generation_prompt)
        return [1, 2, 3]


def fake_stream(model, tokenizer, messages, temperature, top_p, max_tokens):
    yield "Hello", 1, 12.0
    yield " world", 2, 12.5


def make_client():
    a = app_module.create_app(loader=lambda p: ("m", FakeTok()), stream_fn=fake_stream)
    return TestClient(a), a


def events(resp):
    out = []
    for line in resp.iter_lines():
        if line.startswith("data: "):
            out.append(json.loads(line[len("data: "):]))
    return out


def test_sse_framing():
    assert sse({"a": 1}) == 'data: {"a": 1}\n\n'


def test_build_prompt_uses_chat_template():
    tok = FakeTok()
    msgs = [{"role": "user", "content": "hi"}]
    assert build_prompt(tok, msgs) == [1, 2, 3]
    assert tok.seen == (msgs, True)


def test_chat_streams_tokens_then_stats(fake_root):
    client, a = make_client()
    with client.stream("POST", "/api/chat", json={
        "model_id": "qwen-dpo",
        "messages": [{"role": "user", "content": "hi"}],
    }) as r:
        assert r.status_code == 200
        evs = events(r)
    types = [e["type"] for e in evs]
    assert types[-2:] == ["stats", "done"]
    toks = [e["text"] for e in evs if e["type"] == "token"]
    assert "".join(toks) == "Hello world"
    stats = [e for e in evs if e["type"] == "stats"][0]
    assert stats["gen_tokens"] == 2
    assert stats["tps"] == 12.5
    assert stats["model_id"] == "qwen-dpo"
    assert "seconds" in stats and "load_seconds" in stats
    # auto-load happened and emitted a ready event
    assert any(e["type"] == "load" and e["status"] == "ready" for e in evs)
    assert a.state.manager.current_id == "qwen-dpo"


def test_chat_unknown_model_errors(fake_root):
    client, _ = make_client()
    with client.stream("POST", "/api/chat", json={
        "model_id": "nope",
        "messages": [{"role": "user", "content": "hi"}],
    }) as r:
        evs = events(r)
    assert evs[0]["type"] == "error"
    assert "unknown model" in evs[0]["message"]


def test_chat_unavailable_model_errors(fake_root):
    client, _ = make_client()
    with client.stream("POST", "/api/chat", json={
        "model_id": "qwen-sft",  # not on disk in fake_root
        "messages": [{"role": "user", "content": "hi"}],
    }) as r:
        evs = events(r)
    assert evs[0]["type"] == "error"
    assert "not found on disk" in evs[0]["message"]


def test_chat_generation_exception_becomes_error_event(fake_root):
    def boom(model, tokenizer, messages, temperature, top_p, max_tokens):
        yield "par", 1, 5.0
        raise RuntimeError("kaboom")

    a = app_module.create_app(loader=lambda p: ("m", FakeTok()), stream_fn=boom)
    client = TestClient(a)
    with client.stream("POST", "/api/chat", json={
        "model_id": "qwen-dpo",
        "messages": [{"role": "user", "content": "hi"}],
    }) as r:
        evs = events(r)
    assert any(e["type"] == "token" for e in evs)
    assert evs[-1]["type"] == "error"
    assert "kaboom" in evs[-1]["message"]
```

- [ ] **Step 2: Run tests, verify fail**

Run: `.venv/bin/pytest tests/test_chat_sse.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'generate'` (then `sse`)

- [ ] **Step 3: Implement `sse.py`**

```python
import json


def sse(obj: dict) -> str:
    return f"data: {json.dumps(obj)}\n\n"
```

- [ ] **Step 4: Implement `generate.py`**

```python
"""Prompt building + the real mlx token stream.

Mirrors srccurrent/jacgen/eval_probe.jac: full message history through the
tokenizer chat template (no system prompt — training data had none), then
mlx_lm.stream_generate.
"""


def build_prompt(tokenizer, messages: list[dict]):
    return tokenizer.apply_chat_template(messages, add_generation_prompt=True)


def stream_tokens(model, tokenizer, messages, temperature, top_p, max_tokens):
    """Blocking generator yielding (text, generation_tokens, generation_tps)."""
    import mlx_lm
    from mlx_lm.sample_utils import make_sampler

    sampler = make_sampler(temp=temperature, top_p=top_p)
    ptoks = build_prompt(tokenizer, messages)
    for resp in mlx_lm.stream_generate(model, tokenizer, ptoks,
                                       max_tokens=max_tokens, sampler=sampler):
        yield resp.text, resp.generation_tokens, resp.generation_tps
```

- [ ] **Step 5: Implement `/api/chat` in `app.py`**

Add imports and the route (keep Task 2 content):

```python
import asyncio
import time

from fastapi import FastAPI
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

import config
import generate
from model_manager import ModelManager
from sse import sse


class ChatMessage(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    model_config = {"protected_namespaces": ()}  # allow model_id field
    model_id: str
    messages: list[ChatMessage]
    temperature: float = 0.2
    top_p: float = 0.9
    max_tokens: int = 1024
    chat_id: int | None = None
    pair_group: str | None = None
    persist_user: bool = True
```

Inside `create_app`, after the `/api/models` route:

```python
    async def load_events(mgr, model_id: str, path: str):
        """Load model in executor; heartbeat 'loading' events each second."""
        loop = asyncio.get_running_loop()
        fut = loop.run_in_executor(None, mgr.load_sync, model_id, str(path))
        t0 = time.monotonic()
        while not fut.done():
            yield sse({"type": "load", "status": "loading", "model_id": model_id,
                       "elapsed": round(time.monotonic() - t0, 1)})
            try:
                await asyncio.wait_for(asyncio.shield(fut), timeout=1.0)
            except asyncio.TimeoutError:
                pass
        secs = await fut  # re-raises load errors
        yield sse({"type": "load", "status": "ready", "model_id": model_id, "seconds": secs})

    @app.post("/api/chat")
    async def chat(req: ChatRequest):
        mgr = app.state.manager
        stream_fn = app.state.stream_fn or generate.stream_tokens

        async def gen():
            m = config.model_by_id(req.model_id)
            if m is None:
                yield sse({"type": "error", "message": f"unknown model: {req.model_id}"})
                return
            if not config.model_available(m):
                yield sse({"type": "error",
                           "message": f"model not found on disk: {config.model_path(m)}"})
                return

            async with mgr.lock:
                try:
                    if mgr.current_id != req.model_id:
                        async for ev in load_events(mgr, req.model_id, config.model_path(m)):
                            yield ev
                except Exception as e:
                    yield sse({"type": "error", "message": f"load failed: {e}"})
                    return

                loop = asyncio.get_running_loop()
                q: asyncio.Queue = asyncio.Queue()
                msgs = [mm.model_dump() for mm in req.messages]

                def worker():
                    try:
                        for text, ntok, tps in stream_fn(mgr.model, mgr.tokenizer, msgs,
                                                         req.temperature, req.top_p,
                                                         req.max_tokens):
                            loop.call_soon_threadsafe(q.put_nowait, ("token", text, ntok, tps))
                        loop.call_soon_threadsafe(q.put_nowait, ("end", None, None, None))
                    except Exception as e:  # surfaced as SSE error event
                        loop.call_soon_threadsafe(q.put_nowait, ("error", str(e), None, None))

                loop.run_in_executor(None, worker)
                t0 = time.monotonic()
                full, gen_tokens, tps = "", 0, 0.0
                while True:
                    kind, text, ntok, ntps = await q.get()
                    if kind == "token":
                        full += text
                        gen_tokens, tps = ntok, ntps
                        yield sse({"type": "token", "text": text})
                    elif kind == "error":
                        yield sse({"type": "error", "message": text})
                        return
                    else:
                        break
                stats = {"type": "stats", "model_id": req.model_id,
                         "gen_tokens": gen_tokens, "tps": tps,
                         "seconds": round(time.monotonic() - t0, 1),
                         "load_seconds": mgr.load_seconds}
                yield sse(stats)
                yield sse({"type": "done"})

        return StreamingResponse(gen(), media_type="text/event-stream")
```

- [ ] **Step 6: Run tests, verify pass**

Run: `.venv/bin/pytest -v`
Expected: all PASS (chat tests included)

- [ ] **Step 7: Commit**

```bash
git add web_app/server
git commit -m "feat(studio): SSE /api/chat with auto-load heartbeats, stats event, error events"
```

---

### Task 4: SQLite store

**Files:**
- Create: `web_app/server/db.py`
- Test: `web_app/server/tests/test_db.py`

- [ ] **Step 1: Write failing tests**

`web_app/server/tests/test_db.py`:

```python
import pytest

import db


@pytest.fixture(autouse=True)
def tmp_db(tmp_path, monkeypatch):
    monkeypatch.setenv("JAC_STUDIO_DB", str(tmp_path / "chats.db"))
    db.init_db()


def test_create_and_list_chats():
    c = db.create_chat("walker for BFS")
    assert c["id"] == 1
    assert c["title"] == "walker for BFS"
    chats = db.list_chats()
    assert len(chats) == 1
    assert chats[0]["title"] == "walker for BFS"


def test_rename_and_delete():
    c = db.create_chat("old")
    db.rename_chat(c["id"], "new")
    assert db.get_chat(c["id"])["title"] == "new"
    db.delete_chat(c["id"])
    assert db.get_chat(c["id"]) is None
    assert db.list_chats() == []


def test_messages_roundtrip():
    c = db.create_chat("t")
    db.add_message(c["id"], "user", "convert this")
    db.add_message(c["id"], "assistant", "node Person {}", model_id="qwen-dpo",
                   stats={"tps": 42.0, "gen_tokens": 312}, pair_group="pg1")
    msgs = db.get_messages(c["id"])
    assert [m["role"] for m in msgs] == ["user", "assistant"]
    assert msgs[1]["model_id"] == "qwen-dpo"
    assert msgs[1]["stats"]["tps"] == 42.0
    assert msgs[1]["pair_group"] == "pg1"
    assert msgs[0]["stats"] is None


def test_delete_chat_cascades_messages():
    c = db.create_chat("t")
    db.add_message(c["id"], "user", "hi")
    db.delete_chat(c["id"])
    assert db.get_messages(c["id"]) == []
```

- [ ] **Step 2: Run tests, verify fail**

Run: `.venv/bin/pytest tests/test_db.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'db'`

- [ ] **Step 3: Implement `db.py`**

```python
"""SQLite chat history. Connection per call — low traffic, no pooling needed."""
import json
import os
import sqlite3
from pathlib import Path


def db_path() -> Path:
    p = Path(os.environ.get("JAC_STUDIO_DB",
                            Path(__file__).parent / "data" / "chats.db"))
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def connect() -> sqlite3.Connection:
    con = sqlite3.connect(db_path())
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    return con


def init_db() -> None:
    with connect() as con:
        con.executescript("""
        CREATE TABLE IF NOT EXISTS chats (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            chat_id INTEGER NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            model_id TEXT,
            stats_json TEXT,
            pair_group TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        """)


def _row_chat(r) -> dict:
    return {"id": r["id"], "title": r["title"],
            "created_at": r["created_at"], "updated_at": r["updated_at"]}


def create_chat(title: str) -> dict:
    with connect() as con:
        cur = con.execute("INSERT INTO chats (title) VALUES (?)", (title,))
        r = con.execute("SELECT * FROM chats WHERE id=?", (cur.lastrowid,)).fetchone()
        return _row_chat(r)


def list_chats() -> list[dict]:
    with connect() as con:
        rs = con.execute("SELECT * FROM chats ORDER BY updated_at DESC").fetchall()
        return [_row_chat(r) for r in rs]


def get_chat(chat_id: int) -> dict | None:
    with connect() as con:
        r = con.execute("SELECT * FROM chats WHERE id=?", (chat_id,)).fetchone()
        return _row_chat(r) if r else None


def rename_chat(chat_id: int, title: str) -> None:
    with connect() as con:
        con.execute("UPDATE chats SET title=?, updated_at=datetime('now') WHERE id=?",
                    (title, chat_id))


def delete_chat(chat_id: int) -> None:
    with connect() as con:
        con.execute("DELETE FROM chats WHERE id=?", (chat_id,))


def add_message(chat_id: int, role: str, content: str, model_id: str | None = None,
                stats: dict | None = None, pair_group: str | None = None) -> dict:
    with connect() as con:
        cur = con.execute(
            "INSERT INTO messages (chat_id, role, content, model_id, stats_json, pair_group)"
            " VALUES (?,?,?,?,?,?)",
            (chat_id, role, content, model_id,
             json.dumps(stats) if stats is not None else None, pair_group))
        con.execute("UPDATE chats SET updated_at=datetime('now') WHERE id=?", (chat_id,))
        r = con.execute("SELECT * FROM messages WHERE id=?", (cur.lastrowid,)).fetchone()
        return _row_msg(r)


def _row_msg(r) -> dict:
    return {"id": r["id"], "chat_id": r["chat_id"], "role": r["role"],
            "content": r["content"], "model_id": r["model_id"],
            "stats": json.loads(r["stats_json"]) if r["stats_json"] else None,
            "pair_group": r["pair_group"], "created_at": r["created_at"]}


def get_messages(chat_id: int) -> list[dict]:
    with connect() as con:
        rs = con.execute("SELECT * FROM messages WHERE chat_id=? ORDER BY id",
                         (chat_id,)).fetchall()
        return [_row_msg(r) for r in rs]
```

- [ ] **Step 4: Run tests, verify pass**

Run: `.venv/bin/pytest tests/test_db.py -v`
Expected: 4 PASS

- [ ] **Step 5: Commit**

```bash
git add web_app/server
git commit -m "feat(studio): SQLite chat history store"
```

---

### Task 5: Chats CRUD endpoints + persistence in `/api/chat`

**Files:**
- Modify: `web_app/server/app.py`
- Modify: `web_app/server/tests/conftest.py` (tmp DB everywhere)
- Test: `web_app/server/tests/test_chats_api.py`

- [ ] **Step 1: Make all API tests use a tmp DB**

Append to `web_app/server/tests/conftest.py`:

```python
@pytest.fixture(autouse=True)
def tmp_db_global(tmp_path, monkeypatch):
    monkeypatch.setenv("JAC_STUDIO_DB", str(tmp_path / "chats.db"))
```

(`test_db.py`'s own fixture stays; double-setting the env is harmless.)

- [ ] **Step 2: Write failing tests**

`web_app/server/tests/test_chats_api.py`:

```python
import json

from fastapi.testclient import TestClient

import app as app_module
import db


class FakeTok:
    def apply_chat_template(self, messages, add_generation_prompt=False):
        return [1]


def fake_stream(model, tokenizer, messages, temperature, top_p, max_tokens):
    yield "node Person {}", 3, 40.0


def make_client():
    return TestClient(app_module.create_app(loader=lambda p: ("m", FakeTok()),
                                            stream_fn=fake_stream))


def test_chats_crud(fake_root):
    client = make_client()
    r = client.post("/api/chats", json={"title": "walker for BFS"})
    assert r.status_code == 200
    cid = r.json()["id"]

    assert client.get("/api/chats").json()[0]["title"] == "walker for BFS"

    r = client.patch(f"/api/chats/{cid}", json={"title": "renamed"})
    assert r.status_code == 200
    assert client.get(f"/api/chats/{cid}").json()["chat"]["title"] == "renamed"

    assert client.delete(f"/api/chats/{cid}").status_code == 200
    assert client.get("/api/chats").json() == []
    assert client.get(f"/api/chats/{cid}").status_code == 404


def test_chat_persists_messages(fake_root):
    client = make_client()
    cid = client.post("/api/chats", json={"title": "t"}).json()["id"]
    with client.stream("POST", "/api/chat", json={
        "model_id": "qwen-dpo",
        "messages": [{"role": "user", "content": "convert this"}],
        "chat_id": cid,
        "pair_group": "pg1",
    }) as r:
        list(r.iter_lines())
    msgs = client.get(f"/api/chats/{cid}").json()["messages"]
    assert [m["role"] for m in msgs] == ["user", "assistant"]
    assert msgs[0]["content"] == "convert this"
    assert msgs[1]["content"] == "node Person {}"
    assert msgs[1]["model_id"] == "qwen-dpo"
    assert msgs[1]["stats"]["gen_tokens"] == 3
    assert msgs[1]["pair_group"] == "pg1"


def test_chat_persist_user_false_skips_user_row(fake_root):
    client = make_client()
    cid = client.post("/api/chats", json={"title": "t"}).json()["id"]
    with client.stream("POST", "/api/chat", json={
        "model_id": "qwen-dpo",
        "messages": [{"role": "user", "content": "compare leg B"}],
        "chat_id": cid,
        "persist_user": False,
    }) as r:
        list(r.iter_lines())
    msgs = client.get(f"/api/chats/{cid}").json()["messages"]
    assert [m["role"] for m in msgs] == ["assistant"]


def test_chat_without_chat_id_persists_nothing(fake_root):
    client = make_client()
    with client.stream("POST", "/api/chat", json={
        "model_id": "qwen-dpo",
        "messages": [{"role": "user", "content": "hi"}],
    }) as r:
        list(r.iter_lines())
    assert client.get("/api/chats").json() == []
```

- [ ] **Step 3: Run tests, verify fail**

Run: `.venv/bin/pytest tests/test_chats_api.py -v`
Expected: FAIL — 404 on `/api/chats` routes

- [ ] **Step 4: Implement CRUD routes + persistence**

In `app.py` add:

```python
import db
from fastapi import HTTPException


class ChatCreate(BaseModel):
    title: str


class ChatRename(BaseModel):
    title: str
```

Inside `create_app`, call `db.init_db()` first line, then add routes:

```python
    db.init_db()

    @app.get("/api/chats")
    def chats_list():
        return db.list_chats()

    @app.post("/api/chats")
    def chats_create(body: ChatCreate):
        return db.create_chat(body.title)

    @app.get("/api/chats/{chat_id}")
    def chats_get(chat_id: int):
        chat = db.get_chat(chat_id)
        if chat is None:
            raise HTTPException(404)
        return {"chat": chat, "messages": db.get_messages(chat_id)}

    @app.patch("/api/chats/{chat_id}")
    def chats_rename(chat_id: int, body: ChatRename):
        if db.get_chat(chat_id) is None:
            raise HTTPException(404)
        db.rename_chat(chat_id, body.title)
        return {"ok": True}

    @app.delete("/api/chats/{chat_id}")
    def chats_delete(chat_id: int):
        db.delete_chat(chat_id)
        return {"ok": True}
```

In the `chat` route's `gen()`, persist after the stats event (best-effort — never crash the stream). Replace the final two `yield` lines with:

```python
                yield sse(stats)
                if req.chat_id is not None:
                    try:
                        if req.persist_user and req.messages:
                            db.add_message(req.chat_id, "user",
                                           req.messages[-1].content)
                        db.add_message(req.chat_id, "assistant", full,
                                       model_id=req.model_id, stats=stats,
                                       pair_group=req.pair_group)
                    except Exception as e:
                        print(f"history write failed: {e}")
                yield sse({"type": "done"})
```

- [ ] **Step 5: Run all tests, verify pass**

Run: `.venv/bin/pytest -v`
Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add web_app/server
git commit -m "feat(studio): chats CRUD API + best-effort history persistence"
```

---

### Task 6: `/api/load` endpoint

**Files:**
- Modify: `web_app/server/app.py`
- Test: `web_app/server/tests/test_load_api.py`

- [ ] **Step 1: Write failing tests**

`web_app/server/tests/test_load_api.py`:

```python
import json

from fastapi.testclient import TestClient

import app as app_module


def events(resp):
    return [json.loads(l[len("data: "):]) for l in resp.iter_lines()
            if l.startswith("data: ")]


def make_app():
    return app_module.create_app(loader=lambda p: ("m", "t"))


def test_load_streams_ready(fake_root):
    a = make_app()
    client = TestClient(a)
    with client.stream("POST", "/api/load", json={"model_id": "qwen-dpo"}) as r:
        evs = events(r)
    assert evs[-1]["type"] == "load"
    assert evs[-1]["status"] == "ready"
    assert a.state.manager.current_id == "qwen-dpo"


def test_load_unknown_model(fake_root):
    client = TestClient(make_app())
    with client.stream("POST", "/api/load", json={"model_id": "nope"}) as r:
        evs = events(r)
    assert evs[0]["type"] == "error"


def test_load_failure_is_error_event(fake_root):
    def bad_loader(path):
        raise RuntimeError("OOM")
    a = app_module.create_app(loader=bad_loader)
    client = TestClient(a)
    with client.stream("POST", "/api/load", json={"model_id": "qwen-dpo"}) as r:
        evs = events(r)
    assert evs[-1]["type"] == "error"
    assert "OOM" in evs[-1]["message"]
    assert a.state.manager.current_id is None
```

- [ ] **Step 2: Run tests, verify fail**

Run: `.venv/bin/pytest tests/test_load_api.py -v`
Expected: FAIL — 404

- [ ] **Step 3: Implement route**

In `app.py` add model + route inside `create_app`:

```python
class LoadRequest(BaseModel):
    model_config = {"protected_namespaces": ()}
    model_id: str
```

```python
    @app.post("/api/load")
    async def load(req: LoadRequest):
        mgr = app.state.manager

        async def gen():
            m = config.model_by_id(req.model_id)
            if m is None:
                yield sse({"type": "error", "message": f"unknown model: {req.model_id}"})
                return
            if not config.model_available(m):
                yield sse({"type": "error",
                           "message": f"model not found on disk: {config.model_path(m)}"})
                return
            async with mgr.lock:
                try:
                    async for ev in load_events(mgr, req.model_id, config.model_path(m)):
                        yield ev
                except Exception as e:
                    mgr.unload()
                    yield sse({"type": "error", "message": f"load failed: {e}"})

        return StreamingResponse(gen(), media_type="text/event-stream")
```

Note: `load_events` is already defined inside `create_app` (Task 3) — keep it defined above both routes. Also wrap the chat route's load with the same `mgr.unload()` on failure:

```python
                except Exception as e:
                    mgr.unload()
                    yield sse({"type": "error", "message": f"load failed: {e}"})
                    return
```

- [ ] **Step 4: Run all tests, verify pass**

Run: `.venv/bin/pytest -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add web_app/server
git commit -m "feat(studio): /api/load SSE endpoint with failure cleanup"
```

---

### Task 7: Curated prompts + `/api/prompts`

**Files:**
- Create: `web_app/server/scripts/build_prompts.py`
- Create: `web_app/server/prompts.json` (generated, committed)
- Modify: `web_app/server/app.py`
- Test: `web_app/server/tests/test_prompts.py`

- [ ] **Step 1: Write the generator script**

`web_app/server/scripts/build_prompts.py`:

```python
"""Build prompts.json: 12 holdout conversions + handwritten idiom/explain/general.

Run from web_app/server/:  .venv/bin/python scripts/build_prompts.py
Reads the holdout from JAC_STUDIO_DATA_ROOT (models repo), writes prompts.json.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import config

IDIOMS = [
    "Write a Jac walker named Greeter that visits every node connected to root and prints each node's name.",
    "Define a Jac node type Person with has fields name: str and age: int, plus an ability that prints a greeting when a walker visits.",
    "Write Jac code that creates 5 City nodes, connects them in a chain with ++> edges, then spawns a walker that counts them.",
    "Show idiomatic Jac for a typed edge: define an edge Road with has miles: float and connect two City nodes with it.",
    "Write a Jac object (obj) called Stack with push, pop, and peek methods backed by a list.",
    "Write a Jac walker that does breadth-first traversal from root and collects node names into a list, then reports it on exit.",
    "Use a Jac impl block: declare def fib(n: int) -> int; in one place and implement it in an impl block.",
    "Write Jac with entry code that filters a list of numbers with a comprehension and prints the evens.",
]

EXPLAIN = [
    "Explain what this Jac code does:\n\n```jac\nwalker Counter {\n    has count: int = 0;\n    can count_nodes with `root entry {\n        visit [-->];\n    }\n    can tally with entry {\n        self.count += 1;\n    }\n}\n```",
    "What does the ++> operator do in Jac? Show a small example.",
    "Explain the difference between a node, an edge, and a walker in Jac's object-spatial model.",
    "What does this Jac do?\n\n```jac\nnode Person {\n    has name: str;\n    can greet with Visitor entry {\n        print(f\"hello {self.name}\");\n    }\n}\n```",
    "Explain what an impl block is in Jac and why you would separate declaration from implementation.",
    "What is the root node in Jac and how do walkers start from it?",
]

GENERAL = [
    "Write a Python function that merges two sorted lists into one sorted list without using sort().",
    "Explain the difference between BFS and DFS and when you'd pick each.",
    "Write a Python function to check whether a string is a valid palindrome, ignoring case and punctuation.",
    "What does this regex match: ^\\d{3}-\\d{2}-\\d{4}$ ? Suggest a clearer alternative.",
    "Write a Python generator that yields the running average of a stream of numbers.",
]


def pick_conversions(n=12) -> list[str]:
    holdout = config.data_root() / "dataset/eval_holdout/conversion.jsonl"
    recs = [json.loads(l) for l in holdout.read_text().splitlines() if l.strip()]
    stride = max(1, len(recs) // n)
    picked = recs[::stride][:n]
    return [r["prompt"] for r in picked]


def main():
    out = {"categories": [
        {"id": "py2jac", "label": "Python → Jac", "prompts": pick_conversions()},
        {"id": "idioms", "label": "Jac idioms", "prompts": IDIOMS},
        {"id": "explain", "label": "Explain Jac", "prompts": EXPLAIN},
        {"id": "general", "label": "General code", "prompts": GENERAL},
    ]}
    dest = Path(__file__).resolve().parents[1] / "prompts.json"
    dest.write_text(json.dumps(out, indent=2))
    counts = {c["id"]: len(c["prompts"]) for c in out["categories"]}
    print(f"wrote {dest} — {counts}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Generate prompts.json**

Run: `.venv/bin/python scripts/build_prompts.py`
Expected: `wrote .../prompts.json — {'py2jac': 12, 'idioms': 8, 'explain': 6, 'general': 5}`

- [ ] **Step 3: Write failing test for endpoint**

`web_app/server/tests/test_prompts.py`:

```python
from fastapi.testclient import TestClient

import app as app_module


def test_prompts_endpoint():
    client = TestClient(app_module.create_app())
    body = client.get("/api/prompts").json()
    ids = [c["id"] for c in body["categories"]]
    assert ids == ["py2jac", "idioms", "explain", "general"]
    for c in body["categories"]:
        assert len(c["prompts"]) > 0
        assert all(isinstance(p, str) for p in c["prompts"])
```

Run: `.venv/bin/pytest tests/test_prompts.py -v`
Expected: FAIL — 404

- [ ] **Step 4: Implement route**

In `app.py` (inside `create_app`):

```python
    @app.get("/api/prompts")
    def prompts():
        p = Path(__file__).parent / "prompts.json"
        return json.loads(p.read_text())
```

with imports at top: `import json` and `from pathlib import Path`.

- [ ] **Step 5: Run all tests, verify pass**

Run: `.venv/bin/pytest -v`
Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add web_app/server
git commit -m "feat(studio): curated prompt library + /api/prompts"
```

---

### Task 8: UI scaffold + monochrome theme

**Files:**
- Create: `web_app/ui/` (create-next-app scaffold)
- Modify: `web_app/ui/app/globals.css`
- Modify: `web_app/ui/app/layout.tsx`
- Modify: `.gitignore` (repo root)

- [ ] **Step 1: Scaffold Next.js + shadcn**

```bash
cd web_app
npx create-next-app@latest ui --ts --tailwind --eslint --app --no-src-dir \
  --import-alias "@/*" --use-npm --turbopack
cd ui
npx shadcn@latest init --yes --base-color neutral
npx shadcn@latest add button slider popover scroll-area separator textarea tooltip
```

Accept defaults on any extra interactive prompts. Verify: `npm run build` succeeds.

- [ ] **Step 2: Repo .gitignore additions**

Append to repo root `.gitignore`:

```
web_app/ui/node_modules/
web_app/ui/.next/
web_app/server/.venv/
web_app/server/data/
web_app/test/.superpowers/
```

- [ ] **Step 3: Monochrome theme**

In `web_app/ui/app/globals.css`, replace the generated `:root` and `.dark` CSS-variable blocks with a single dark monochrome set (we force dark mode; keep the `@theme inline` block and the rest of the generated file intact):

```css
:root, .dark {
  --background: #0a0a0a;
  --foreground: #ededed;
  --card: #0d0d0d;
  --card-foreground: #ededed;
  --popover: #121212;
  --popover-foreground: #ededed;
  --primary: #ededed;
  --primary-foreground: #0a0a0a;
  --secondary: #1a1a1a;
  --secondary-foreground: #ededed;
  --muted: #161616;
  --muted-foreground: #8a8a8a;
  --accent: #1a1a1a;
  --accent-foreground: #ededed;
  --destructive: #d4d4d4; /* monochrome: errors are gray + typography, not red */
  --border: #262626;
  --input: #333333;
  --ring: #525252;
  --radius: 0.625rem;
}
```

Append schematic utilities at the end of the file:

```css
body {
  background-color: var(--background);
  background-image: radial-gradient(#161616 1px, transparent 1px);
  background-size: 18px 18px;
}

.micro-label {
  font-family: var(--font-geist-mono), monospace;
  font-size: 9px;
  letter-spacing: 0.2em;
  text-transform: uppercase;
  color: #6a6a6a;
}

.dashed-rule {
  border-top: 1px dashed #333;
}

.stat-line {
  font-family: var(--font-geist-mono), monospace;
  font-size: 10px;
  color: #6a6a6a;
}
```

- [ ] **Step 4: Layout**

Replace `web_app/ui/app/layout.tsx` body wrapper (keep generated Geist font setup):

```tsx
import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

export const metadata: Metadata = {
  title: "Jac Studio",
  description: "Local chatbot for fine-tuned Jac models",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className="dark">
      <body className={`${geistSans.variable} ${geistMono.variable} antialiased`}>
        {children}
      </body>
    </html>
  );
}
```

- [ ] **Step 5: Verify build, commit**

Run: `npm run build`
Expected: builds clean.

```bash
git add web_app/ui .gitignore
git commit -m "feat(studio): Next.js + shadcn scaffold, monochrome schematic theme"
```

---

### Task 9: API client + SSE reader

**Files:**
- Create: `web_app/ui/lib/api.ts`

- [ ] **Step 1: Implement `lib/api.ts`**

```ts
const BASE = "http://127.0.0.1:8400";

export type ModelInfo = { id: string; label: string; available: boolean; size_gb: number | null };
export type ModelsResponse = { models: ModelInfo[]; loaded: string | null; ram_gb: number; resident_gb: number | null };
export type Stats = { model_id: string; gen_tokens: number; tps: number; seconds: number; load_seconds: number };
export type ChatMeta = { id: number; title: string; created_at: string; updated_at: string };
export type StoredMessage = { id: number; chat_id: number; role: "user" | "assistant"; content: string; model_id: string | null; stats: Stats | null; pair_group: string | null; created_at: string };
export type PromptCategory = { id: string; label: string; prompts: string[] };
export type Sampling = { temperature: number; top_p: number; max_tokens: number };

export type StreamEvent =
  | { type: "token"; text: string }
  | { type: "load"; status: "loading" | "ready"; model_id: string; elapsed?: number; seconds?: number }
  | { type: "stats" } & Stats
  | { type: "error"; message: string }
  | { type: "done" };

async function j<T>(path: string, init?: RequestInit): Promise<T> {
  const r = await fetch(`${BASE}${path}`, {
    headers: { "Content-Type": "application/json" },
    ...init,
  });
  if (!r.ok) throw new Error(`${path}: ${r.status}`);
  return r.json();
}

export const api = {
  ping: () => j<ModelsResponse>("/api/models"),
  models: () => j<ModelsResponse>("/api/models"),
  prompts: () => j<{ categories: PromptCategory[] }>("/api/prompts"),
  chats: () => j<ChatMeta[]>("/api/chats"),
  createChat: (title: string) => j<ChatMeta>("/api/chats", { method: "POST", body: JSON.stringify({ title }) }),
  getChat: (id: number) => j<{ chat: ChatMeta; messages: StoredMessage[] }>(`/api/chats/${id}`),
  renameChat: (id: number, title: string) => j(`/api/chats/${id}`, { method: "PATCH", body: JSON.stringify({ title }) }),
  deleteChat: (id: number) => j(`/api/chats/${id}`, { method: "DELETE" }),
};

async function streamSSE(path: string, body: unknown, onEvent: (e: StreamEvent) => void) {
  const r = await fetch(`${BASE}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok || !r.body) throw new Error(`${path}: ${r.status}`);
  const reader = r.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf("\n\n")) >= 0) {
      const frame = buf.slice(0, i);
      buf = buf.slice(i + 2);
      if (frame.startsWith("data: ")) onEvent(JSON.parse(frame.slice(6)));
    }
  }
}

export type ChatBody = {
  model_id: string;
  messages: { role: string; content: string }[];
  chat_id?: number | null;
  pair_group?: string | null;
  persist_user?: boolean;
} & Sampling;

export const streamChat = (body: ChatBody, onEvent: (e: StreamEvent) => void) =>
  streamSSE("/api/chat", body, onEvent);

export const streamLoad = (model_id: string, onEvent: (e: StreamEvent) => void) =>
  streamSSE("/api/load", { model_id }, onEvent);
```

- [ ] **Step 2: Verify build, commit**

Run: `npm run build` (in `web_app/ui`)
Expected: clean.

```bash
git add web_app/ui/lib/api.ts
git commit -m "feat(studio): typed API client with SSE stream reader"
```

---

### Task 10: State hook (`use-studio`) with send + compare logic

**Files:**
- Create: `web_app/ui/lib/use-studio.ts`

- [ ] **Step 1: Implement the hook**

```ts
"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import { api, streamChat, streamLoad, type ChatMeta, type ModelsResponse, type PromptCategory, type Sampling, type Stats } from "./api";

export type UiMessage = {
  role: "user" | "assistant";
  content: string;
  modelId?: string;
  stats?: Stats;
  pairGroup?: string | null;
  streaming?: boolean;
  loadState?: { status: "loading"; elapsed: number } | null;
  error?: string | null;
};

export function useStudio() {
  const [online, setOnline] = useState<boolean | null>(null);
  const [modelsInfo, setModelsInfo] = useState<ModelsResponse | null>(null);
  const [modelId, setModelId] = useState("qwen-dpo");
  const [compareId, setCompareId] = useState<string | null>(null);
  const [loadingModel, setLoadingModel] = useState<{ id: string; elapsed: number } | null>(null);
  const [chats, setChats] = useState<ChatMeta[]>([]);
  const [chatId, setChatId] = useState<number | null>(null);
  const [messages, setMessages] = useState<UiMessage[]>([]);
  const [prompts, setPrompts] = useState<PromptCategory[]>([]);
  const [sampling, setSampling] = useState<Sampling>({ temperature: 0.2, top_p: 0.9, max_tokens: 1024 });
  const [composer, setComposer] = useState("");
  const [busy, setBusy] = useState(false);
  const messagesRef = useRef(messages);
  messagesRef.current = messages;

  const refreshModels = useCallback(async () => {
    try {
      const m = await api.models();
      setModelsInfo(m);
      setOnline(true);
    } catch {
      setOnline(false);
    }
  }, []);

  useEffect(() => {
    refreshModels();
    api.prompts().then((p) => setPrompts(p.categories)).catch(() => {});
    api.chats().then(setChats).catch(() => {});
  }, [refreshModels]);

  // offline retry ping
  useEffect(() => {
    if (online === false) {
      const t = setInterval(refreshModels, 3000);
      return () => clearInterval(t);
    }
  }, [online, refreshModels]);

  const newChat = useCallback(() => {
    setChatId(null);
    setMessages([]);
  }, []);

  const openChat = useCallback(async (id: number) => {
    const { messages: stored } = await api.getChat(id);
    setChatId(id);
    setMessages(stored.map((m) => ({
      role: m.role, content: m.content, modelId: m.model_id ?? undefined,
      stats: m.stats ?? undefined, pairGroup: m.pair_group,
    })));
  }, []);

  const removeChat = useCallback(async (id: number) => {
    await api.deleteChat(id);
    setChats(await api.chats());
    if (chatId === id) newChat();
  }, [chatId, newChat]);

  const loadModel = useCallback(async (id: string) => {
    setModelId(id);
    setLoadingModel({ id, elapsed: 0 });
    try {
      await streamLoad(id, (e) => {
        if (e.type === "load" && e.status === "loading") setLoadingModel({ id, elapsed: e.elapsed ?? 0 });
      });
    } finally {
      setLoadingModel(null);
      refreshModels();
    }
  }, [refreshModels]);

  const patchLast = (fn: (m: UiMessage) => UiMessage) =>
    setMessages((ms) => ms.map((m, i) => (i === ms.length - 1 ? fn(m) : m)));

  const runLeg = useCallback(async (legModel: string, history: { role: string; content: string }[], cid: number, persistUser: boolean, pairGroup: string | null) => {
    setMessages((ms) => [...ms, { role: "assistant", content: "", modelId: legModel, streaming: true, pairGroup }]);
    await streamChat(
      { model_id: legModel, messages: history, chat_id: cid, pair_group: pairGroup, persist_user: persistUser, ...sampling },
      (e) => {
        if (e.type === "token") patchLast((m) => ({ ...m, content: m.content + e.text, loadState: null }));
        else if (e.type === "load" && e.status === "loading") patchLast((m) => ({ ...m, loadState: { status: "loading", elapsed: e.elapsed ?? 0 } }));
        else if (e.type === "load" && e.status === "ready") patchLast((m) => ({ ...m, loadState: null }));
        else if (e.type === "stats") patchLast((m) => ({ ...m, stats: e as Stats, streaming: false }));
        else if (e.type === "error") patchLast((m) => ({ ...m, error: e.message, streaming: false, loadState: null }));
      },
    );
  }, [sampling]);

  const send = useCallback(async (text: string) => {
    if (!text.trim() || busy) return;
    setBusy(true);
    setComposer("");
    try {
      let cid = chatId;
      if (cid === null) {
        const title = text.trim().slice(0, 40) || "untitled";
        const c = await api.createChat(title);
        cid = c.id;
        setChatId(cid);
        api.chats().then(setChats).catch(() => {});
      }
      const history = [
        ...messagesRef.current
          .filter((m) => !m.error && (!m.pairGroup || m.modelId === modelId))
          .map((m) => ({ role: m.role, content: m.content })),
        { role: "user", content: text },
      ];
      setMessages((ms) => [...ms, { role: "user", content: text }]);
      if (compareId) {
        const pg = crypto.randomUUID();
        await runLeg(modelId, history, cid, true, pg);
        await runLeg(compareId, history, cid, false, pg);
      } else {
        await runLeg(modelId, history, cid, true, null);
      }
      api.chats().then(setChats).catch(() => {});
      refreshModels();
    } finally {
      setBusy(false);
    }
  }, [busy, chatId, compareId, modelId, runLeg, refreshModels]);

  return {
    online, modelsInfo, modelId, compareId, loadingModel, chats, chatId, messages,
    prompts, sampling, composer, busy,
    setCompareId, setSampling, setComposer,
    newChat, openChat, removeChat, loadModel, send, refreshModels,
  };
}
```

Note: in compare history, prior paired responses from the *other* model are filtered out — each model continues its own thread.

- [ ] **Step 2: Verify build, commit**

Run: `npm run build`
Expected: clean.

```bash
git add web_app/ui/lib/use-studio.ts
git commit -m "feat(studio): use-studio state hook with streaming send + sequential compare"
```

---

### Task 11: Shell, sidebar, offline panel

**Files:**
- Create: `web_app/ui/components/sidebar.tsx`
- Create: `web_app/ui/components/offline.tsx`
- Modify: `web_app/ui/app/page.tsx`

- [ ] **Step 1: Implement `components/offline.tsx`**

```tsx
export function Offline() {
  return (
    <div className="flex h-screen items-center justify-center">
      <div className="rounded-lg border border-dashed border-neutral-700 bg-[#0d0d0d] p-8 text-center">
        <div className="micro-label mb-3">JAC.STUDIO — STATUS</div>
        <p className="text-lg text-neutral-200">backend offline</p>
        <p className="mt-2 font-mono text-xs text-neutral-500">
          start it with: <span className="text-neutral-300">./web_app/start.sh</span>
        </p>
        <p className="mt-4 font-mono text-[10px] text-neutral-600">retrying every 3s…</p>
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Implement `components/sidebar.tsx`**

```tsx
"use client";
import type { ChatMeta, ModelsResponse } from "@/lib/api";

function MemGauge({ info }: { info: ModelsResponse | null }) {
  if (!info) return null;
  const used = info.resident_gb ?? 0;
  const filled = Math.min(8, Math.round((used / info.ram_gb) * 8));
  return (
    <div className="dashed-rule pt-3 font-mono text-[10px] text-neutral-500">
      MEM {used.toFixed(1)} / {info.ram_gb} GB{" "}
      <span className="text-neutral-300">{"▮".repeat(filled)}</span>
      {"░".repeat(8 - filled)}
    </div>
  );
}

export function Sidebar(props: {
  chats: ChatMeta[];
  activeId: number | null;
  info: ModelsResponse | null;
  onNew: () => void;
  onOpen: (id: number) => void;
  onDelete: (id: number) => void;
}) {
  return (
    <aside className="flex w-56 shrink-0 flex-col border-r border-neutral-800 bg-[#0d0d0d] p-3">
      <div className="micro-label mb-3">JAC.STUDIO — fig.1</div>
      <button
        onClick={props.onNew}
        className="mb-3 rounded-md border border-dashed border-neutral-600 py-1.5 text-xs text-neutral-300 hover:border-neutral-400"
      >
        + new chat
      </button>
      <div className="micro-label mb-1">HISTORY</div>
      <div className="flex-1 space-y-0.5 overflow-y-auto">
        {props.chats.map((c) => (
          <div
            key={c.id}
            onClick={() => props.onOpen(c.id)}
            className={`group flex cursor-pointer items-center justify-between rounded-md px-2 py-1.5 text-xs ${
              c.id === props.activeId ? "bg-[#1a1a1a] text-neutral-100" : "text-neutral-400 hover:bg-[#141414]"
            }`}
          >
            <span className="truncate">{c.title}</span>
            <button
              onClick={(e) => { e.stopPropagation(); props.onDelete(c.id); }}
              className="hidden font-mono text-[9px] text-neutral-600 hover:text-neutral-300 group-hover:block"
            >
              DEL
            </button>
          </div>
        ))}
        {props.chats.length === 0 && (
          <p className="px-2 font-mono text-[10px] text-neutral-600">no chats yet</p>
        )}
      </div>
      <MemGauge info={props.info} />
    </aside>
  );
}
```

- [ ] **Step 3: Assemble `app/page.tsx` (placeholder center/rail for now)**

```tsx
"use client";
import { useStudio } from "@/lib/use-studio";
import { Sidebar } from "@/components/sidebar";
import { Offline } from "@/components/offline";

export default function Home() {
  const s = useStudio();
  if (s.online === false) return <Offline />;
  if (s.online === null) return null;
  return (
    <div className="flex h-screen overflow-hidden">
      <Sidebar
        chats={s.chats}
        activeId={s.chatId}
        info={s.modelsInfo}
        onNew={s.newChat}
        onOpen={s.openChat}
        onDelete={s.removeChat}
      />
      <main className="flex min-w-0 flex-1 flex-col">{/* Task 12 */}</main>
      <div className="w-60 shrink-0">{/* Task 13 */}</div>
    </div>
  );
}
```

- [ ] **Step 4: Verify build, commit**

Run: `npm run build`
Expected: clean.

```bash
git add web_app/ui
git commit -m "feat(studio): app shell, chat sidebar with memory gauge, offline panel"
```

---

### Task 12: Center column — model pill, thread, composer

**Files:**
- Create: `web_app/ui/components/model-pill.tsx`
- Create: `web_app/ui/components/thread.tsx`
- Create: `web_app/ui/components/composer.tsx`
- Modify: `web_app/ui/app/page.tsx`

- [ ] **Step 1: Implement `components/model-pill.tsx`**

```tsx
"use client";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import type { ModelsResponse } from "@/lib/api";

export function ModelPill(props: {
  info: ModelsResponse | null;
  modelId: string;
  compareId: string | null;
  loading: { id: string; elapsed: number } | null;
  onPick: (id: string) => void;
  onPickCompare: (id: string | null) => void;
}) {
  const { info } = props;
  const label = (id: string | null) => info?.models.find((m) => m.id === id)?.label ?? id;
  return (
    <div className="flex items-center justify-between border-b border-neutral-800 px-4 py-2.5">
      <div className="flex items-center gap-2">
        <Popover>
          <PopoverTrigger className="rounded-full border border-neutral-700 bg-[#161616] px-4 py-1 text-xs text-neutral-200 hover:border-neutral-500">
            {props.loading ? `loading ${label(props.loading.id)}… ${props.loading.elapsed.toFixed(0)}s` : <>{label(props.modelId)} <span className="text-neutral-500">▾</span></>}
          </PopoverTrigger>
          <PopoverContent className="w-56 border-neutral-800 bg-[#121212] p-1">
            {info?.models.map((m) => (
              <button
                key={m.id}
                disabled={!m.available}
                onClick={() => props.onPick(m.id)}
                className="flex w-full items-center justify-between rounded px-2 py-1.5 text-left text-xs text-neutral-300 hover:bg-[#1a1a1a] disabled:opacity-40"
              >
                {m.label}
                <span className="font-mono text-[9px] text-neutral-500">
                  {m.id === info.loaded ? "● LOADED" : m.available ? `${m.size_gb}GB` : "MISSING"}
                </span>
              </button>
            ))}
          </PopoverContent>
        </Popover>
        {props.compareId && (
          <span className="font-mono text-[10px] text-neutral-500">vs {label(props.compareId)}</span>
        )}
      </div>
      <Popover>
        <PopoverTrigger className="micro-label hover:text-neutral-300">
          ⇄ COMPARE{props.compareId ? " ·ON" : ""}
        </PopoverTrigger>
        <PopoverContent className="w-56 border-neutral-800 bg-[#121212] p-1" align="end">
          <button
            onClick={() => props.onPickCompare(null)}
            className="w-full rounded px-2 py-1.5 text-left text-xs text-neutral-400 hover:bg-[#1a1a1a]"
          >
            off
          </button>
          {info?.models.filter((m) => m.available && m.id !== props.modelId).map((m) => (
            <button
              key={m.id}
              onClick={() => props.onPickCompare(m.id)}
              className="w-full rounded px-2 py-1.5 text-left text-xs text-neutral-300 hover:bg-[#1a1a1a]"
            >
              {m.label}
            </button>
          ))}
        </PopoverContent>
      </Popover>
    </div>
  );
}
```

- [ ] **Step 2: Implement `components/thread.tsx`**

```tsx
"use client";
import { useEffect, useRef, useState } from "react";
import type { UiMessage } from "@/lib/use-studio";

function CodeBlock({ lang, code }: { lang: string; code: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="relative mt-3 mb-1 rounded-lg border border-neutral-800 bg-[#121212]">
      <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">
        OUTPUT.{(lang || "TXT").toUpperCase()}
      </span>
      <button
        onClick={() => { navigator.clipboard.writeText(code); setCopied(true); setTimeout(() => setCopied(false), 1200); }}
        className="absolute right-2 top-2 font-mono text-[9px] text-neutral-500 hover:text-neutral-200"
      >
        {copied ? "COPIED" : "COPY"}
      </button>
      <pre className="overflow-x-auto p-3 pt-4 font-mono text-xs leading-relaxed text-neutral-200">{code}</pre>
    </div>
  );
}

function parts(content: string) {
  const out: { type: "text" | "code"; lang?: string; body: string }[] = [];
  const re = /```(\w*)\n?([\s\S]*?)(```|$)/g;
  let last = 0, m: RegExpExecArray | null;
  while ((m = re.exec(content))) {
    if (m.index > last) out.push({ type: "text", body: content.slice(last, m.index) });
    out.push({ type: "code", lang: m[1], body: m[2].replace(/\n$/, "") });
    last = re.lastIndex;
  }
  if (last < content.length) out.push({ type: "text", body: content.slice(last) });
  return out;
}

function Bubble({ m, label }: { m: UiMessage; label: string }) {
  if (m.role === "user") {
    return (
      <div className="my-2 flex justify-end">
        <div className="max-w-[80%] rounded-xl bg-neutral-200 px-4 py-2 text-sm text-neutral-900">{m.content}</div>
      </div>
    );
  }
  return (
    <div className="my-3 max-w-[92%]">
      {m.pairGroup && <div className="micro-label mb-1">{label}</div>}
      {m.loadState && (
        <div className="stat-line animate-pulse">swapping to {label}… {m.loadState.elapsed.toFixed(0)}s</div>
      )}
      {parts(m.content).map((p, i) =>
        p.type === "code" ? (
          <CodeBlock key={i} lang={p.lang ?? ""} code={p.body} />
        ) : (
          <p key={i} className="whitespace-pre-wrap text-sm leading-relaxed text-neutral-200">{p.body}</p>
        ),
      )}
      {m.streaming && !m.loadState && <span className="animate-pulse font-mono text-neutral-400">▍</span>}
      {m.error && <div className="stat-line mt-1 border border-dashed border-neutral-600 p-2">ERROR: {m.error}</div>}
      {m.stats && (
        <div className="stat-line mt-1.5">
          └─ {m.stats.tps.toFixed(0)} tok/s · {m.stats.gen_tokens} tok · Δ{m.stats.seconds}s
          {m.stats.load_seconds > 0 && ` · load ${m.stats.load_seconds}s`}
        </div>
      )}
    </div>
  );
}

export function Thread({ messages, modelLabel }: { messages: UiMessage[]; modelLabel: (id?: string) => string }) {
  const endRef = useRef<HTMLDivElement>(null);
  useEffect(() => { endRef.current?.scrollIntoView({ behavior: "smooth" }); }, [messages]);

  const rows: (UiMessage | UiMessage[])[] = [];
  for (let i = 0; i < messages.length; i++) {
    const m = messages[i];
    const n = messages[i + 1];
    if (m.role === "assistant" && m.pairGroup && n?.pairGroup === m.pairGroup) {
      rows.push([m, n]);
      i++;
    } else rows.push(m);
  }

  return (
    <div className="flex-1 overflow-y-auto px-6 py-4">
      {messages.length === 0 && (
        <div className="flex h-full items-center justify-center">
          <p className="micro-label">SELECT A PROMPT OR TYPE BELOW</p>
        </div>
      )}
      {rows.map((r, i) =>
        Array.isArray(r) ? (
          <div key={i} className="grid grid-cols-2 gap-4">
            {r.map((m, k) => (
              <div key={k} className="rounded-lg border border-dashed border-neutral-800 p-3">
                <Bubble m={m} label={modelLabel(m.modelId)} />
              </div>
            ))}
          </div>
        ) : (
          <Bubble key={i} m={r} label={modelLabel((r as UiMessage).modelId)} />
        ),
      )}
      <div ref={endRef} />
    </div>
  );
}
```

- [ ] **Step 3: Implement `components/composer.tsx`**

```tsx
"use client";
import { useRef } from "react";
import type { PromptCategory } from "@/lib/api";

export function Composer(props: {
  value: string;
  busy: boolean;
  categories: PromptCategory[];
  onChange: (v: string) => void;
  onSend: (text: string) => void;
  onChip: (categoryId: string) => void;
}) {
  const taRef = useRef<HTMLTextAreaElement>(null);
  return (
    <div className="px-6 pb-4">
      <div className="mb-2 flex gap-1.5">
        {props.categories.map((c) => (
          <button
            key={c.id}
            onClick={() => props.onChip(c.id)}
            className="rounded-full border border-dashed border-neutral-600 px-2.5 py-0.5 font-mono text-[9px] text-neutral-400 hover:border-neutral-400 hover:text-neutral-200"
          >
            {c.id}
          </button>
        ))}
      </div>
      <div className="flex items-end gap-2 rounded-xl border border-neutral-700 bg-[#121212] p-2 focus-within:border-neutral-500">
        <textarea
          ref={taRef}
          value={props.value}
          onChange={(e) => props.onChange(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              props.onSend(props.value);
            }
          }}
          rows={Math.min(8, Math.max(1, props.value.split("\n").length))}
          placeholder="Ask the model…  (Enter to send, Shift+Enter for newline)"
          className="max-h-48 flex-1 resize-none bg-transparent px-2 py-1 text-sm text-neutral-200 outline-none placeholder:text-neutral-600"
        />
        <button
          onClick={() => props.onSend(props.value)}
          disabled={props.busy || !props.value.trim()}
          className="rounded-lg border border-neutral-600 px-3 py-1 font-mono text-[10px] text-neutral-300 hover:border-neutral-400 disabled:opacity-30"
        >
          {props.busy ? "…" : "⏎ SEND"}
        </button>
      </div>
    </div>
  );
}
```

- [ ] **Step 4: Wire into `app/page.tsx`**

Replace the `<main>` placeholder:

```tsx
      <main className="flex min-w-0 flex-1 flex-col">
        <ModelPill
          info={s.modelsInfo}
          modelId={s.modelId}
          compareId={s.compareId}
          loading={s.loadingModel}
          onPick={s.loadModel}
          onPickCompare={s.setCompareId}
        />
        <Thread messages={s.messages} modelLabel={(id) => s.modelsInfo?.models.find((m) => m.id === id)?.label ?? id ?? ""} />
        <Composer
          value={s.composer}
          busy={s.busy}
          categories={s.prompts}
          onChange={s.setComposer}
          onSend={s.send}
          onChip={(cid) => {
            const cat = s.prompts.find((c) => c.id === cid);
            if (cat?.prompts[0]) s.setComposer(cat.prompts[0]);
          }}
        />
      </main>
```

with imports:

```tsx
import { ModelPill } from "@/components/model-pill";
import { Thread } from "@/components/thread";
import { Composer } from "@/components/composer";
```

- [ ] **Step 5: Verify build, commit**

Run: `npm run build`
Expected: clean.

```bash
git add web_app/ui
git commit -m "feat(studio): model pill, streaming thread with schematic code blocks, composer"
```

---

### Task 13: Right rail — prompt library, sampling, last run

**Files:**
- Create: `web_app/ui/components/rail.tsx`
- Modify: `web_app/ui/app/page.tsx`

- [ ] **Step 1: Implement `components/rail.tsx`**

```tsx
"use client";
import { useState } from "react";
import { Slider } from "@/components/ui/slider";
import type { PromptCategory, Sampling, Stats } from "@/lib/api";

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="mb-4">
      <div className="micro-label dashed-rule mb-2 pt-2">{title}</div>
      {children}
    </div>
  );
}

export function Rail(props: {
  prompts: PromptCategory[];
  sampling: Sampling;
  lastStats: Stats | null;
  collapsed: boolean;
  onSampling: (s: Sampling) => void;
  onPick: (text: string) => void;
  onToggle: () => void;
}) {
  const [open, setOpen] = useState<string | null>("py2jac");
  if (props.collapsed) {
    return (
      <button onClick={props.onToggle} className="micro-label border-l border-neutral-800 px-1.5 hover:text-neutral-300" title="expand">
        ⟨
      </button>
    );
  }
  return (
    <aside className="flex w-64 shrink-0 flex-col overflow-y-auto border-l border-neutral-800 bg-[#0d0d0d] p-3">
      <button onClick={props.onToggle} className="micro-label mb-2 self-end hover:text-neutral-300">collapse ⟩</button>
      <Section title="PROMPT LIBRARY">
        {props.prompts.map((c) => (
          <div key={c.id} className="mb-1">
            <button
              onClick={() => setOpen(open === c.id ? null : c.id)}
              className="flex w-full justify-between py-1 text-xs text-neutral-300 hover:text-neutral-100"
            >
              <span>{open === c.id ? "▾" : "▸"} {c.label}</span>
              <span className="font-mono text-[9px] text-neutral-600">{c.prompts.length}</span>
            </button>
            {open === c.id && (
              <div className="ml-3 space-y-1 border-l border-dashed border-neutral-700 pl-2">
                {c.prompts.map((p, i) => (
                  <button
                    key={i}
                    onClick={() => props.onPick(p)}
                    className="block w-full truncate text-left text-[11px] text-neutral-500 hover:text-neutral-200"
                    title={p}
                  >
                    {p.replace(/\n/g, " ").slice(0, 60)}
                  </button>
                ))}
              </div>
            )}
          </div>
        ))}
      </Section>
      <Section title="SAMPLING">
        {([
          ["temperature", 0, 1.5, 0.05, props.sampling.temperature],
          ["top_p", 0.1, 1, 0.05, props.sampling.top_p],
          ["max_tokens", 128, 4096, 128, props.sampling.max_tokens],
        ] as const).map(([key, min, max, step, val]) => (
          <div key={key} className="mb-3">
            <div className="mb-1 flex justify-between text-[10px] text-neutral-400">
              <span>{key.replace("_", " ")}</span>
              <span className="font-mono">{val}</span>
            </div>
            <Slider
              min={min} max={max} step={step} value={[val]}
              onValueChange={([v]) => props.onSampling({ ...props.sampling, [key]: v })}
            />
          </div>
        ))}
      </Section>
      <Section title="LAST RUN">
        {props.lastStats ? (
          <div className="font-mono text-[10px] leading-relaxed text-neutral-400">
            {props.lastStats.tps.toFixed(0)} tok/s<br />
            {props.lastStats.gen_tokens} tokens<br />
            Δ {props.lastStats.seconds}s{props.lastStats.load_seconds > 0 && <> · load {props.lastStats.load_seconds}s</>}
          </div>
        ) : (
          <p className="font-mono text-[10px] text-neutral-600">no runs yet</p>
        )}
      </Section>
    </aside>
  );
}
```

- [ ] **Step 2: Wire into `app/page.tsx`**

Replace the rail placeholder `<div className="w-60 shrink-0">` with:

```tsx
      <Rail
        prompts={s.prompts}
        sampling={s.sampling}
        lastStats={[...s.messages].reverse().find((m) => m.stats)?.stats ?? null}
        collapsed={railCollapsed}
        onSampling={s.setSampling}
        onPick={s.setComposer}
        onToggle={() => setRailCollapsed(!railCollapsed)}
      />
```

with at top of the component:

```tsx
import { useState } from "react";
import { Rail } from "@/components/rail";
// inside Home():
const [railCollapsed, setRailCollapsed] = useState(false);
```

- [ ] **Step 3: Verify build, lint, commit**

Run: `npm run build && npm run lint`
Expected: clean.

```bash
git add web_app/ui
git commit -m "feat(studio): right rail with prompt library, sampling sliders, last-run stats"
```

---

### Task 14: start.sh, smoke.sh, README

**Files:**
- Create: `web_app/start.sh`
- Create: `web_app/smoke.sh`
- Create: `web_app/README.md`

- [ ] **Step 1: `web_app/start.sh`**

```bash
#!/bin/bash
# Jac Studio: FastAPI model server (:8400) + Next.js UI (:3000). Ctrl-C stops both.
set -e
cd "$(dirname "$0")"

export JAC_STUDIO_DATA_ROOT="${JAC_STUDIO_DATA_ROOT:-/Users/ayush/Downloads/JaseciLabs/DataGeneration}"

server/.venv/bin/uvicorn app:app --app-dir server --host 127.0.0.1 --port 8400 &
SERVER_PID=$!

(cd ui && npm run dev) &
UI_PID=$!

trap 'kill $SERVER_PID $UI_PID 2>/dev/null' INT TERM EXIT
wait
```

```bash
chmod +x web_app/start.sh
```

- [ ] **Step 2: `web_app/smoke.sh`**

```bash
#!/bin/bash
# Boot check: API answers and UI serves. Run while start.sh is up.
set -e
echo -n "api /api/models: "
curl -sf http://127.0.0.1:8400/api/models | head -c 120 && echo " ... OK"
echo -n "api /api/prompts: "
curl -sf http://127.0.0.1:8400/api/prompts >/dev/null && echo "OK"
echo -n "ui :3000: "
curl -sf -o /dev/null http://localhost:3000 && echo "OK"
echo "smoke passed"
```

```bash
chmod +x web_app/smoke.sh
```

- [ ] **Step 3: `web_app/README.md`**

```markdown
# Jac Studio

Local chatbot for the fine-tuned Jac models (Gemma/Qwen, SFT + DPO fused, MLX).
Everything runs on this machine — no external calls.

## Run

    ./web_app/start.sh        # API :8400 + UI :3000
    open http://localhost:3000

Models are read from `JAC_STUDIO_DATA_ROOT` (default: the main DataGeneration
checkout — `models/` is gitignored so worktrees don't have it).

## Layout

- `server/` — FastAPI + mlx_lm. One resident model; swap = unload → load (~20-40s).
  SSE streaming, SQLite history in `server/data/`.
- `ui/` — Next.js + shadcn, monochrome "Soft Mono × Schematic" theme.

## Test

    cd web_app/server && .venv/bin/pytest          # fast, fake-model seam
    ./web_app/smoke.sh                              # while running

Compare mode is sequential on 48GB: model A answers, then the server swaps to
model B (load progress shown in B's pane).
```

- [ ] **Step 4: Run smoke end-to-end (fake-free, real server, no model load)**

```bash
./web_app/start.sh &
sleep 12
./web_app/smoke.sh
kill %1
```

Expected: `smoke passed`. (No model is loaded by smoke — `/api/models` and `/api/prompts` don't touch mlx.)

- [ ] **Step 5: Commit**

```bash
git add web_app/start.sh web_app/smoke.sh web_app/README.md
git commit -m "feat(studio): start/smoke scripts and README"
```

---

### Task 15: Real-model verification (manual, slow)

**Files:** none new — this is a verification pass.

- [ ] **Step 1: Boot and load a real model**

```bash
./web_app/start.sh
# in browser at http://localhost:3000:
```

- [ ] **Step 2: Manual checklist**

1. Model pill → pick **Qwen · DPO** → loading state with elapsed seconds appears; pill shows `● LOADED` in picker after.
2. Right rail → Python → Jac category → click first prompt → composer fills → send → tokens stream, code block renders with `OUTPUT.JAC` tab, stats line appears (`tok/s`, tokens, `Δs`).
3. Follow-up turn ("now add an age field") → model answers with context.
4. Sidebar shows the chat with derived title; reload page → chat persists, click it → messages restore.
5. Compare → pick **Gemma · DPO** → send a prompt → pane A streams, then pane B shows "swapping to Gemma · DPO… Ns" then streams; both stats lines present.
6. Memory gauge shows resident GB; switching models updates it.
7. Kill the server mid-session → UI flips to offline panel; restart → it recovers.

- [ ] **Step 3: Optional slow pytest with a real model**

Append to `web_app/server/tests/test_chat_sse.py`:

```python
import os
import pytest


@pytest.mark.slow
@pytest.mark.skipif(not os.environ.get("JAC_STUDIO_SLOW"), reason="set JAC_STUDIO_SLOW=1")
def test_real_model_generates():
    import mlx_lm
    from generate import stream_tokens
    import config
    m = config.model_by_id("qwen-dpo")
    model, tok = mlx_lm.load(str(config.model_path(m)))
    text = ""
    for t, n, tps in stream_tokens(model, tok,
                                   [{"role": "user", "content": "Say hello in Jac."}],
                                   0.2, 0.9, 64):
        text += t
    assert len(text) > 0
```

Run (optional): `JAC_STUDIO_SLOW=1 .venv/bin/pytest -m slow -v`
Register the marker in `web_app/server/pytest.ini`:

```ini
[pytest]
markers =
    slow: loads a real MLX model
```

- [ ] **Step 4: Final commit + merge decision**

```bash
git add -A web_app
git commit -m "feat(studio): real-model verification pass"
```

Then use superpowers:finishing-a-development-branch to merge `jac-studio` back.

---

## Self-review notes

- Spec coverage: models registry (T1), one-resident + swap (T2), SSE chat + stats + auto-load (T3), SQLite (T4), CRUD + persistence + pair_group (T5), /api/load (T6), prompts (T7), theme (T8), API client (T9), multi-turn + compare-sequential + history filter per model (T10), shell/sidebar/gauge/offline (T11), pill/thread/code-blocks/stats/composer/chips (T12), rail/sliders/last-run (T13), start/smoke/README (T14), real-model checklist (T15). Error handling: unknown/missing model, load failure (unload + error event), generation exception (partial kept + error event), offline panel with retry — all covered.
- Type consistency: `StreamEvent`/`Stats` in api.ts match server event JSON (`gen_tokens`, `tps`, `seconds`, `load_seconds`, `model_id`); `persist_user`/`pair_group` field names match pydantic.
- Known accepted simplifications (per spec YAGNI): no markdown beyond code fences + paragraphs; chip click inserts first prompt of category (full list lives in rail); no component tests for UI.
