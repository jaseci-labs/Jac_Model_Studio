"""studio - integration tests for the chat/message persistence walkers.

Exercises the real OSP graph CRUD (`root --> Chat --> Msg`) end to end: create,
list, rename, soft-delete, message append, and — most importantly — the multi-
tenant / workspace isolation guarantees the sidebar relies on.

These tests share one persisted `root` (see `jac guide jac-testing`), so each test
scopes itself to a UNIQUE workspace string and counts only the chats it created,
never a total on `root`. `delete_chat`/`add_message` write an audit line via
`auth.uid()`; we redirect the data_root to a temp dir so that stays out of the repo.

Annex file: pairs with persistence.sv.jac. Run with `jac test persistence.sv.jac`.
"""

import os;
import json;
import tempfile;

"""Contain audit-log writes (delete_chat/add_message) in a throwaway dir."""
def _isolate_data_root() -> None {
    os.environ["JAC_STUDIO_DATA_ROOT"] = tempfile.mkdtemp(prefix="studio-persist-");
}

test "create_chat then list_chats round-trips in its workspace" {
    _isolate_data_root();
    ws = "test-create";
    c = create_chat("first chat", ws);
    assert c.id, "create_chat should return a jid";
    assert c.title == "first chat", c.title;
    assert c.workspace == ws, c.workspace;
    assert c.created_at and c.created_at == c.updated_at, c;

    listed = list_chats(ws);
    assert len(listed) == 1, listed;
    assert listed[0].id == c.id, listed;
}

test "list_chats is scoped to its workspace" {
    _isolate_data_root();
    create_chat("in A", "test-ws-a");
    create_chat("in B1", "test-ws-b");
    create_chat("in B2", "test-ws-b");
    assert len(list_chats("test-ws-a")) == 1, list_chats("test-ws-a");
    assert len(list_chats("test-ws-b")) == 2, list_chats("test-ws-b");
    assert list_chats("test-ws-empty") == [], "unknown workspace should be empty";
}

test "list_chats orders most-recently-updated first" {
    _isolate_data_root();
    ws = "test-order";
    old = create_chat("older", ws);
    new = create_chat("newer", ws);
    # Rename `old` so its updated_at moves ahead of `new`.
    rename_chat(old.id, "older-bumped");
    listed = list_chats(ws);
    assert listed[0].id == old.id, [v.title for v in listed];
    assert listed[0].title == "older-bumped", listed[0].title;
}

test "rename_chat updates the title and bumps updated_at" {
    _isolate_data_root();
    ws = "test-rename";
    c = create_chat("before", ws);
    assert rename_chat(c.id, "after") == True;
    got = list_chats(ws)[0];
    assert got.title == "after", got.title;
    assert got.updated_at >= c.updated_at, (got.updated_at, c.updated_at);
    # Unknown id is a no-op that returns False.
    assert rename_chat("does-not-exist", "x") == False;
}

test "delete_chat soft-deletes: hidden from list, undeletable twice" {
    _isolate_data_root();
    ws = "test-delete";
    c = create_chat("doomed", ws);
    assert delete_chat(c.id) == True;
    assert list_chats(ws) == [], "soft-deleted chat should vanish from the list";
    # _find_chat skips deleted chats, so a second delete cannot find it.
    assert delete_chat(c.id) == False, "second delete should return False";
    assert rename_chat(c.id, "zombie") == False, "cannot rename a deleted chat";
}

test "add_message appends messages and bumps the chat's updated_at" {
    _isolate_data_root();
    ws = "test-messages";
    c = create_chat("thread", ws);
    stats = json.dumps({"tps": 42.0});
    u = add_message(c.id, "user", "hello?", "", "", "grp-1");
    a = add_message(c.id, "assistant", "hi there", "mdl-x", stats, "grp-1");
    assert u.id and a.id, (u, a);
    assert a.role == "assistant" and a.model_id == "mdl-x", a;
    assert a.stats_json == stats, a.stats_json;

    msgs = get_messages(c.id);
    assert len(msgs) == 2, msgs;
    roles = [m.role for m in msgs];
    assert "user" in roles and "assistant" in roles, roles;
    assert all([m.pair_group == "grp-1" for m in msgs]), roles;
}

test "add_message on an unknown chat returns an empty view and stores nothing" {
    _isolate_data_root();
    empty = add_message("no-such-chat", "user", "ghost", "", "", "");
    assert empty.id == "", empty.id;
    assert empty.role == "", empty;
}

test "get_messages on an unknown chat is empty" {
    _isolate_data_root();
    assert get_messages("no-such-chat") == [];
}

test "messages of a deleted chat are unreachable via get_messages" {
    _isolate_data_root();
    ws = "test-deleted-msgs";
    c = create_chat("temp", ws);
    add_message(c.id, "user", "secret", "", "", "");
    delete_chat(c.id);
    # _find_chat skips deleted chats, so the message is no longer reachable.
    assert get_messages(c.id) == [], "deleted chat's messages must not be readable";
}

test "today_utc returns an ISO yyyy-mm-dd date" {
    d = today_utc();
    assert len(d) == 10, d;
    assert d[4] == "-" and d[7] == "-", d;
    parts = d.split("-");
    assert len(parts) == 3, parts;
    assert int(parts[0]) >= 2024, parts;      # sanity: a real year
}
