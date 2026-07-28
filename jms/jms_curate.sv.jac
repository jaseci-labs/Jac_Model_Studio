"""studio - JMS CURATE stage: file-based accept/reject/edit + training split.

The curation surface is entirely FILE-based — no per-row graph nodes. Two files
under <project>/dataset/ carry the state:

- raw.jsonl   — the generator's output (immutable here; owned by jms_gen). Each
  line is `{"_id","_type","_meta":{"chunks":[...],"job":...},"messages":[...]}`.
- decisions.jsonl — an append-only OVERLAY this module owns. Each line is
  `{"_id","action":"accept"|"reject"|"edit","messages":[...](edit only),"ts"}`.
  The LAST entry per `_id` wins; earlier ones are history. `materialize` compacts
  the file (rewrites deduped) before building the split.

A row's effective status merges the two: no decision → "pending"; else the last
decision's action → accepted / rejected / edited. `edited` is its own stats
bucket but is treated as accepted-with-edit at materialize (its edited content
wins over raw). `materialize` carves accepted+edited rows deterministically into
dataset/train.jsonl + dataset/holdout.jsonl by a sha1(_id)%100 hash gate, and
strips EVERY underscore-prefixed key (_id/_type/_meta) so the shipped rows are
pure sft-chat `{"messages":[...]}`.

Kept out of jms_projects (which stays graph-only) and out of jms_gen (the
generation engine); imports `validate_row` from jms_gen for edit validation and
`_find_project`/`jms_project_dir`/`_count_lines` from jms_projects. No circular
import: neither of those imports this module.

Checker notes (jaclang 0.16.1): dict values are `any` → int(str(...)); never a
local named `root` (graph builtin); slice + splitlines for pagination.
"""

import json;
import os;
import hashlib;
import datetime;
import from pathlib { Path }
import from jms_gen { validate_row }
import from jms_projects { JmsProject, _find_project, jms_project_dir, _count_lines }

def _now() -> str {
    return datetime.datetime.now(datetime.UTC).replace(tzinfo=None).isoformat() + "Z";
}

# ------------------------------------------------------------- file helpers ----
def _dataset_dir(p: JmsProject) -> Path {
    return jms_project_dir(p.slug) / "dataset";
}

def _raw_file(p: JmsProject) -> Path {
    return _dataset_dir(p) / "raw.jsonl";
}

def _decisions_file(p: JmsProject) -> Path {
    return _dataset_dir(p) / "decisions.jsonl";
}

def _train_file(p: JmsProject) -> Path {
    return _dataset_dir(p) / "train.jsonl";
}

def _holdout_file(p: JmsProject) -> Path {
    return _dataset_dir(p) / "holdout.jsonl";
}

"""Every non-blank JSONL line of raw.jsonl parsed to a dict (garbage lines
skipped). O(total) — acceptable at this product's row counts."""
def _read_raw(p: JmsProject) -> list[dict] {
    rf = _raw_file(p);
    if not rf.exists() { return []; }
    out: list[dict] = [];
    for ln in rf.read_text().splitlines() {
        if not ln.strip() { continue; }
        try { out.append(dict(json.loads(ln))); } except Exception {}
    }
    return out;
}

"""decisions.jsonl folded to {_id: last-decision-dict} — last line per id wins,
so a re-decide simply appends and this read picks the newest."""
def _read_decisions(p: JmsProject) -> dict {
    df = _decisions_file(p);
    res: dict = {};
    if not df.exists() { return res; }
    for ln in df.read_text().splitlines() {
        if not ln.strip() { continue; }
        try {
            d = dict(json.loads(ln));
            rid = str(d.get("_id", ""));
            if rid { res[rid] = d; }
        } except Exception {}
    }
    return res;
}

"""Effective status of *rid* given the folded decisions map."""
def _status_of(rid: str, decisions: dict) -> str {
    if rid not in decisions { return "pending"; }
    act = str(dict(decisions[rid]).get("action", ""));
    if act == "accept" { return "accepted"; }
    if act == "reject" { return "rejected"; }
    if act == "edit" { return "edited"; }
    return "pending";
}

"""Append one decision line, normalising a missing trailing newline first so the
overlay never runs two records together on one line."""
def _append_decisions(p: JmsProject, added: str) -> None {
    df = _decisions_file(p);
    df.parent.mkdir(parents=True, exist_ok=True);
    existing = df.read_text() if df.exists() else "";
    if existing and not existing.endswith("\n") { existing = existing + "\n"; }
    df.write_text(existing + added);
}

