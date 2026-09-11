"""studio - append-only audit trail for shared-host operations.

Every money- or job-sensitive action writes one JSON line to
<data_root>/audit/audit.jsonl (paths.audit_dir()): who (uid), when, what (action), detail (dict).
Call only from inside authenticated endpoint bodies (uses auth.uid()).

Retention / rotation is an ops concern — ship a logrotate rule or cron that
compresses old audit.jsonl files; the app never truncates.
"""

import json;
import datetime;
import from server.core { auth }
import from server.core { paths }
import from pathlib { Path }

def _now() -> str {
    return datetime.datetime.now(datetime.UTC).replace(tzinfo=None).isoformat() + "Z";
}

def _audit_file() -> Path {
    d = paths.audit_dir();
    d.mkdir(parents=True, exist_ok=True);
    return d / "audit.jsonl";
}

"""Append one audit record. Safe to call from any `def` endpoint helper."""
def log(action: str, detail: dict) -> None {
    rec = {
        "at": _now(),
        "uid": auth.uid(),
        "action": action,
        "detail": detail
    };
    try {
        with open(_audit_file(), "a") as f {
            f.write(json.dumps(rec) + "\n");
        }
    } except Exception {
        return;
    }
}
