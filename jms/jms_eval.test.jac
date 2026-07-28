"""studio - tests for jms_eval.sv.jac (holdout scoring: math + guards + paging).

Pure-and-cheap coverage only — no worker spawn, no mlx, no Anthropic. Covers the
similarity 1-5 mapping, the summary (mean/pass_rate) math, the judge-without-key
metric fallback, start_eval's guard ladder (unknown project / bad metric / no
holdout / unknown run), and eval_rows offset-pagination over fabricated
outputs.jsonl + scores.jsonl.

Shares a persisted root (see `jac guide jac-testing`); workspace redirected to a
temp dir so nothing lands in the repo, and ANTHROPIC_API_KEY is cleared so the
judge-fallback assertions are deterministic. Run with `jac test jms_eval.test.jac`;
`jac clean --data --force` if a re-run flakes.
"""

import os;
import json;
import tempfile;
import from jms_projects { JmsProject, JmsEvalRun, create_project, _find_project, jms_project_dir }

def _isolate_ws -> None {
    os.environ["JAC_STUDIO_WORKSPACE"] = tempfile.mkdtemp(prefix="studio-jmseval-");
    try { os.environ.pop("ANTHROPIC_API_KEY"); } except Exception {}
}

"""Write a 1-line holdout so start_eval clears the holdout guard."""
def _seed_holdout(pid: str) -> None {
    p = _find_project(pid);
    d = jms_project_dir(p.slug) / "dataset";
    d.mkdir(parents=True, exist_ok=True);
    row = {"messages": [
        {"role": "user", "content": "q"},
        {"role": "assistant", "content": "a"}
    ]};
    (d / "holdout.jsonl").write_text(json.dumps(row) + "\n");
}

# ---------------------------------------------------------------- pure math ----
test "similarity_score maps difflib ratio to 1-5" {
    assert similarity_score("abc", "abc") == 5, "identical → 5";
    assert similarity_score("", "xyz") == 1, "disjoint (ratio 0) → 1";
    # "abcd" vs "abef": common "ab" → 2*2/(4+4)=0.5 → round(2.0)+1 = 3
    assert similarity_score("abcd", "abef") == 3, "half overlap → 3";
    s = similarity_score("hello world", "hello there");
    assert s >= 1 and s <= 5, "always in range";
}

test "summarize computes n / mean / pass_rate" {
    r = summarize([5, 4, 3, 2, 1], 4);
    assert int(str(r["n"])) == 5, r;
    assert abs(float(str(r["mean_score"])) - 3.0) < 0.0001, r;
    # 2 of 5 are >= 4
    assert abs(float(str(r["pass_rate"])) - 0.4) < 0.0001, r;
    e = summarize([], 4);
    assert int(str(e["n"])) == 0 and float(str(e["mean_score"])) == 0.0, e;
    assert float(str(e["pass_rate"])) == 0.0, e;
    # pass_score threshold shifts the rate
    r3 = summarize([5, 4, 3, 2, 1], 3);
    assert abs(float(str(r3["pass_rate"])) - 0.6) < 0.0001, r3;
}

# ------------------------------------------------------------ metric fallback --
test "judge with no key falls back to similarity" {
    _isolate_ws();
    eff = _effective_metric("judge");
    assert str(eff["metric"]) == "similarity", eff;
    assert str(eff["note"]) != "", "carries a note";
    keep = _effective_metric("similarity");
    assert str(keep["metric"]) == "similarity" and str(keep["note"]) == "", keep;
}

# --------------------------------------------------------------- guard ladder --
test "start_eval: unknown project" {
    _isolate_ws();
    r = start_eval("nope", "rid", "similarity", 0);
    assert not bool(r["ok"]) and str(r["error"]) == "unknown project", r;
}

test "start_eval: bad metric rejected before spawn" {
    _isolate_ws();
    v = create_project("Eval Metric", "t");
    r = start_eval(v.pid, "rid", "bogus", 0);
    assert not bool(r["ok"]), r;
    assert "metric must be" in str(r["error"]), r;
}

test "start_eval: no holdout rows" {
    _isolate_ws();
    v = create_project("Eval NoHoldout", "t");
    r = start_eval(v.pid, "rid", "similarity", 0);
    assert not bool(r["ok"]), r;
    assert "holdout" in str(r["error"]), r;
}

test "start_eval: unknown run (past holdout+metric guards)" {
    _isolate_ws();
    v = create_project("Eval NoRun", "t");
    _seed_holdout(v.pid);
    r = start_eval(v.pid, "ghost", "similarity", 0);
    assert not bool(r["ok"]), r;
    assert "unknown run" in str(r["error"]), r;
}

# ----------------------------------------------------------------- eval_rows ---
"""Attach a JmsEvalRun node + write fabricated outputs.jsonl/scores.jsonl."""
def _seed_eval(pid: str, eid: str, n: int) -> None {
    p = _find_project(pid);
    p ++> JmsEvalRun(eid=eid, run_rid="r1", metric="similarity", status="completed", n=n);
    ed = jms_project_dir(p.slug) / "evals" / eid;
    ed.mkdir(parents=True, exist_ok=True);
    olines: list[str] = [];
    slines: list[str] = [];
    for i in range(n) {
        olines.append(json.dumps({
            "idx": i,
            "prompt_messages": [{"role": "user", "content": "prompt " + str(i)}],
            "reference": "ref " + str(i),
            "generated": "gen " + str(i)
        }));
        slines.append(json.dumps({"idx": i, "score": (i % 5) + 1, "rationale": "because " + str(i)}));
    }
    (ed / "outputs.jsonl").write_text("\n".join(olines) + "\n");
    (ed / "scores.jsonl").write_text("\n".join(slines) + "\n");
}

test "eval_rows paginates + merges scores" {
    _isolate_ws();
    v = create_project("Eval Rows", "t");
    _seed_eval(v.pid, "ev1", 5);

    pg0 = eval_rows(v.pid, "ev1", 0, 2);
    assert int(str(pg0["total"])) == 5, pg0;
    assert len(list(pg0["rows"])) == 2, pg0;
    r0 = dict(list(pg0["rows"])[0]);
    assert str(r0["idx"]) == "0", r0;
    assert str(r0["reference"]) == "ref 0" and str(r0["generated"]) == "gen 0", r0;
    assert int(str(r0["score"])) == 1, r0;                       # (0%5)+1
    assert "prompt 0" in str(r0["prompt_excerpt"]), r0;
    assert "because 0" in str(r0["rationale"]), r0;

    pg1 = eval_rows(v.pid, "ev1", 2, 2);
    ids = [str(dict(x)["idx"]) for x in list(pg1["rows"])];
    assert ids == ["2", "3"], ids;

    tail = eval_rows(v.pid, "ev1", 4, 10);
    assert len(list(tail["rows"])) == 1 and str(dict(list(tail["rows"])[0])["idx"]) == "4", tail;

    # unknown eval → empty, zero-safe
    none = eval_rows(v.pid, "nope", 0, 10);
    assert int(str(none["total"])) == 0 and len(list(none["rows"])) == 0, none;
}
