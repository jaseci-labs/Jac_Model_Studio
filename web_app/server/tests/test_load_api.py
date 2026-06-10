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
