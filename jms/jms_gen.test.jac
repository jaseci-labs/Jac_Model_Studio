"""studio - tests for jms_gen.sv.jac (SYNTHESIZE estimates, refusals, validator).

Covers the pure pieces without spawning workers: estimate_gen math (claude
priced / mlx free / cap), the sft-chat row validator (master copy of the
worker's duplicate), and every start_gen refusal path — unknown project, bad
provider, no approved plan, no scanned source, claude without a key, target
over the cap, mlx with an unknown model. Plans are fabricated directly as
JmsGenPlan nodes (draft_plan would need a live LLM).

Shares a persisted root (see jac guide jac-testing) — each test creates its own
project. Workspace redirected to a temp dir so nothing lands in the repo.
Run with `jac test jms_gen.sv.jac`; `jac clean --data --force` if a re-run flakes.
"""

import os;
import tempfile;
import from jms_projects { JmsGenPlan, create_project, add_source }
import from jms_llm { clear_anthropic_key }

def _isolate_ws -> None {
    os.environ["JAC_STUDIO_WORKSPACE"] = tempfile.mkdtemp(prefix="studio-jmsgen-");
}

"""A one-file real source tree add_source can scan."""
def _mk_tree -> str {
    d = tempfile.mkdtemp(prefix="jmsgen-src-");
    f: any = open(os.path.join(d, "a.py"), "w");
    f.write("def hello():\n    return 1\n");
    f.close();
    return d;
}

glob _PLAN_BODY: str = '{"description": "d", "schema": "sft-chat", "mix": [{"type_name": "t", "description": "x", "share_pct": 100}], "target_rows": 10, "system_prompt": "s", "grounding_notes": "g"}';

"""Fabricate an approved plan node on *pid* (draft_plan needs a live LLM)."""
def _approve_fake_plan(pid: str) -> None {
    p = _find_project(pid);
    if p is None { return; }
    p ++> JmsGenPlan(
        version=1, status="approved", provider="claude", model="claude-sonnet-5",
        plan_json=_PLAN_BODY, created="t", approved_at="t"
    );
}

test "estimate_gen math: claude priced, batches/token totals correct" {
    e = estimate_gen("any-pid", "claude", "claude-sonnet-5", 40, 8);
    assert int(str(e["batches"])) == 5, e;
    assert int(str(e["est_input_tokens"])) == 5 * (1200 + 3 * 3000), e;
    assert int(str(e["est_output_tokens"])) == 40 * 450, e;
    assert float(str(e["est_cost_usd"])) > 0.0, e;
    assert bool(e["cap_ok"]), e;
}

test "estimate_gen math: mlx models cost zero; cap trips over 5000" {
    e = estimate_gen("any-pid", "mlx", "qwen-q4", 40, 8);
    assert float(str(e["est_cost_usd"])) == 0.0, e;
    over = estimate_gen("any-pid", "claude", "claude-sonnet-5", 6000, 8);
    assert not bool(over["cap_ok"]), over;
    zero = estimate_gen("any-pid", "claude", "claude-sonnet-5", 0, 8);
    assert not bool(zero["cap_ok"]), zero;
}

test "validate_row accepts well-formed sft-chat rows" {
    ok = {"messages": [{"role": "user", "content": "q"}, {"role": "assistant", "content": "a"}]};
    assert validate_row(ok);
    sys_first = {"messages": [
        {"role": "system", "content": "s"},
        {"role": "user", "content": "q"},
        {"role": "assistant", "content": "a"}
    ]};
    assert validate_row(sys_first);
    multi = {"messages": [
        {"role": "user", "content": "q1"}, {"role": "assistant", "content": "a1"},
        {"role": "user", "content": "q2"}, {"role": "assistant", "content": "a2"}
    ]};
    assert validate_row(multi);
}

test "validate_row rejects malformed rows" {
    assert not validate_row({});
    assert not validate_row({"messages": []});
    assert not validate_row({"messages": "nope"});
    assert not validate_row({"messages": [{"role": "user", "content": "only user"}]});
    # ends on user
    assert not validate_row({"messages": [{"role": "user", "content": "q"}, {"role": "assistant", "content": "a"}, {"role": "user", "content": "q2"}]});
    # consecutive same role
    assert not validate_row({"messages": [{"role": "user", "content": "q"}, {"role": "user", "content": "q2"}, {"role": "assistant", "content": "a"}]});
    # empty content
    assert not validate_row({"messages": [{"role": "user", "content": "  "}, {"role": "assistant", "content": "a"}]});
    # bad leading role
    assert not validate_row({"messages": [{"role": "assistant", "content": "a"}, {"role": "assistant", "content": "b"}]});
    # non-dict message
    assert not validate_row({"messages": ["hi", {"role": "assistant", "content": "a"}]});
}

test "start_gen refuses unknown project and bad provider" {
    _isolate_ws();
    r = start_gen("no-such-pid", "claude", "claude-sonnet-5", 10, 12);
    assert not bool(r["ok"]) and "unknown project" in str(r["error"]), r;
    v = create_project("Gen Guard", "test");
    r2 = start_gen(v.pid, "openai", "gpt-x", 10, 12);
    assert not bool(r2["ok"]) and "unknown provider" in str(r2["error"]), r2;
}

test "start_gen refuses without an approved plan, then without a scanned source" {
    _isolate_ws();
    v = create_project("Gen NoPlan", "test");
    added = add_source(v.pid, "code", _mk_tree());
    assert "error" not in added, added;
    r = start_gen(v.pid, "claude", "claude-sonnet-5", 10, 12);
    assert not bool(r["ok"]) and "approved plan" in str(r["error"]), r;
    # plan but no source
    v2 = create_project("Gen NoSource", "test");
    _approve_fake_plan(v2.pid);
    r2 = start_gen(v2.pid, "claude", "claude-sonnet-5", 10, 12);
    assert not bool(r2["ok"]) and "scanned source" in str(r2["error"]), r2;
}

test "start_gen refuses claude without a key and targets over the cap" {
    _isolate_ws();
    v = create_project("Gen NoKey", "test");
    add_source(v.pid, "code", _mk_tree());
    _approve_fake_plan(v.pid);
    over = start_gen(v.pid, "claude", "claude-sonnet-5", 6000, 7000);
    assert not bool(over["ok"]) and "cap" in str(over["error"]), over;
    # clear both key sources (user node + env) so resolution comes up empty
    clear_anthropic_key();
    saved = str(os.environ.pop("ANTHROPIC_API_KEY", ""));
    r = start_gen(v.pid, "claude", "claude-sonnet-5", 10, 12);
    if saved { os.environ["ANTHROPIC_API_KEY"] = saved; }
    assert not bool(r["ok"]) and "Anthropic key" in str(r["error"]), r;
}

test "start_gen refuses mlx with an unknown/off-disk model" {
    _isolate_ws();
    v = create_project("Gen NoModel", "test");
    add_source(v.pid, "code", _mk_tree());
    _approve_fake_plan(v.pid);
    r = start_gen(v.pid, "mlx", "no-such-model", 10, 12);
    assert not bool(r["ok"]), r;
    assert "local model" in str(r["error"]), r;
}

test "list_gen_jobs and gen_status are empty-safe" {
    _isolate_ws();
    v = create_project("Gen Empty", "test");
    assert list_gen_jobs(v.pid) == [], "no jobs yet";
    s = gen_status(v.pid);
    assert "error" in s and "no generation jobs" in str(s["error"]), s;
}
