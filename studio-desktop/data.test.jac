"""studio - unit tests for data.sv.jac row parsing + fence helpers.

Covers the pure record→DataRowView classifier (`_build_row`) that powers the DATA
and RL DATA browsers, plus the markdown-fence / func-name extractors it relies on.
No filesystem or workspace registry is touched, so these run anywhere.

Annex file: pairs with data.sv.jac. Run with `jac test data.sv.jac`.
"""

test "_fence extracts a language-tagged code block" {
    text = "here you go:\n```python\nprint('hi')\n```\nthanks";
    assert _fence(text, "python") == "print('hi')", _fence(text, "python");
}

test "_fence falls back to the first untagged block for an absent language" {
    text = "```\nsome code\n```";
    assert _fence(text, "python") == "some code", _fence(text, "python");
}

test "_fence returns empty when there is no fence at all" {
    assert _fence("just prose, no code", "jac") == "";
}

test "_funcname recognizes def / walker / node / obj / class" {
    assert _funcname("def add(a, b) { return a + b; }") == "add";
    assert _funcname("walker Crawl {}") == "Crawl";
    assert _funcname("node Person {}") == "Person";
    assert _funcname("obj View {}") == "View";
    assert _funcname("class Foo: pass") == "Foo";
    assert _funcname("no declaration here") == "";
}

test "_first_line trims and truncates long lines" {
    assert _first_line("\n\n  hello world  \nsecond") == "hello world";
    long = "x" * 200;
    out = _first_line(long);
    assert out.endswith("…"), out;
    assert len(out) == 91, len(out);          # 90 chars + ellipsis
}

test "_strip_fences removes fenced blocks, keeping prose" {
    text = "before\n```python\ncode\n```\nafter";
    stripped = _strip_fences(text);
    assert "code" not in stripped, stripped;
    assert "before" in stripped and "after" in stripped, stripped;
}

test "_build_row classifies an SFT messages record" {
    rec = {
        "messages": [
            {"role": "user", "content": "Convert this:\n```python\ndef sq(x): return x*x\n```"},
            {"role": "assistant", "content": "```jac\ndef sq(x: int) -> int { return x * x; }\n```"}
        ],
        "meta": {"difficulty": "easy", "source": "seed"}
    };
    row = _build_row(0, rec);
    assert row.kind == "sft", row.kind;
    assert row.difficulty == "easy", row.difficulty;
    assert row.source == "seed", row.source;
    assert "def sq(x): return x*x" == row.python, row.python;
    assert row.jac.startswith("def sq(x: int)"), row.jac;
    assert row.name == "sq", row.name;               # func name lifted from the code
}

test "_build_row classifies a DPO chosen/rejected record" {
    rec = {
        "prompt": "Write a Jac add function",
        "chosen": "```jac\ndef add(a: int, b: int) -> int { return a + b; }\n```",
        "rejected": "```jac\ndef add(a, b) { return a + b }\n```"
    };
    row = _build_row(3, rec);
    assert row.kind == "dpo", row.kind;
    assert row.idx == 3, row.idx;
    assert row.chosen.startswith("def add(a: int"), row.chosen;
    assert row.rejected.startswith("def add(a, b)"), row.rejected;
}

test "_build_row classifies a holdout record" {
    rec = {"python": "def mul(a, b): return a*b", "prompt": "multiply", "func_name": "mul"};
    row = _build_row(1, rec);
    assert row.kind == "holdout", row.kind;
    assert row.python == "def mul(a, b): return a*b", row.python;
    assert row.name == "mul", row.name;
}

test "_build_row classifies an RL task record and unpacks its answer" {
    rec = {
        "prompt": "solve it",
        "answer": '{"id": "task-7", "source": "grpo", "expected_output": "42", "timeout": 5}'
    };
    row = _build_row(2, rec);
    assert row.kind == "rltask", row.kind;
    assert row.name == "task-7", row.name;
    assert row.source == "grpo", row.source;
    assert row.jac == "42", row.jac;
}

test "_build_row falls back to raw for an unrecognized record" {
    rec = {"something": "unexpected"};
    row = _build_row(0, rec);
    assert row.kind == "raw", row.kind;
    assert "unexpected" in row.raw, row.raw;
    assert row.name == "—", row.name;               # no func name → em-dash placeholder
}

test "_build_row defaults difficulty and source to em-dash when meta is absent" {
    row = _build_row(0, {"messages": []});
    assert row.difficulty == "—", row.difficulty;
    assert row.source == "—", row.source;
}
