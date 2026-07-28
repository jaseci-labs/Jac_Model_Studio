"""studio - unit tests for cptsft.sv.jac row parsing + fence helpers.

Covers the pure record→DataRowView classifier (`_build_row`) that powers the 04
CPT-SFT DATA browser, plus the markdown-fence extractors it relies on. 04's rows
carry category/complexity/task_type at TOP level (no `meta` envelope), so these
assert that shape specifically. No filesystem or workspace registry is touched.

Annex file: pairs with cptsft.sv.jac. Run with `jac test cptsft.test.jac`.
"""

test "_fence extracts a language-tagged code block" {
    text = "here:\n```python\nprint('hi')\n```\ndone";
    assert _fence(text, "python") == "print('hi')", _fence(text, "python");
}

test "_fence returns empty when there is no fence at all" {
    assert _fence("just prose", "jac") == "";
}

test "_build_row classifies an SFT messages record with top-level category" {
    rec = {
        "category": "code_gen",
        "complexity": "medium",
        "task_type": "cl_component_authoring",
        "messages": [
            {"role": "user", "content": "Write it:\n```python\ndef sq(x): return x*x\n```"},
            {"role": "assistant", "content": "```jac\ndef sq(x: int) -> int { return x * x; }\n```"}
        ]
    };
    row = _build_row(0, rec);
    assert row.kind == "sft", row.kind;
    assert row.source == "code_gen", row.source;          # category → source column
    assert row.difficulty == "medium", row.difficulty;    # complexity → difficulty column
    assert row.name == "cl_component_authoring", row.name; # task_type → name
    assert row.jac.startswith("def sq(x: int)"), row.jac;
}

test "_build_row classifies a DPO record and lifts axis into source" {
    rec = {
        "axis": "graph_native",
        "prompt": "Write a Jac add function",
        "chosen": "```jac\ndef add(a: int, b: int) -> int { return a + b; }\n```",
        "rejected": "```jac\ndef add(a, b) { return a + b }\n```"
    };
    row = _build_row(3, rec);
    assert row.kind == "dpo", row.kind;
    assert row.idx == 3, row.idx;
    assert row.source == "graph_native", row.source;       # axis → source
    assert row.name == "graph_native", row.name;
    assert row.chosen.startswith("def add(a: int"), row.chosen;
    assert row.rejected.startswith("def add(a, b)"), row.rejected;
}

test "_build_row falls back to raw for an unrecognized record" {
    row = _build_row(0, {"something": "unexpected"});
    assert row.kind == "raw", row.kind;
    assert "unexpected" in row.raw, row.raw;
    assert row.name == "—", row.name;
}

test "_build_row defaults difficulty and source to em-dash when fields absent" {
    row = _build_row(0, {"messages": []});
    assert row.difficulty == "—", row.difficulty;
    assert row.source == "—", row.source;
}

test "_row_matches passes everything when both filters are empty" {
    assert _row_matches({"category": "debug"}, "", "");
    assert _row_matches({"axis": "typing"}, "", "");
    assert _row_matches({}, "", "");
}

test "_row_matches filters SFT rows by category" {
    assert _row_matches({"category": "debug"}, "debug", "");
    assert not _row_matches({"category": "code_gen"}, "debug", "");
    assert not _row_matches({}, "debug", "");             # missing category never matches a filter
}

test "_row_matches filters DPO rows by axis" {
    assert _row_matches({"axis": "graph_native"}, "", "graph_native");
    assert not _row_matches({"axis": "idiomatic"}, "", "graph_native");
    assert not _row_matches({}, "", "graph_native");
}

test "_allowed gates to the release + holdout allowlist only" {
    assert _allowed("model-experiments/04-cpt-sft/dataset/fresh/releases/sft_train.jsonl");
    assert _allowed("model-experiments/04-cpt-sft/dataset/shared/holdouts/debug_holdout.jsonl");
    assert not _allowed("model-experiments/04-cpt-sft/dataset/fresh/rejected/x.jsonl");
    assert not _allowed("model-experiments/04-cpt-sft/dataset/fresh/logs/run.log");
}