# ------------------------------------------------------------------ readers ----
"""One row as the client lists it: id/type/status + the effective messages
(edited version when edited) + chunk provenance + source job id."""
def _row_view(row: dict, rid: str, st: str, decisions: dict) -> dict {
    msgs: any = row.get("messages", []);
    if st == "edited" and rid in decisions {
        dm: any = dict(decisions[rid]).get("messages", None);
        if isinstance(dm, list) { msgs = dm; }
    }
    meta_raw: any = row.get("_meta", {});
    meta: dict = dict(meta_raw) if isinstance(meta_raw, dict) else {};
    chunks: any = meta.get("chunks", []);
    return {
        "_id": rid,
        "_type": str(row.get("_type", "")),
        "status": st,
        "messages": list(msgs) if isinstance(msgs, list) else [],
        "chunks": list(chunks) if isinstance(chunks, list) else [],
        "job": str(meta.get("job", ""))
    };
}

"""Curation counters for the header tiles. `acceptance_pct` = (accepted+edited)
over all DECIDED rows (pending excluded); 0 when nothing is decided. train/holdout
are line counts of the materialized files, 0 before the first BUILD."""
def curate_stats(pid: str) -> dict {
    p = _find_project(pid);
    if p is None { return {}; }
    raw = _read_raw(p);
    decisions = _read_decisions(p);
    pending = 0;
    accepted = 0;
    rejected = 0;
    edited = 0;
    for row in raw {
        st = _status_of(str(row.get("_id", "")), decisions);
        if st == "pending" { pending = pending + 1; }
        elif st == "accepted" { accepted = accepted + 1; }
        elif st == "rejected" { rejected = rejected + 1; }
        elif st == "edited" { edited = edited + 1; }
    }
    decided_accept = accepted + edited;
    denom = accepted + rejected + edited;
    acc_pct = int(round(float(decided_accept) * 100.0 / float(denom))) if denom > 0 else 0;
    return {
        "total": len(raw), "pending": pending, "accepted": accepted,
        "rejected": rejected, "edited": edited, "acceptance_pct": acc_pct,
        "train_rows": _count_lines(_train_file(p)),
        "holdout_rows": _count_lines(_holdout_file(p))
    };
}

