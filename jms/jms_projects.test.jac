"""studio - integration tests for jms_projects.sv.jac (project + source graph).

Exercises the real OSP graph CRUD (`root ++> JmsProject ++> JmsSource`) and the
os.walk source scanner end to end: slug generation on weird names, create→list
round-trip, add_source against a real temp tree (with an excluded node_modules
subdir + an oversized/binary file), and delete_project removing the project from
the list.

These share one persisted `root` (see `jac guide jac-testing`), so each test
creates its own projects and counts only what it created. The workspace_root is
redirected to a temp dir so the jms-projects/ skeleton + project.json snapshots
stay out of the repo. Annex file: pairs with jms_projects.sv.jac. Run with
`jac test jms_projects.sv.jac`; `jac clean --data --force` first if a re-run flakes.
"""

import os;
import tempfile;

"""Contain the jms-projects/ skeleton + snapshots in a throwaway workspace."""
def _isolate_ws -> None {
    os.environ["JAC_STUDIO_WORKSPACE"] = tempfile.mkdtemp(prefix="studio-jms-");
}

"""Build a small source tree: 3 code files + a docs file + an excluded
node_modules/ subdir + a >1MB file that must be skipped. Returns the root path."""
def _make_tree -> str {
    d = tempfile.mkdtemp(prefix="jms-src-");
    _write(os.path.join(d, "a.py"), "print('a')\n");
    _write(os.path.join(d, "b.js"), "console.log('b')\n");
    _write(os.path.join(d, "c.jac"), "with entry { print('c'); }\n");
    _write(os.path.join(d, "readme.md"), "# docs\n");
    _write(os.path.join(d, "notes.txt"), "ignored by code kind\n");
    nm = os.path.join(d, "node_modules", "dep");
    os.makedirs(nm, exist_ok=True);
    _write(os.path.join(nm, "index.js"), "module.exports = 1\n");
    _write(os.path.join(d, "big.py"), "x" * (1048576 + 10));
    return d;
}

def _write(path: str, text: str) -> None {
    f: any = open(path, "w");
    f.write(text);
    f.close();
}

test "slugify handles weird names, punctuation and collapsing" {
    assert _slugify("My Project!!! 2") == "my-project-2", _slugify("My Project!!! 2");
    assert _slugify("  Hello   World  ") == "hello-world", _slugify("  Hello   World  ");
    assert _slugify("___") == "project", _slugify("___");
    assert _slugify("café-résumé") == "caf-r-sum", _slugify("café-résumé");
    assert _slugify("A/B\\C") == "a-b-c", _slugify("A/B\\C");
}

test "create_project + list_projects round-trips and de-dupes slugs" {
    _isolate_ws();
    a = create_project("Demo One", "convert python to jac");
    assert a.pid, "pid minted";
    assert a.slug == "demo-one", a.slug;
    assert a.use_case == "convert python to jac", a.use_case;
    assert a.source_count == 0, a.source_count;
    # Same name → distinct slug.
    b = create_project("Demo One", "second");
    assert b.slug == "demo-one-2", b.slug;

    listed = list_projects();
    pids = [p.pid for p in listed];
    assert a.pid in pids and b.pid in pids, pids;
    # Skeleton dir laid down.
    d = jms_project_dir(a.slug);
    assert (d / "dataset").is_dir() and (d / "sources").is_dir(), str(d);
    assert (d / "project.json").exists(), "snapshot written";
}

test "add_source scans a real tree, honoring excludes + size cap" {
    _isolate_ws();
    p = create_project("Scan Me", "test");
    tree = _make_tree();
    res = add_source(p.pid, "code", tree);
    assert "error" not in res, res;
    # a.py, b.js, c.jac, readme.md — 4 code files. notes.txt (docs-only ext),
    # node_modules/index.js (pruned dir), big.py (>1MB) all excluded.
    assert res["files"] == 4, res;
    assert res["est_tokens"] > 0, res;
    hist = res["ext_histogram"];
    assert ".py" in hist and hist[".py"] == 1, hist;
    assert ".js" in hist and hist[".js"] == 1, hist;
    # get_project reflects the scanned source + stage_state.
    full = get_project(p.pid);
    assert len(full["sources"]) == 1, full;
    assert full["stage_state"]["sources"] == "done", full["stage_state"];
}

