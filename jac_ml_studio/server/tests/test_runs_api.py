"""Tests for /api/runs router."""

import pytest
from fastapi.testclient import TestClient

import app as app_module


@pytest.fixture()
def client(results_root):
    """TestClient with results_root in place."""
    a = app_module.create_app()
    return TestClient(a)


# ---------------------------------------------------------------------------
# GET /api/runs — list
# ---------------------------------------------------------------------------

class TestListRuns:
    def test_includes_qwen_with_sft(self, client):
        r = client.get("/api/runs")
        assert r.status_code == 200
        runs = {x["name"]: x for x in r.json()["runs"]}
        assert "qwen" in runs
        assert runs["qwen"]["has_sft"] is True

    def test_qwen_stages_contains_train(self, client):
        r = client.get("/api/runs")
        runs = {x["name"]: x for x in r.json()["runs"]}
        assert "train" in runs["qwen"]["stages"]

    def test_gemma_has_dpo(self, client):
        r = client.get("/api/runs")
        runs = {x["name"]: x for x in r.json()["runs"]}
        assert "gemma" in runs
        assert runs["gemma"]["has_dpo"] is True

    def test_excludes_comparison(self, client):
        r = client.get("/api/runs")
        names = [x["name"] for x in r.json()["runs"]]
        assert "comparison" not in names

    def test_excludes_builder(self, client):
        r = client.get("/api/runs")
        names = [x["name"] for x in r.json()["runs"]]
        assert "_builder" not in names

    def test_excludes_stray_log(self, client):
        r = client.get("/api/runs")
        names = [x["name"] for x in r.json()["runs"]]
        assert "stray.log" not in names

    def test_running_field_present(self, client):
        r = client.get("/api/runs")
        for run in r.json()["runs"]:
            assert "running" in run


# ---------------------------------------------------------------------------
# GET /api/runs/{name}  — single run metrics
# ---------------------------------------------------------------------------

class TestRunMetrics:
    def test_qwen_sft_shape(self, client):
        r = client.get("/api/runs/qwen?mode=sft")
        assert r.status_code == 200
        d = r.json()
        assert d["name"] == "qwen"
        assert d["mode"] == "sft"
        assert d["found"] is True

    def test_qwen_sft_train_points(self, client):
        r = client.get("/api/runs/qwen?mode=sft")
        d = r.json()
        assert len(d["train"]) == 2

    def test_qwen_sft_val_points(self, client):
        r = client.get("/api/runs/qwen?mode=sft")
        d = r.json()
        assert len(d["val"]) == 1

    def test_qwen_sft_curve_points(self, client):
        r = client.get("/api/runs/qwen?mode=sft")
        d = r.json()
        assert len(d["curve"]) == 2

    def test_qwen_sft_idiom_has_idiom_true(self, client):
        r = client.get("/api/runs/qwen?mode=sft")
        d = r.json()
        assert d["has_idiom"] is True

    def test_qwen_sft_idiom_avg_sim(self, client):
        r = client.get("/api/runs/qwen?mode=sft")
        d = r.json()
        assert abs(d["idiom_avg_sim"] - 0.85) < 1e-6

    def test_qwen_sft_log_tail_nonempty(self, client):
        r = client.get("/api/runs/qwen?mode=sft")
        d = r.json()
        assert d["log_tail"] != ""

    def test_gemma_dpo_metrics(self, client):
        r = client.get("/api/runs/gemma?mode=dpo")
        assert r.status_code == 200
        d = r.json()
        assert d["found"] is True
        assert len(d["train"]) == 1

    def test_unknown_name_returns_found_false(self, client):
        r = client.get("/api/runs/doesnotexist?mode=sft")
        assert r.status_code == 200
        assert r.json()["found"] is False

    def test_dotdot_name_rejected(self, client):
        # ..%2F decodes to ../ which the HTTP layer resolves before hitting the
        # endpoint — either 400 (caught by our safe() check) or 404 (routing
        # normalises the path away). Both indicate the request was blocked.
        r = client.get("/api/runs/..%2Fetc")
        assert r.status_code in (400, 404)

    def test_bad_mode_returns_400(self, client):
        r = client.get("/api/runs/qwen?mode=bad")
        assert r.status_code == 400

    def test_all_required_fields_present(self, client):
        r = client.get("/api/runs/qwen?mode=sft")
        d = r.json()
        for field in ["name", "mode", "found", "running", "last_iter",
                      "train", "val", "lr", "tps", "curve",
                      "idiom_sim", "has_idiom", "idiom_label", "idiom_avg_sim",
                      "idiom_idiomatic", "idiom_python", "idiom_runs", "idiom_total",
                      "log_tail"]:
            assert field in d, f"missing field: {field}"


# ---------------------------------------------------------------------------
# GET /api/runs/compare
# ---------------------------------------------------------------------------

class TestCompareRuns:
    def test_sft_names_contains_qwen(self, client):
        r = client.get("/api/runs/compare?mode=sft")
        assert r.status_code == 200
        assert "qwen" in r.json()["names"]

    def test_sft_headline_has_final_pass(self, client):
        r = client.get("/api/runs/compare?mode=sft")
        headline = {h["name"]: h for h in r.json()["headline"]}
        assert "qwen" in headline
        assert headline["qwen"]["final_pass"] == 61.0

    def test_sft_response_keys(self, client):
        r = client.get("/api/runs/compare?mode=sft")
        d = r.json()
        for key in ["names", "train", "val", "curve", "headline"]:
            assert key in d

    def test_compare_route_does_not_conflict_with_name_route(self, client):
        # /compare must be registered before /{name} so it's not captured
        r = client.get("/api/runs/compare?mode=sft")
        assert r.status_code == 200
        assert "names" in r.json()
