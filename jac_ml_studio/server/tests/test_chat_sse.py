import json
import os

import pytest
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


def test_chat_load_failure_unloads_and_errors(fake_root):
    def bad_loader(path):
        raise RuntimeError("no metal")

    a = app_module.create_app(loader=bad_loader, stream_fn=fake_stream)
    client = TestClient(a)
    with client.stream("POST", "/api/chat", json={
        "model_id": "qwen-dpo",
        "messages": [{"role": "user", "content": "hi"}],
    }) as r:
        evs = events(r)
    assert evs[-1]["type"] == "error"
    assert "load failed" in evs[-1]["message"]
    assert "no metal" in evs[-1]["message"]
    assert a.state.manager.current_id is None


def test_chat_already_loaded_skips_load_events(fake_root):
    client, a = make_client()
    body = {"model_id": "qwen-dpo", "messages": [{"role": "user", "content": "hi"}]}
    with client.stream("POST", "/api/chat", json=body) as r:
        list(r.iter_lines())
    with client.stream("POST", "/api/chat", json=body) as r:
        evs = events(r)
    assert not any(e["type"] == "load" for e in evs)
    assert any(e["type"] == "token" for e in evs)
    stats = [e for e in evs if e["type"] == "stats"][0]
    assert stats["load_seconds"] == 0.0


def test_chat_first_load_event_is_prompt_heartbeat_or_ready(fake_root):
    client, _ = make_client()
    with client.stream("POST", "/api/chat", json={
        "model_id": "gemma-dpo",
        "messages": [{"role": "user", "content": "hi"}],
    }) as r:
        evs = events(r)
    load_evs = [e for e in evs if e["type"] == "load"]
    assert load_evs, "expected load events on cold start"
    assert load_evs[-1]["status"] == "ready"


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


@pytest.mark.slow
@pytest.mark.skipif(not os.environ.get("JAC_STUDIO_SLOW"), reason="set JAC_STUDIO_SLOW=1")
def test_real_model_generates():
    import mlx_lm
    from generate import stream_tokens
    import config
    m = config.model_by_id("gemma-dpo")
    model, tok = mlx_lm.load(str(config.model_path(m)))
    text = ""
    for t, n, tps in stream_tokens(model, tok,
                                   [{"role": "user", "content": "Say hello in Jac."}],
                                   0.2, 0.9, 64):
        text += t
    assert len(text) > 0