test "add_source rejects bad kind / relative / missing paths" {
    _isolate_ws();
    p = create_project("Guard", "test");
    assert "error" in add_source(p.pid, "video", "/tmp"), "bad kind rejected";
    assert "error" in add_source(p.pid, "code", "relative/path"), "relative rejected";
    assert "error" in add_source(p.pid, "code", "/no/such/dir/xyz"), "missing rejected";
}

test "user include glob overrides the kind defaults" {
    _isolate_ws();
    p = create_project("Globbed", "test");
    tree = _make_tree();
    res = add_source(p.pid, "code", tree, ["*.jac"]);
    assert "error" not in res, res;
    assert res["files"] == 1, res;                 # only c.jac matches
    assert ".jac" in res["ext_histogram"], res;
}

test "remove_source + scan_source lifecycle" {
    _isolate_ws();
    p = create_project("Lifecycle", "test");
    tree = _make_tree();
    added = add_source(p.pid, "code", tree);
    sid = str(added["sid"]);
    rescanned = scan_source(p.pid, sid);
    assert rescanned["files"] == 4, rescanned;
    assert remove_source(p.pid, sid) == True;
    assert remove_source(p.pid, sid) == False, "second remove is a no-op";
    assert len(get_project(p.pid)["sources"]) == 0, "source detached";
}

test "update_project patches mutable fields, never the name" {
    _isolate_ws();
    p = create_project("Editable", "old use case");
    v = update_project(p.pid, {"use_case": "new use case", "provider": "openai", "model": "gpt-x", "name": "HACKED"});
    assert v.use_case == "new use case", v.use_case;
    assert v.provider == "openai" and v.model == "gpt-x", v;
    assert v.name == "Editable", "name is immutable";
    assert v.slug == "editable", v.slug;
}

test "delete_project removes it from the list" {
    _isolate_ws();
    a = create_project("Keeper", "x");
    b = create_project("Doomed", "y");
    assert delete_project(b.pid) == True;
    pids = [p.pid for p in list_projects()];
    assert a.pid in pids, pids;
    assert b.pid not in pids, "deleted project gone from list";
    assert delete_project(b.pid) == False, "second delete is a no-op";
}

test "get_project on an unknown pid is empty" {
    _isolate_ws();
    assert get_project("no-such-pid") == {};
}

# ===================================== project lifecycle (rename / clone / export)

"""Materialize dataset/<which>.jsonl for *slug* with *n* one-field JSON rows.
Returns the file path so a test can stat it."""
def _seed_dataset(slug: str, which: str, n: int) -> str {
    d = jms_project_dir(slug) / "dataset";
    d.mkdir(parents=True, exist_ok=True);
    f = d / (which + ".jsonl");
    rows = [f'{{"i": {i}, "text": "row {i}"}}' for i in range(n)];
    f.write_text("\n".join(rows) + "\n");
    return str(f);
}

test "rename_project changes the display name and NEVER the slug or directory" {
    _isolate_ws();
    p = create_project("Before Name", "x");
    olddir = jms_project_dir(p.slug);
    assert olddir.is_dir(), str(olddir);
    v = rename_project(p.pid, "  After Name  ");
    assert v.name == "After Name", v.name;
    assert v.slug == "before-name", "slug is the immutable fs identity";
    assert jms_project_dir(v.slug) == olddir and olddir.is_dir(), "directory untouched";
    # get_project + the on-disk snapshot both reflect the new name.
    assert get_project(p.pid)["name"] == "After Name";
    snap: any = open(str(olddir / "project.json"), "r");
    body = snap.read();
    snap.close();
    assert "After Name" in body, body;
}

test "rename_project rejects blank names and unknown pids" {
    _isolate_ws();
    p = create_project("Keep Me", "x");
    assert rename_project(p.pid, "   ").name == "Keep Me", "blank rename is a no-op";
    assert rename_project("no-such-pid", "X").pid == "", "unknown pid → blank view";
    # 120-char cap.
    assert len(rename_project(p.pid, "z" * 500).name) == 120;
}

