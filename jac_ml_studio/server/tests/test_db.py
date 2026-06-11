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
