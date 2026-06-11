"""Tests for runlogs.py — pure log/metrics parsers.

Each test writes its own fixture content via tmp_path so there are no
external file dependencies.
"""
import json
from pathlib import Path

import pytest

import config
import runlogs


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

SFT_LOG = """\
Iter 1: Val loss 1.781
Iter 10: Train loss 1.888, Learning Rate 3.000e-06, It/sec 0.5, Tokens/sec 483.916, Trained Tokens 9678, Peak mem 30.1 GB
Iter 20: Train loss 1.402, Learning Rate 3.000e-06, Tokens/sec 410.2
"""

DPO_LOG = """\
Iter 5: loss 0.693, lr 1.000e-06, tok/s 120.5
"""


# ---------------------------------------------------------------------------
# parse_train_log
# ---------------------------------------------------------------------------

class TestParseTrainLog:
    def test_sft_train_series(self, tmp_path):
        p = tmp_path / "train.log"
        p.write_text(SFT_LOG)
        r = runlogs.parse_train_log(p)
        assert r["train"] == [{"x": 10, "y": 1.888}, {"x": 20, "y": 1.402}]

    def test_sft_val_series(self, tmp_path):
        p = tmp_path / "train.log"
        p.write_text(SFT_LOG)
        r = runlogs.parse_train_log(p)
        assert r["val"] == [{"x": 1, "y": 1.781}]

    def test_sft_lr_series(self, tmp_path):
        p = tmp_path / "train.log"
        p.write_text(SFT_LOG)
        r = runlogs.parse_train_log(p)
        assert len(r["lr"]) == 2
        assert r["lr"][0] == {"x": 10, "y": 3.0e-6}
        assert r["lr"][1] == {"x": 20, "y": 3.0e-6}

    def test_sft_tps_series(self, tmp_path):
        p = tmp_path / "train.log"
        p.write_text(SFT_LOG)
        r = runlogs.parse_train_log(p)
        assert len(r["tps"]) == 2
        assert r["tps"][0] == {"x": 10, "y": 483.916}
        assert r["tps"][1]["x"] == 20

    def test_sft_last_iter(self, tmp_path):
        p = tmp_path / "train.log"
        p.write_text(SFT_LOG)
        r = runlogs.parse_train_log(p)
        assert r["last_iter"] == 20

    def test_dpo_train_series(self, tmp_path):
        p = tmp_path / "train.log"
        p.write_text(DPO_LOG)
        r = runlogs.parse_train_log(p)
        assert r["train"] == [{"x": 5, "y": 0.693}]

    def test_dpo_lr_series(self, tmp_path):
        p = tmp_path / "train.log"
        p.write_text(DPO_LOG)
        r = runlogs.parse_train_log(p)
        assert r["lr"] == [{"x": 5, "y": 1.0e-6}]

    def test_dpo_tps_series(self, tmp_path):
        p = tmp_path / "train.log"
        p.write_text(DPO_LOG)
        r = runlogs.parse_train_log(p)
        assert r["tps"] == [{"x": 5, "y": 120.5}]

    def test_missing_file_returns_empty(self, tmp_path):
        r = runlogs.parse_train_log(tmp_path / "no_such.log")
        assert r == {"train": [], "val": [], "lr": [], "tps": [], "last_iter": 0}


# ---------------------------------------------------------------------------
# read_series
# ---------------------------------------------------------------------------

JSONL_SERIES = """\
{"step": 100, "test_pass_pct": 42}
{"step": 200, "test_pass_pct": 55}
not-json-garbage
{"avg_sim": 0.91}
"""


class TestReadSeries:
    def test_normal_rows(self, tmp_path):
        p = tmp_path / "metrics.jsonl"
        p.write_text(JSONL_SERIES)
        out = runlogs.read_series(p, "test_pass_pct")
        assert out == [{"x": 100, "y": 42.0}, {"x": 200, "y": 55.0}]

    def test_malformed_line_skipped(self, tmp_path):
        p = tmp_path / "metrics.jsonl"
        p.write_text(JSONL_SERIES)
        out = runlogs.read_series(p, "test_pass_pct")
        # garbage line + summary row (no step) must be skipped → only 2 points
        assert len(out) == 2

    def test_missing_ykey_skipped(self, tmp_path):
        p = tmp_path / "metrics.jsonl"
        # row has step but not the requested key
        p.write_text('{"step": 1, "other": 99}\n{"step": 2, "val": 5}\n')
        out = runlogs.read_series(p, "val")
        assert out == [{"x": 2, "y": 5.0}]

    def test_missing_file_returns_empty(self, tmp_path):
        out = runlogs.read_series(tmp_path / "no.jsonl", "val")
        assert out == []