test "duplicate_project clones config + sources + plan, and NO dataset by default" {
    _isolate_ws();
    a = create_project("Original", "convert python to jac");
    update_project(a.pid, {"provider": "mlx", "model": "qwen3", "group_id": "ws02"});
    tree = _make_tree();
    add_source(a.pid, "code", tree);
    src_node = _find_project(a.pid);
    (src_node ++> JmsGenPlan(version=4, status="approved", provider="mlx",
                             model="qwen3", plan_json='{"target_rows": 500}'))[0];
    _seed_dataset(a.slug, "train", 50);

    r = duplicate_project(a.pid);
    assert "error" not in r, r;
    assert r["name"] == "Original copy", r;
    assert r["slug"] == "original-copy", r;
    assert r["pid"] != a.pid, "fresh pid";
    assert r["use_case"] == "convert python to jac" and r["provider"] == "mlx", r;
    assert r["model"] == "qwen3" and r["group_id"] == "ws02", r;
    assert r["source_count"] == 1, r;
    assert r["plan_copied"] == True, r;
    assert r["copied_bytes"] == 0 and r["copied_files"] == [], "no dataset copied by default";
    # The clone's own dataset dir is empty — the original's rows are untouched.
    clone_dir = jms_project_dir(str(r["slug"]));
    assert clone_dir.is_dir() and not (clone_dir / "dataset" / "train.jsonl").exists();
    assert (jms_project_dir(a.slug) / "dataset" / "train.jsonl").exists(), "source untouched";
    # Clone's graph carries the scanned source + the approved plan (renumbered v1).
    full = get_project(str(r["pid"]));
    assert len(full["sources"]) == 1 and full["sources"][0]["files"] == 4, full["sources"];
    assert full["stage_state"]["sources"] == "done", full["stage_state"];
    assert full["stage_state"]["generate"] == "done", full["stage_state"];
    assert full["plans"][0]["version"] == 1 and full["plans"][0]["target_rows"] == 500, full["plans"];
    # …and NOT the runs/jobs history.
    assert full["gen_jobs"] == [] and full["train_runs"] == [] and full["evals"] == [];
    # Original still listed, unmodified.
    assert len([p for p in list_projects() if p.pid == a.pid]) == 1;
}

test "duplicate_project opt-in copy_curated streams train + holdout only" {
    _isolate_ws();
    a = create_project("Copyme", "x");
    _seed_dataset(a.slug, "train", 100);
    _seed_dataset(a.slug, "holdout", 10);
    r = duplicate_project(a.pid, "Copyme Full", True);
    assert "error" not in r, r;
    assert r["slug"] == "copyme-full", r;
    files = [str(f["file"]) for f in r["copied_files"]];
    assert files == ["train.jsonl", "holdout.jsonl"], files;
    assert r["copied_bytes"] > 0, r;
    cd = jms_project_dir("copyme-full") / "dataset";
    assert (cd / "train.jsonl").exists() and (cd / "holdout.jsonl").exists();
    # Byte-identical + no leftover .tmp sibling.
    assert (cd / "train.jsonl").read_text() == (jms_project_dir(a.slug) / "dataset" / "train.jsonl").read_text();
    assert not (cd / "train.jsonl.tmp").exists(), "atomic write cleaned up";
    assert get_project(str(r["pid"]))["row_stats"]["curated"] == 100;
}

test "duplicate_project with a custom name, no dataset, and an unknown pid" {
    _isolate_ws();
    a = create_project("Bare", "x");
    r = duplicate_project(a.pid, "Renamed Clone", True);
    assert r["name"] == "Renamed Clone" and r["slug"] == "renamed-clone", r;
    assert r["copied_files"] == [] and "no materialized dataset" in str(r["note"]), r;
    assert r["plan_copied"] == False, r;
    assert "error" in duplicate_project("no-such-pid"), "unknown pid rejected";
    # Duplicating twice de-dupes the slug rather than colliding on disk.
    r2 = duplicate_project(a.pid, "Renamed Clone");
    assert r2["slug"] == "renamed-clone-2", r2;
}

test "dataset_export_info reports sizes + the response budget" {
    _isolate_ws();
    a = create_project("Sized", "x");
    info0 = dataset_export_info(a.pid);
    assert info0["train"]["exists"] == False and info0["train"]["lines"] == 0, info0;
    _seed_dataset(a.slug, "train", 25);
    info = dataset_export_info(a.pid);
    assert info["train"]["exists"] == True and info["train"]["lines"] == 25, info;
    assert info["train"]["bytes"] > 0 and info["total_bytes"] == info["train"]["bytes"], info;
    assert info["max_response_bytes"] == _EXPORT_MAX_BYTES, info;
    assert "error" in dataset_export_info("no-such-pid");
}

