"""studio - tests for jms_curate.sv.jac (file-based accept/reject/edit + split).

Exercises the whole curation lifecycle over a fabricated raw.jsonl: create a real
project via the endpoint (so it hangs off the shared test root), drop 6 rows into
its dataset/raw.jsonl, then drive decide_row / decide_page / materialize and check
the merged reads. No workers, no LLM — validate_row is the only borrowed piece.

Covers: pending→accept→reject→edit status merge, last-decision-wins on re-decide,
edited content winning at read + materialize, filtered pagination counts, the
deterministic sha1 carve at holdout_pct 0 / 100 edges, underscore-key stripping,
rejected+pending exclusion, and the acceptance-pct math.

Shares a persisted root (see `jac guide jac-testing`); workspace redirected to a
temp dir so nothing lands in the repo. Run with `jac test jms_curate.sv.jac`;
`jac clean --data --force` if a re-run flakes.
"""

import os;
import json;
import tempfile;
import from jms_projects { create_project, _find_project, jms_project_dir }

def _isolate_ws -> None {
    os.environ["JAC_STUDIO_WORKSPACE"] = tempfile.mkdtemp(prefix="studio-jmscur-");
}

"""6 fabricated raw rows written to the project's dataset/raw.jsonl. Rows carry
underscore keys (_id/_type/_meta) that materialize must strip."""
def _seed(pid: str) -> list[str] {
    p = _find_project(pid);
    ids = ["r0", "r1", "r2", "r3", "r4", "r5"];
    lines: list[str] = [];
    for rid in ids {
        row = {
            "_id": rid,
            "_type": "Function Definitions",
            "_meta": {"chunks": [rid + ".jac:1-10"], "job": "job-" + rid},
            "messages": [
                {"role": "user", "content": "q " + rid},
                {"role": "assistant", "content": "a " + rid}
            ]
        };
        lines.append(json.dumps(row));
    }
    d = jms_project_dir(p.slug) / "dataset";
    d.mkdir(parents=True, exist_ok=True);
    (d / "raw.jsonl").write_text("\n".join(lines) + "\n");
    return ids;
}

test "empty project: stats + rows are zero-safe" {
    _isolate_ws();
    v = create_project("Cur Empty", "t");
    s = curate_stats(v.pid);
    assert int(str(s["total"])) == 0 and int(str(s["pending"])) == 0, s;
    assert int(str(s["train_rows"])) == 0 and int(str(s["holdout_rows"])) == 0, s;
    r = curate_rows(v.pid, 0, 20, "all");
    assert int(str(r["total"])) == 0 and len(list(r["rows"])) == 0, r;
    assert rejected_ids(v.pid) == [], "no rejects";
}

test "seed → all pending; accept/reject/edit move the buckets" {
    _isolate_ws();
    v = create_project("Cur Life", "t");
    _seed(v.pid);
    s0 = curate_stats(v.pid);
    assert int(str(s0["total"])) == 6 and int(str(s0["pending"])) == 6, s0;
    assert int(str(s0["acceptance_pct"])) == 0, s0;

    decide_row(v.pid, "r0", "accept");
    decide_row(v.pid, "r1", "accept");
    decide_row(v.pid, "r2", "reject");
    edited = [
        {"role": "user", "content": "q r3"},
        {"role": "assistant", "content": "EDITED answer"}
    ];
    s = decide_row(v.pid, "r3", "edit", edited);
    assert int(str(s["accepted"])) == 2, s;
    assert int(str(s["rejected"])) == 1, s;
    assert int(str(s["edited"])) == 1, s;
    assert int(str(s["pending"])) == 2, s;
    # (accepted+edited)/(accepted+rejected+edited) = 3/4 = 75
    assert int(str(s["acceptance_pct"])) == 75, s;
    assert rejected_ids(v.pid) == ["r2"], rejected_ids(v.pid);
}

test "edit content wins on read; last decision wins on re-decide" {
    _isolate_ws();
    v = create_project("Cur Edit", "t");
    _seed(v.pid);
    edited = [
        {"role": "user", "content": "q r0"},
        {"role": "assistant", "content": "FIRST edit"}
    ];
    decide_row(v.pid, "r0", "edit", edited);
    page = curate_rows(v.pid, 0, 20, "edited");
    assert int(str(page["total"])) == 1, page;
    row0 = dict(list(page["rows"])[0]);
    msgs = list(row0["messages"]);
    assert str(dict(msgs[1])["content"]) == "FIRST edit", msgs;
    assert str(row0["status"]) == "edited", row0;
    # provenance survives the merge
    assert list(row0["chunks"]) == ["r0.jac:1-10"], row0;

    # re-decide: reject overrides the earlier edit (last line wins)
    decide_row(v.pid, "r0", "reject");
    s = curate_stats(v.pid);
    assert int(str(s["edited"])) == 0 and int(str(s["rejected"])) == 1, s;
    assert rejected_ids(v.pid) == ["r0"], rejected_ids(v.pid);
}

test "decide_row rejects bad edits and unknown rows" {
    _isolate_ws();
    v = create_project("Cur Bad", "t");
    _seed(v.pid);
    bad = decide_row(v.pid, "r0", "edit", [{"role": "user", "content": "only user"}]);
    assert "error" in bad and "invalid" in str(bad["error"]), bad;
    miss = decide_row(v.pid, "nope", "accept");
    assert "error" in miss and "unknown row" in str(miss["error"]), miss;
    un = decide_row(v.pid, "r0", "delete");
    assert "error" in un and "unknown action" in str(un["error"]), un;
}