"""A page of merged rows for *filter* (all|pending|accepted|rejected|edited),
sliced [offset:offset+cap] (cap 100). `total` is the count for THIS filter."""
def curate_rows(pid: str, offset: int, limit: int, `filter: str = "all") -> dict {
    p = _find_project(pid);
    if p is None { return {"rows": [], "total": 0}; }
    filt = `filter if `filter in ["all", "pending", "accepted", "rejected", "edited"] else "all";
    cap = max(1, min(limit, 100));
    raw = _read_raw(p);
    decisions = _read_decisions(p);
    matched: list[dict] = [];
    for row in raw {
        rid = str(row.get("_id", ""));
        st = _status_of(rid, decisions);
        if filt != "all" and st != filt { continue; }
        matched.append({"row": row, "rid": rid, "st": st});
    }
    total = len(matched);
    rows: list[dict] = [];
    i = max(0, offset);
    while i < total and i < offset + cap {
        m = matched[i];
        rows.append(_row_view(dict(m["row"]), str(m["rid"]), str(m["st"]), decisions));
        i = i + 1;
    }
    return {"rows": rows, "total": total};
}

# --------------------------------------------------------------- decisions -----
"""Record one accept/reject/edit for *row_id*. `edit` requires a valid sft-chat
`messages` list (jms_gen.validate_row). Returns the fresh curate_stats, or
{"error": ...}."""
def decide_row(pid: str, row_id: str, action: str, messages: list = []) -> dict {
    p = _find_project(pid);
    if p is None { return {"error": "unknown project"}; }
    if action not in ["accept", "reject", "edit"] { return {"error": "unknown action: " + action}; }
    raw = _read_raw(p);
    found = False;
    for row in raw {
        if str(row.get("_id", "")) == row_id { found = True; break; }
    }
    if not found { return {"error": "unknown row: " + row_id}; }
    entry: dict = {"_id": row_id, "action": action, "ts": _now()};
    if action == "edit" {
        msgs: list = [dict(m) for m in messages];
        if not validate_row({"messages": msgs}) { return {"error": "invalid messages — edit must be a valid sft-chat transcript"}; }
        entry["messages"] = msgs;
    }
    _append_decisions(p, json.dumps(entry) + "\n");
    return curate_stats(pid);
}

"""Bulk accept or reject a set of row ids in one append (unknown ids are
skipped). Returns the fresh curate_stats, or {"error": ...}."""
def decide_page(pid: str, row_ids: list[str], action: str) -> dict {
    p = _find_project(pid);
    if p is None { return {"error": "unknown project"}; }
    if action not in ["accept", "reject"] { return {"error": "bulk action must be accept or reject"}; }
    raw = _read_raw(p);
    valid: dict = {};
    for row in raw { valid[str(row.get("_id", ""))] = True; }
    ts = _now();
    added = "";
    for rid in row_ids {
        r = str(rid);
        if r in valid {
            added = added + json.dumps({"_id": r, "action": action, "ts": ts}) + "\n";
        }
    }
    if added { _append_decisions(p, added); }
    return curate_stats(pid);
}

"""_ids of every currently-rejected row (feeds the REGENERATE button)."""
def rejected_ids(pid: str) -> list[str] {
    p = _find_project(pid);
    if p is None { return []; }
    decisions = _read_decisions(p);
    out: list[str] = [];
    for row in _read_raw(p) {
        rid = str(row.get("_id", ""));
        if _status_of(rid, decisions) == "rejected" { out.append(rid); }
    }
    return out;
}

# -------------------------------------------------------------- materialize ----
"""Rewrite decisions.jsonl deduped (one line per id, last-decision wins)."""
def _compact_decisions(p: JmsProject, decisions: dict) -> None {
    lines: list[str] = [];
    for rid in decisions { lines.append(json.dumps(dict(decisions[rid]))); }
    df = _decisions_file(p);
    df.parent.mkdir(parents=True, exist_ok=True);
    df.write_text("\n".join(lines) + ("\n" if lines else ""));
}

"""The final shipped form of one accepted/edited row: edited messages win, then
EVERY underscore-prefixed key (_id/_type/_meta) is dropped → pure sft-chat."""
def _final_row(row: dict, rid: str, st: str, decisions: dict) -> dict {
    merged: dict = dict(row);
    if st == "edited" and rid in decisions {
        dm: any = dict(decisions[rid]).get("messages", None);
        if isinstance(dm, list) { merged["messages"] = dm; }
    }
    out: dict = {};
    for k in merged {
        if not str(k).startswith("_") { out[str(k)] = merged[k]; }
    }
    return out;
}

"""Compact the overlay, then build the training split from accepted+edited rows
(edited content wins, underscore keys stripped). Deterministic carve:
sha1(_id)%100 < holdout_pct → holdout, else train. Writes dataset/train.jsonl +
dataset/holdout.jsonl. Returns {train_rows, holdout_rows, skipped_rejected,
skipped_pending}."""
def materialize(pid: str, holdout_pct: int = 10) -> dict {
    p = _find_project(pid);
    if p is None { return {"error": "unknown project"}; }
    hp = holdout_pct;
    if hp < 0 { hp = 0; }
    if hp > 100 { hp = 100; }
    raw = _read_raw(p);
    decisions = _read_decisions(p);
    _compact_decisions(p, decisions);
    train: list[str] = [];
    holdout: list[str] = [];
    skipped_rejected = 0;
    skipped_pending = 0;
    for row in raw {
        rid = str(row.get("_id", ""));
        st = _status_of(rid, decisions);
        if st == "rejected" { skipped_rejected = skipped_rejected + 1; continue; }
        if st == "pending" { skipped_pending = skipped_pending + 1; continue; }
        line = json.dumps(_final_row(dict(row), rid, st, decisions));
        bucket = int(hashlib.sha1(rid.encode()).hexdigest(), 16) % 100;
        if bucket < hp { holdout.append(line); }
        else { train.append(line); }
    }
    _train_file(p).write_text("\n".join(train) + ("\n" if train else ""));
    _holdout_file(p).write_text("\n".join(holdout) + ("\n" if holdout else ""));
    return {
        "train_rows": len(train), "holdout_rows": len(holdout),
        "skipped_rejected": skipped_rejected, "skipped_pending": skipped_pending
    };
}