# ---------------------------------------------------------------------------
# last_row
# ---------------------------------------------------------------------------

class TestLastRow:
    def test_returns_last_json_object(self, tmp_path):
        p = tmp_path / "idiom.jsonl"
        p.write_text(
            '{"step": 1, "avg_sim": 0.8}\n'
            '{"avg_sim": 0.91, "idiomatic": 7, "python_shaped": 3}\n'
        )
        r = runlogs.last_row(p)
        assert r["avg_sim"] == 0.91
        assert r["idiomatic"] == 7

    def test_skips_non_json_lines(self, tmp_path):
        p = tmp_path / "idiom.jsonl"
        p.write_text('noise\n{"avg_sim": 0.5}\n# comment\n')
        r = runlogs.last_row(p)
        assert r == {"avg_sim": 0.5}

    def test_missing_file_returns_empty_dict(self, tmp_path):
        r = runlogs.last_row(tmp_path / "nope.jsonl")
        assert r == {}

    def test_empty_file_returns_empty_dict(self, tmp_path):
        p = tmp_path / "empty.jsonl"
        p.write_text("")
        r = runlogs.last_row(p)
        assert r == {}


# ---------------------------------------------------------------------------
# tail
# ---------------------------------------------------------------------------

class TestTail:
    def test_returns_last_n_lines(self, tmp_path):
        p = tmp_path / "train.log"
        lines = [f"line {i}" for i in range(50)]
        p.write_text("\n".join(lines))
        out = runlogs.tail(p, 10)
        # last 10 lines of a 50-line file
        assert "line 40" in out
        assert "line 49" in out
        assert "line 39" not in out

    def test_fewer_lines_than_n(self, tmp_path):
        p = tmp_path / "short.log"
        p.write_text("a\nb\nc")
        out = runlogs.tail(p, 40)
        assert out == "a\nb\nc"

    def test_missing_file_returns_empty_string(self, tmp_path):
        out = runlogs.tail(tmp_path / "ghost.log")
        assert out == ""

    def test_default_n_is_40(self, tmp_path):
        p = tmp_path / "train.log"
        lines = [f"L{i}" for i in range(100)]
        p.write_text("\n".join(lines))
        out = runlogs.tail(p)
        returned_lines = out.split("\n")
        # default n=40: 100 lines → start at index 60
        assert returned_lines[0] == "L60"
        assert returned_lines[-1] == "L99"


# ---------------------------------------------------------------------------
# pick_idiom
# ---------------------------------------------------------------------------

class TestPickIdiom:
    def _make_idiom_file(self, path: Path, has_avg_sim: bool = True):
        path.parent.mkdir(parents=True, exist_ok=True)
        row = {"avg_sim": 0.85} if has_avg_sim else {"other": 1}
        path.write_text(json.dumps(row) + "\n")

    def test_prefers_idiom_metrics_jsonl(self, tmp_path):
        run_dir = tmp_path / "myrun"
        self._make_idiom_file(run_dir / "idiom-metrics.jsonl")
        self._make_idiom_file(run_dir / "graph-idiom.jsonl")
        result = runlogs.pick_idiom(run_dir, "sft")
        assert result == run_dir / "idiom-metrics.jsonl"

    def test_fallback_to_graph_idiom(self, tmp_path):
        run_dir = tmp_path / "myrun"
        run_dir.mkdir()
        self._make_idiom_file(run_dir / "graph-idiom.jsonl")
        result = runlogs.pick_idiom(run_dir, "sft")
        assert result == run_dir / "graph-idiom.jsonl"

    def test_dpo_mode_looks_under_dpo_subdir(self, tmp_path):
        run_dir = tmp_path / "myrun"
        self._make_idiom_file(run_dir / "dpo" / "idiom-metrics.jsonl")
        result = runlogs.pick_idiom(run_dir, "dpo")
        assert result == run_dir / "dpo" / "idiom-metrics.jsonl"

    def test_dpo_mode_fallback_graph(self, tmp_path):
        run_dir = tmp_path / "myrun"
        self._make_idiom_file(run_dir / "dpo" / "graph-idiom.jsonl")
        result = runlogs.pick_idiom(run_dir, "dpo")
        assert result == run_dir / "dpo" / "graph-idiom.jsonl"

    def test_returns_none_when_neither_exists(self, tmp_path):
        run_dir = tmp_path / "myrun"
        run_dir.mkdir()
        result = runlogs.pick_idiom(run_dir, "sft")
        assert result is None

    def test_returns_none_when_no_avg_sim(self, tmp_path):
        run_dir = tmp_path / "myrun"
        # file exists but has no avg_sim key
        self._make_idiom_file(run_dir / "idiom-metrics.jsonl", has_avg_sim=False)
        self._make_idiom_file(run_dir / "graph-idiom.jsonl", has_avg_sim=False)
        result = runlogs.pick_idiom(run_dir, "sft")
        assert result is None


