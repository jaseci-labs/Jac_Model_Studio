"""studio - OSP graph persistence for chats + messages (replaces SQLite).

`root --> Chat --> Msg`. Chats live on the shared root graph and survive restarts.
`jid(node)` is the stable cross-RPC id. Ported from server/db.py (chats/messages).
"""

import datetime;
import os;
import audit;

def _now() -> str {
    return datetime.datetime.now(datetime.UTC).replace(tzinfo=None).isoformat() + "Z";
}

"""Current UTC date as YYYY-MM-DD — the sidebar groups chats by day and labels the
current day TODAY. Computed server-side so the client needs no Date object (both
this and chat timestamps are UTC, so the grouping lines up)."""
def today_utc() -> str {
    return datetime.datetime.now(datetime.UTC).date().isoformat();
}

obj ChatView {
    has id: str = "",
        title: str = "",
        workspace: str = "01",
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
        workspace: str = "01",
        created_at: str = "",
        updated_at: str = "",
        deleted_at: str = "";

    def to_view -> ChatView {
        return ChatView(
            id=jid(self), title=self.title, workspace=self.workspace,
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

def _is_deleted(c: Chat) -> bool {
    try {
        return bool(c.deleted_at);
    } except Exception {
        return False;
    }
}

"""Drop chats in trash longer than TRASH_DAYS (default 7). Called from list_chats."""
def _purge_expired_trash() -> None {
    days = 7;
    try {
        days = int(str(os.environ.get("JAC_TRASH_DAYS", "7")));
    } except Exception {}
    cutoff = (
        datetime.datetime.now(datetime.UTC) - datetime.timedelta(days=days)
    ).replace(tzinfo=None).isoformat() + "Z";
    for c in [root -->][?:Chat] {
        if _is_deleted(c) and c.deleted_at < cutoff {
            for m in [c -->][?:Msg] { del m; }
            del c;
        }
    }
}

"""Find a chat by jid on the caller's root; skips soft-deleted chats."""
def _find_chat(chat_id: str) -> Chat | None {
    for c in [root -->][?:Chat] {
        if jid(c) == chat_id and not _is_deleted(c) {
            return c;
        }
    }
    return None;
}

"""Workspace of a chat. Pre-workspace nodes lack the field on disk; the dataclass
default resolves them to "01" via class-attr lookup (verified in the jaclang 0.16.1
serializer). try/except is belt-and-braces against any future default_factory."""
def _ws_of(c: Chat) -> str {
    try {
        w = c.workspace;
        return w if w else "01";
    } except Exception {
        return "01";
    }
}

"""Chats in the caller's workspace, most-recently-updated first. Plain `def` →
JWT required + runs on the caller's OWN root, so `[root -->][?:Chat]` only ever
returns this user's chats (multi-tenant isolation is automatic)."""
def list_chats(workspace: str = "01") -> list[ChatView] {
    _purge_expired_trash();
    out: list[ChatView] = [];
    for c in [root -->][?:Chat] {
        if _is_deleted(c) { continue; }
        if _ws_of(c) == workspace {
            out.append(c.to_view());
        }
    }
    out.sort(key=lambda (v: ChatView) -> str { return v.updated_at; }, reverse=True);
    return out;
}

def create_chat(title: str, workspace: str = "01") -> ChatView {
    now = _now();
    c = root ++> Chat(title=title, workspace=workspace, created_at=now, updated_at=now);
    return c.to_view();
}

def rename_chat(chat_id: str, title: str) -> bool {
    c = _find_chat(chat_id);
    if c {
        c.title = title;
        c.updated_at = _now();
        return True;
    }
    return False;
}

def delete_chat(chat_id: str) -> bool {
    c = _find_chat(chat_id);
    if c {
        c.deleted_at = _now();
        c.updated_at = _now();
        audit.log("chat_delete", {"chat_id": chat_id, "title": c.title});
        return True;
    }
    return False;
}

def get_messages(chat_id: str) -> list[MsgView] {
    c = _find_chat(chat_id);
    out: list[MsgView] = [];
    if c {
        for m in [c -->][?:Msg] {
            out.append(m.to_view());
        }
    }
    return out;
}

def add_message(
    chat_id: str, role: str, content: str, model_id: str, stats_json: str, pair_group: str
) -> MsgView {
    c = _find_chat(chat_id);
    if not c {
        return MsgView();
    }
    m = c ++> Msg(
        role=role, content=content, model_id=model_id,
        stats_json=stats_json, pair_group=pair_group, created_at=_now()
    );
    c.updated_at = _now();
    return m.to_view();
}
