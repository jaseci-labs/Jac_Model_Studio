"""SQLite concurrency hardening for the JMS server process.

WHY THIS FILE EXISTS
--------------------
Under two concurrent client sessions (one calling `local_session`/`warm_model`
while another's UI polls `list_builders`/`system_ram`/`active_jobs`/`today_utc`
on a 1-2s timer) the server used to return "Internal Server Error" with
`sqlite3.OperationalError: database is locked` as the root cause, on endpoints
that never touch SQLite themselves. Reproduced here with 12 concurrent curl
workers for 30s: 19 lock errors / 3 HTTP 500s, every one with this frame chain:

    jac_scale/jserver/jfast_api.jac          request_context_middleware
    jaclang/runtimelib/impl/context.impl.jac aset_user_root -> _aget_anchor
    jaclang/runtimelib/impl/memory.impl.jac  aget -> (to_thread) -> get -> get
    jaclang/runtimelib/impl/memory.impl.jac:629  _ensure_connection
    jaclang/runtimelib/memory.jac:194            _create_new_schema
    sqlite3.OperationalError: database is locked

ROOT CAUSE (all upstream, none of it configurable from jac.toml)
----------------------------------------------------------------
1. `ExecutionContext.postinit` (jaclang/runtimelib/impl/context.impl.jac:42)
   builds a fresh `TieredMemory` per execution context, and jac-scale's
   `ScaleTieredMemory.postinit` (jac_scale/impl/memory_hierarchy.main.impl.jac:38)
   builds a fresh `SqliteMemory` from it. jac-scale creates one execution
   context PER HTTP REQUEST, so every request opens its OWN sqlite connection
   to `.jac/data/anchor_store.db` and re-runs `_create_new_schema()` — which
   ends in `INSERT OR REPLACE INTO schema_meta ...` + `commit()`. That is a
   *write transaction on every single request*, including pure-read polling
   endpoints. (`lsof` on a live server shows 10+ concurrent fds on that file.)

2. Both sqlite connection sites open with the stdlib default busy timeout of
   5 seconds and never raise it:
     jaclang/runtimelib/impl/memory.impl.jac:621
         sqlite3.connect(self.path, check_same_thread=False)
     jaclang/runtimelib/impl/server.impl.jac:33
         sqlite3.connect(self._db_path, check_same_thread=False)
   Combined with (1), N concurrent requests are N writers queueing on one
   file; on a slow/external volume the queue blows past 5s and SQLite raises.

3. jac-scale's user store (`.jac/data/users.db`, hit by `local_session` on
   every auth) is opened through SQLAlchemy — `create_engine(f"sqlite:///{...}")`
   at jac_scale/impl/identity_storage.sqlite.impl.jac:10 — which never sets
   `journal_mode`, so that database sits in DELETE (rollback-journal) mode.
   Verified on disk: header write-version byte == 1. In DELETE mode a writer
   takes an EXCLUSIVE lock that blocks *readers* too, so auth traffic
   serializes hard.

WHY A sitecustomize
-------------------
None of the three sites is reachable from `jac.toml`: jac-scale's
`[plugins.scale.database]` schema (jac_scale/plugin_config.jac:73-93) exposes
only `mongodb_uri` / `redis_url` / `shelf_db_path` — no timeout, no pragma
hook — and jaclang's `SqliteMemory` takes a bare `path`. The only remaining
in-repo seam is the `sqlite3` module itself. Patching the installed jaclang
wheel would fix (2) but not (3), and would be silently reverted by the next
`uv tool upgrade jaclang`. So we wrap `sqlite3.connect` once, at interpreter
startup, before any jac/jac-scale/SQLAlchemy code imports.

`start.sh` / `start_prod.sh` put this directory on PYTHONPATH; CPython's `site`
module imports `sitecustomize` automatically after PYTHONPATH is on sys.path,
which is the earliest available hook and also covers the detached Python
workers this app spawns (they inherit the environment).

WHAT IT DOES
------------
* `timeout=` on every `sqlite3.connect()` (default 30s, override with
  JAC_SQLITE_BUSY_TIMEOUT_MS) instead of the stdlib's 5s.
* `PRAGMA busy_timeout` to match, for connections whose timeout came in
  positionally and for the SQLAlchemy pool.
* `PRAGMA journal_mode=WAL`, which is a no-op on the already-WAL anchor store
  and migrates `users.db` off DELETE mode. WAL is persistent in the file
  header, so it sticks after the first successful connection.

Upstream fix worth filing: raise the busy timeout at both
`jaclang/runtimelib` connect sites, set `journal_mode=WAL` on the jac-scale
identity engine, and — the real bug — stop re-running `_create_new_schema()`
(a write) on a brand-new connection for every HTTP request.
"""

import os
import sqlite3
import sqlite3.dbapi2

_BUSY_MS = int(os.environ.get("JAC_SQLITE_BUSY_TIMEOUT_MS", "30000"))
_SEC = _BUSY_MS / 1000.0

_orig_connect = sqlite3.dbapi2.connect


def _connect(*args, **kwargs):
    # sqlite3.connect(database, timeout, detect_types, ...) — only inject the
    # keyword when the caller did not already supply it either way.
    if len(args) < 2 and "timeout" not in kwargs:
        kwargs["timeout"] = _SEC
    conn = _orig_connect(*args, **kwargs)
    try:
        conn.execute("PRAGMA busy_timeout=%d" % _BUSY_MS)
        conn.execute("PRAGMA journal_mode=WAL")
    except sqlite3.Error:
        # Read-only file, :memory:, or a locked header — never let connection
        # tuning break the connection itself.
        pass
    return conn


sqlite3.dbapi2.connect = _connect
sqlite3.connect = _connect