# ---------------------------------------------------------------------------
# stages
# ---------------------------------------------------------------------------

class TestStages:
    def test_train_and_curve_done(self, tmp_path):
        run_dir = tmp_path / "myrun"
        run_dir.mkdir()
        (run_dir / ".train.done").touch()
        (run_dir / ".curve.done").touch()
        result = runlogs.stages(run_dir)
        assert result == ["train", "curve"]

    def test_all_stages(self, tmp_path):
        run_dir = tmp_path / "myrun"
        run_dir.mkdir()
        for s in ["base", "dry", "train", "curve", "finetuned"]:
            (run_dir / f".{s}.done").touch()
        result = runlogs.stages(run_dir)
        assert result == ["base", "dry", "train", "curve", "finetuned"]

    def test_no_stages(self, tmp_path):
        run_dir = tmp_path / "myrun"
        run_dir.mkdir()
        assert runlogs.stages(run_dir) == []

    def test_missing_dir_returns_empty(self, tmp_path):
        result = runlogs.stages(tmp_path / "nonexistent")
        assert result == []


# ---------------------------------------------------------------------------
# merge_by_x
# ---------------------------------------------------------------------------

class TestMergeByX:
    def test_two_runs_different_x_sets(self):
        by_run = {
            "runA": [{"x": 10, "y": 1.5}, {"x": 20, "y": 1.3}],
            "runB": [{"x": 10, "y": 2.0}, {"x": 30, "y": 1.8}],
        }
        result = runlogs.merge_by_x(by_run)
        # sorted by x
        xs = [r["x"] for r in result]
        assert xs == [10, 20, 30]
        # x=10 has both runs
        row10 = next(r for r in result if r["x"] == 10)
        assert row10["runA"] == 1.5
        assert row10["runB"] == 2.0
        # x=20 only has runA
        row20 = next(r for r in result if r["x"] == 20)
        assert row20["runA"] == 1.3
        assert "runB" not in row20
        # x=30 only has runB
        row30 = next(r for r in result if r["x"] == 30)
        assert row30["runB"] == 1.8
        assert "runA" not in row30

    def test_empty_input(self):
        assert runlogs.merge_by_x({}) == []

    def test_single_run(self):
        by_run = {"solo": [{"x": 5, "y": 0.9}]}
        result = runlogs.merge_by_x(by_run)
        assert result == [{"x": 5, "solo": 0.9}]


# ---------------------------------------------------------------------------
# last_iter
# ---------------------------------------------------------------------------

class TestLastIter:
    def test_returns_max_iter_from_sft_log(self, tmp_path):
        p = tmp_path / "train.log"
        p.write_text(SFT_LOG)
        assert runlogs.last_iter(p) == 20

    def test_returns_zero_for_missing_file(self, tmp_path):
        assert runlogs.last_iter(tmp_path / "no.log") == 0

    def test_returns_zero_for_empty_file(self, tmp_path):
        p = tmp_path / "train.log"
        p.write_text("")
        assert runlogs.last_iter(p) == 0


# ---------------------------------------------------------------------------
# config additions
# ---------------------------------------------------------------------------

class TestConfigAdditions:
    def test_results_dir_under_data_root(self, fake_root):
        assert config.results_dir() == fake_root / "results"

    def test_jac_bin_under_data_root(self, fake_root):
        assert config.jac_bin() == fake_root / ".venv" / "bin" / "jac"

    def test_holdouts_has_function_and_graph_keys(self):
        assert "function" in config.HOLDOUTS
        assert "graph" in config.HOLDOUTS

    def test_holdouts_point_to_jsonl_files(self):
        for v in config.HOLDOUTS.values():
            assert v.endswith(".jsonl")

    def test_excluded_run_dirs_contains_evals(self):
        assert "_evals" in config.EXCLUDED_RUN_DIRS

    def test_excluded_run_dirs_contains_comparison(self):
        assert "comparison" in config.EXCLUDED_RUN_DIRS

    def test_excluded_run_dirs_contains_builder(self):
        assert "_builder" in config.EXCLUDED_RUN_DIRS
