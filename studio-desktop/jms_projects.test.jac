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
