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


def _row_msg(r) -> dict:
    return {"id": r["id"], "chat_id": r["chat_id"], "role": r["role"],
            "content": r["content"], "model_id": r["model_id"],
            "stats": json.loads(r["stats_json"]) if r["stats_json"] else None,
            "pair_group": r["pair_group"], "created_at": r["created_at"]}


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


def get_messages(chat_id: int) -> list[dict]:
    with connect() as con:
        rs = con.execute("SELECT * FROM messages WHERE chat_id=? ORDER BY id",
                         (chat_id,)).fetchall()
        return [_row_msg(r) for r in rs]
