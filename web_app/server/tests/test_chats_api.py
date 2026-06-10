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