test "filtered pagination counts + slicing" {
    _isolate_ws();
    v = create_project("Cur Page", "t");
    _seed(v.pid);
    decide_page(v.pid, ["r0", "r1", "r2"], "accept");
    decide_page(v.pid, ["r3", "r4"], "reject");
    # 5 decided, 1 pending (r5)
    allp = curate_rows(v.pid, 0, 2, "all");
    assert int(str(allp["total"])) == 6 and len(list(allp["rows"])) == 2, allp;
    pg2 = curate_rows(v.pid, 4, 2, "all");
    assert len(list(pg2["rows"])) == 2, pg2;
    acc = curate_rows(v.pid, 0, 20, "accepted");
    assert int(str(acc["total"])) == 3, acc;
    rej = curate_rows(v.pid, 0, 20, "rejected");
    assert int(str(rej["total"])) == 2, rej;
    pend = curate_rows(v.pid, 0, 20, "pending");
    assert int(str(pend["total"])) == 1, pend;
    assert str(dict(list(pend["rows"])[0])["_id"]) == "r5", pend;
}

test "materialize: split, underscore strip, rejected+pending excluded" {
    _isolate_ws();
    v = create_project("Cur Mat", "t");
    _seed(v.pid);
    # accept r0,r1,r2; edit r3; reject r4; leave r5 pending
    decide_page(v.pid, ["r0", "r1", "r2"], "accept");
    decide_row(v.pid, "r3", "edit", [
        {"role": "user", "content": "q r3"},
        {"role": "assistant", "content": "EDITED r3"}
    ]);
    decide_page(v.pid, ["r4"], "reject");

    m = materialize(v.pid, 10);
    assert int(str(m["skipped_rejected"])) == 1, m;
    assert int(str(m["skipped_pending"])) == 1, m;
    # 4 accepted/edited land somewhere in train+holdout
    assert int(str(m["train_rows"])) + int(str(m["holdout_rows"])) == 4, m;

    p = _find_project(v.pid);
    tf = jms_project_dir(p.slug) / "dataset" / "train.jsonl";
    hf = jms_project_dir(p.slug) / "dataset" / "holdout.jsonl";
    ship: list = [];
    for src in [tf, hf] {
        if src.exists() {
            for ln in src.read_text().splitlines() {
                if ln.strip() { ship.append(dict(json.loads(ln))); }
            }
        }
    }
    assert len(ship) == 4, ship;
    edited_seen = False;
    for row in ship {
        # NO underscore keys survived
        for k in row { assert not str(k).startswith("_"), k; }
        assert "messages" in row, row;
        msgs = list(row["messages"]);
        if str(dict(msgs[1])["content"]) == "EDITED r3" { edited_seen = True; }
    }
    assert edited_seen, "edited content must win in the shipped rows";

    s = curate_stats(v.pid);
    assert int(str(s["train_rows"])) + int(str(s["holdout_rows"])) == 4, s;
}

test "materialize carve edges: holdout_pct 0 → all train, 100 → all holdout" {
    _isolate_ws();
    v = create_project("Cur Carve", "t");
    _seed(v.pid);
    decide_page(v.pid, ["r0", "r1", "r2", "r3", "r4", "r5"], "accept");

    m0 = materialize(v.pid, 0);
    assert int(str(m0["train_rows"])) == 6 and int(str(m0["holdout_rows"])) == 0, m0;

    m100 = materialize(v.pid, 100);
    assert int(str(m100["train_rows"])) == 0 and int(str(m100["holdout_rows"])) == 6, m100;

    # deterministic: same pct twice → identical split counts
    a = materialize(v.pid, 30);
    b = materialize(v.pid, 30);
    assert int(str(a["train_rows"])) == int(str(b["train_rows"])), [a, b];
    assert int(str(a["holdout_rows"])) == int(str(b["holdout_rows"])), [a, b];
}

test "materialize refuses a no-op build and never clobbers an existing split" {
    _isolate_ws();
    # nothing generated at all
    v0 = create_project("Cur NoRows", "t");
    e0 = materialize(v0.pid, 10);
    assert "error" in e0, e0;
    assert "train_rows" not in e0, e0;

    v = create_project("Cur NoOp", "t");
    _seed(v.pid);
    # every row pending → still nothing to split
    e1 = materialize(v.pid, 10);
    assert "error" in e1, e1;
    assert "pending" in str(e1["error"]), e1;

    # every row rejected → still nothing to split
    decide_page(v.pid, ["r0", "r1", "r2", "r3", "r4", "r5"], "reject");
    e2 = materialize(v.pid, 10);
    assert "error" in e2, e2;

    # build a real split, then undo every decision: the refused rebuild must leave
    # the materialized files exactly as they were (no empty overwrite).
    decide_page(v.pid, ["r0", "r1", "r2", "r3", "r4", "r5"], "accept");
    ok = materialize(v.pid, 10);
    good = int(str(ok["train_rows"])) + int(str(ok["holdout_rows"]));
    assert good == 6, ok;
    for rid in ["r0", "r1", "r2", "r3", "r4", "r5"] { decide_row(v.pid, rid, "reset"); }
    e3 = materialize(v.pid, 10);
    assert "error" in e3, e3;
    s = curate_stats(v.pid);
    assert int(str(s["train_rows"])) + int(str(s["holdout_rows"])) == 6, s;
}
