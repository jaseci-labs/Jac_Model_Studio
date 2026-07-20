"""studio - unit tests for the metrics.sv.jac parsers.

Pure-logic coverage for the training/eval artifact parsers that feed the Train
HISTORY / MONITOR views. Each test writes a fixture into an isolated temp dir and
asserts the parsed shape, so nothing here touches the real data_root or a server.

Annex file: pairs with metrics.sv.jac and sees its private `def`s directly.
Run with `jac test metrics.sv.jac`.
"""

import tempfile;
import from pathlib { Path }

"""Write `text` to a fresh temp file and return its Path (auto-cleaned by the OS)."""
def _tmpfile(text: str, suffix: str = ".log") -> Path {
    d = tempfile.mkdtemp(prefix="studio-metrics-");
    p = Path(d) / f"fixture{suffix}";
    p.write_text(text);
    return p;
}

test "parse_train_log reads mlx SFT format" {
    log = (
        "Iter 1: Train loss 2.500, Learning Rate 1.0e-5, Tokens/sec 120.0\n"
        "Iter 2: Val loss 2.100\n"
        "Iter 2: Train loss 2.000, Learning Rate 1.0e-5, Tokens/sec 130.0\n"
    );
    r = parse_train_log(_tmpfile(log));
    # Series values come back as `any` out of the dict; bind typed lists so the
    # checker (and len/index) are happy while asserting the same shape.
    train: list = list(r["train"]);
    val: list = list(r["val"]);
    tps: list = list(r["tps"]);
    lr: list = list(r["lr"]);
    assert r["last_iter"] == 2, r;
    assert len(train) == 2, train;
    assert train[0] == {"x": 1, "y": 2.5}, train[0];
    assert len(val) == 1, val;
    assert val[0]["y"] == 2.1, val;
    assert len(tps) == 2, tps;
    assert len(lr) == 2, lr;
}

test "parse_train_log reads DPO ': loss' format" {
    log = "Iter 10: loss 0.693, lr 5.0e-6, tok/s 88.0\n";
    r = parse_train_log(_tmpfile(log));
    train: list = list(r["train"]);
    lr: list = list(r["lr"]);
    tps: list = list(r["tps"]);
    assert r["last_iter"] == 10, r;
    assert train[0] == {"x": 10, "y": 0.693}, train;
    assert lr[0]["y"] == 5.0e-6, lr;
    assert tps[0]["y"] == 88.0, tps;
}

test "parse_train_log skips lines without an Iter marker" {
    log = "Starting training...\nrandom noise\nIter 3: Train loss 1.0\n";
    r = parse_train_log(_tmpfile(log));
    train: list = list(r["train"]);
    assert r["last_iter"] == 3, r;
    assert len(train) == 1, train;
}

test "parse_train_log returns empty shape for a missing file" {
    r = parse_train_log(Path("/nonexistent/does-not-exist.log"));
    assert r == {"train": [], "val": [], "lr": [], "tps": [], "last_iter": 0}, r;
}

test "read_series pulls x/y pairs and skips malformed rows" {
    body = (
        '{"step": 0, "acc": 0.10}\n'
        'not json at all\n'
        '{"step": 1, "acc": 0.55}\n'
        '{"step": 2}\n'                 # missing ykey → skipped
        '{"step": 3, "acc": 0.90}\n'
    );
    series = read_series(_tmpfile(body, ".jsonl"), "acc");
    assert len(series) == 3, series;
    assert series[0] == {"x": 0, "y": 0.10}, series[0];
    assert series[2] == {"x": 3, "y": 0.90}, series[2];
}

test "read_series is empty for a missing file" {
    assert read_series(Path("/nope/missing.jsonl"), "acc") == [];
}

test "last_row returns the final parseable object" {
    body = '{"step": 0, "v": 1}\n{"step": 1, "v": 2}\nbroken\n{"step": 2, "v": 3}\n';
    r = last_row(_tmpfile(body, ".jsonl"));
    assert r["step"] == 2 and r["v"] == 3, r;
}

test "last_row is empty for a file with no JSON objects" {
    assert last_row(_tmpfile("just\nsome\ntext\n")) == {};
}

test "tail returns the last n lines" {
    body = "\n".join([str(i) for i in range(100)]);
    out = tail(_tmpfile(body), 5);
    assert out == "95\n96\n97\n98\n99", out;
}

test "tail is empty for a missing file" {
    assert tail(Path("/nope/missing.log")) == "";
}

test "last_iter finds the maximum Iter across the file" {
    body = "Iter 5\nIter 42\nIter 7\n";
    assert last_iter(_tmpfile(body)) == 42;
    assert last_iter(Path("/nope/missing.log")) == 0;
}

test "merge_by_x overlays per-run series and sorts by x" {
    by_run = {
        "runA": [{"x": 0, "y": 1.0}, {"x": 2, "y": 3.0}],
        "runB": [{"x": 0, "y": 9.0}, {"x": 1, "y": 8.0}]
    };
    rows = merge_by_x(by_run);
    assert len(rows) == 3, rows;
    assert rows[0] == {"x": 0, "runA": 1.0, "runB": 9.0}, rows[0];
    assert rows[1] == {"x": 1, "runB": 8.0}, rows[1];
    assert rows[2] == {"x": 2, "runA": 3.0}, rows[2];
}

test "stages lists only completed stage markers in canonical order" {
    d = Path(tempfile.mkdtemp(prefix="studio-stages-"));
    (d / ".base.done").write_text("");
    (d / ".train.done").write_text("");
    (d / ".finetuned.done").write_text("");
    found = stages(d);
    assert found == ["base", "train", "finetuned"], found;
    assert stages(Path("/nope/missing")) == [];
}

test "idiom_summary picks the row carrying avg_sim" {
    d = Path(tempfile.mkdtemp(prefix="studio-idiom-"));
    (d / "idiom-metrics.jsonl").write_text(
        '{"step": 0}\n{"step": 1, "avg_sim": 0.82, "idiomatic": 4}\n'
    );
    row = idiom_summary(d, "sft", "function");
    assert row["avg_sim"] == 0.82, row;
    assert row["idiomatic"] == 4, row;
    # Nothing on disk for the graph kind → empty dict.
    assert idiom_summary(d, "sft", "graph") == {}, "expected empty for missing graph metrics";
}