test "export_dataset paginates under the line budget and says so" {
    _isolate_ws();
    a = create_project("Exportme", "x");
    n = _EXPORT_MAX_LINES + 37;
    _seed_dataset(a.slug, "train", n);
    pg1 = export_dataset(a.pid, "train");
    assert pg1["count"] == _EXPORT_MAX_LINES, pg1["count"];
    assert pg1["eof"] == False and pg1["truncated"] == True, pg1;
    assert pg1["note"], "a capped page must say it was capped";
    assert pg1["bytes"] <= _EXPORT_MAX_BYTES, pg1["bytes"];
    assert pg1["filename"] == "exportme-train.jsonl", pg1["filename"];
    pg2 = export_dataset(a.pid, "train", int(str(pg1["next_offset"])));
    assert pg2["count"] == 37, pg2["count"];
    assert pg2["eof"] == True and pg2["truncated"] == False, pg2;
    # Nothing lost, nothing duplicated across the page boundary.
    allrows = list(pg1["lines"]) + list(pg2["lines"]);
    assert len(allrows) == n, len(allrows);
    assert allrows[0] == '{"i": 0, "text": "row 0"}', allrows[0];
    assert allrows[n - 1] == f'{{"i": {n - 1}, "text": "row {n - 1}"}}', allrows[n - 1];
}

test "export_dataset validates pid / which / materialization" {
    _isolate_ws();
    a = create_project("Guarded", "x");
    assert "error" in export_dataset("no-such-pid");
    assert "error" in export_dataset(a.pid, "adapters"), "only train|holdout";
    assert "error" in export_dataset(a.pid, "holdout"), "not materialized yet";
    _seed_dataset(a.slug, "holdout", 3);
    ok = export_dataset(a.pid, "holdout");
    assert ok["count"] == 3 and ok["eof"] == True, ok;
}

test "export_summary renders JSON and Markdown with counts + stage state" {
    _isolate_ws();
    a = create_project("Summed", "make it good at jac");
    add_source(a.pid, "code", _make_tree());
    _seed_dataset(a.slug, "train", 12);
    j = export_summary(a.pid);
    assert j["filename"] == "summed-summary.json" and j["mime"] == "application/json", j["filename"];
    assert j["truncated"] == False and j["bytes"] == len(str(j["content"])), j["bytes"];
    parsed = json.loads(str(j["content"]));
    assert parsed["project"]["slug"] == "summed", parsed["project"];
    assert parsed["counts"]["sources"] == 1 and parsed["counts"]["curated_rows"] == 12, parsed["counts"];
    assert parsed["stage_state"]["curate"] == "done", parsed["stage_state"];

    m = export_summary(a.pid, "md");
    assert m["filename"] == "summed-summary.md" and m["mime"] == "text/markdown", m["filename"];
    body = str(m["content"]);
    assert body.startswith("# Summed"), body[:40];
    assert "| curated_rows | 12 |" in body, body;
    assert "## Train runs" in body and "_none_" in body, body;
    assert "error" in export_summary("no-such-pid");
    assert "error" in export_summary(a.pid, "pdf"), "only json|md";
}

test "export_summary caps long lists instead of truncating silently" {
    _isolate_ws();
    a = create_project("Many Evals", "x");
    node_a = _find_project(a.pid);
    over = _SUMMARY_MAX_ITEMS + 5;
    for i in range(over) {
        (node_a ++> JmsEvalRun(eid=f"e{i}", run_rid="r1", status="completed",
                               n=1, started=f"2026-01-01T00:00:{i % 60:02d}Z"))[0];
    }
    j = export_summary(a.pid);
    parsed = json.loads(str(j["content"]));
    assert parsed["counts"]["evals"] == over, parsed["counts"];
    assert len(parsed["evals"]) == _SUMMARY_MAX_ITEMS, len(parsed["evals"]);
    joined = " ".join([str(x) for x in parsed["notes"]]);
    assert "evals" in joined and "capped" in joined, parsed["notes"];
    assert int(j["bytes"]) <= _EXPORT_MAX_BYTES, j["bytes"];
}
