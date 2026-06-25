"""studio - OSP graph persistence for chats + messages (replaces SQLite).

`root --> Chat --> Msg`. Chats live on the shared root graph and survive restarts.
`jid(node)` is the stable cross-RPC id. Ported from server/db.py (chats/messages).
"""

import datetime;

def _now() -> str {
    return datetime.datetime.now(datetime.UTC).replace(tzinfo=None).isoformat() + "Z";
}

obj ChatView {
    has id: str = "",
        title: str = "",
        created_at: str = "",
        updated_at: str = "";
}

obj MsgView {
    has id: str = "",
        role: str = "",
        content: str = "",
        model_id: str = "",
        stats_json: str = "",
        pair_group: str = "",
        created_at: str = "";
}

node Chat {
    has title: str = "",
        created_at: str = "",
        updated_at: str = "";

    def to_view -> ChatView {
        return ChatView(
            id=jid(self), title=self.title,
            created_at=self.created_at, updated_at=self.updated_at
        );
    }
}

node Msg {
    has role: str = "",
        content: str = "",
        model_id: str = "",
        stats_json: str = "",
        pair_group: str = "",
        created_at: str = "";

    def to_view -> MsgView {
        return MsgView(
            id=jid(self), role=self.role, content=self.content,
            model_id=self.model_id, stats_json=self.stats_json,
            pair_group=self.pair_group, created_at=self.created_at
        );
    }
}

def _find_chat(chat_id: str) -> Chat | None {
    for c in [root -->][?:Chat] {
        if jid(c) == chat_id {
            return c;
        }
    }
    return None;
}

"""All chats, newest first."""
def:pub list_chats() -> list[ChatView] {
    out: list[ChatView] = [];
    for c in [root -->][?:Chat] {
        out.append(c.to_view());
    }
    out.reverse();
    return out;
}

def:pub create_chat(title: str) -> ChatView {
    now = _now();
    c = (root ++> Chat(title=title, created_at=now, updated_at=now))[0];
    return c.to_view();
}

def:pub rename_chat(chat_id: str, title: str) -> bool {
    c = _find_chat(chat_id);
    if c {
        c.title = title;
        return True;
    }
    return False;
}

def:pub delete_chat(chat_id: str) -> bool {
    c = _find_chat(chat_id);
    if c {
        for m in [c -->][?:Msg] {
            del m;
        }
        del c;
        return True;
    }
    return False;
}

def:pub get_messages(chat_id: str) -> list[MsgView] {
    c = _find_chat(chat_id);
    out: list[MsgView] = [];
    if c {
        for m in [c -->][?:Msg] {
            out.append(m.to_view());
        }
    }
    return out;
}

def:pub add_message(
    chat_id: str, role: str, content: str, model_id: str, stats_json: str, pair_group: str
) -> MsgView {
    c = _find_chat(chat_id);
    if not c {
        return MsgView();
    }
    m = (c ++> Msg(
        role=role, content=content, model_id=model_id,
        stats_json=stats_json, pair_group=pair_group, created_at=_now()
    ))[0];
    c.updated_at = _now();
    return m.to_view();
}
