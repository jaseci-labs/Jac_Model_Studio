"""Tests for /api/dataset endpoints."""
import json
import pytest
from fastapi.testclient import TestClient


def make_client(dataset_root):
    from app import create_app
    return TestClient(create_app())


# ---------------------------------------------------------------------------
# /api/dataset/stats
# ---------------------------------------------------------------------------

def test_stats_sft_total(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/stats")
    assert r.status_code == 200
    data = r.json()
    # sft.jsonl has 2 rows, sft_auto.jsonl has 1 row
    assert data["sft_total"] == 3
    assert len(data["sft_files"]) == 2
    assert data["dpo_pairs"] == 1


def test_stats_splits(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/stats")
    splits = r.json()["splits"]
    assert splits["mlx_train"] == 2
    assert splits["mlx_valid"] == 1
    assert splits["dpo_train"] == 3
    assert splits["dpo_valid"] == 1
    assert splits["holdout"] == 1
    assert splits["graph_holdout"] == 1


def test_stats_by_difficulty(dataset_root):
    client = make_client(dataset_root)
    data = client.get("/api/dataset/stats").json()
    sft_file = data["sft_files"][0]  # sft.jsonl
    assert sft_file["path"] == "dataset/conversion/sft.jsonl"
    assert sft_file["total"] == 2
    assert sft_file["by_difficulty"]["easy"] == 1
    assert sft_file["by_difficulty"]["medium"] == 1


# ---------------------------------------------------------------------------
# /api/dataset/files
# ---------------------------------------------------------------------------

def test_files_lists_nine(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/files")
    assert r.status_code == 200
    files = r.json()["files"]
    assert len(files) == 9


def test_files_counts(dataset_root):
    client = make_client(dataset_root)
    files = client.get("/api/dataset/files").json()["files"]
    by_path = {f["path"]: f for f in files}
    assert by_path["dataset/conversion/sft.jsonl"]["count"] == 2
    assert by_path["dataset/conversion/sft_auto.jsonl"]["count"] == 1
    assert by_path["dataset/conversion/dpo.jsonl"]["count"] == 1


def test_files_has_labels(dataset_root):
    client = make_client(dataset_root)
    files = client.get("/api/dataset/files").json()["files"]
    labels = [f["label"] for f in files]
    assert "SFT idiomatic core" in labels
    assert "Holdout (function)" in labels


# ---------------------------------------------------------------------------
# /api/dataset/rows  — SFT
# ---------------------------------------------------------------------------

def test_rows_sft_kind(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/rows", params={"path": "dataset/conversion/sft.jsonl"})
    assert r.status_code == 200
    data = r.json()
    assert data["total"] == 2
    row = data["rows"][0]
    assert row["kind"] == "sft"


def test_rows_sft_python_jac_extracted(dataset_root):
    client = make_client(dataset_root)
    rows = client.get("/api/dataset/rows", params={"path": "dataset/conversion/sft.jsonl"}).json()["rows"]
    row = rows[0]
    assert "def add" in row["python"]
    assert "def add" in row["jac"]
    # No HTML spans — raw code strings only
    assert "<span" not in row["python"]
    assert "<span" not in row["jac"]


def test_rows_sft_no_html_anywhere(dataset_root):
    client = make_client(dataset_root)
    rows = client.get("/api/dataset/rows", params={"path": "dataset/conversion/sft.jsonl"}).json()["rows"]
    payload_str = json.dumps(rows)
    assert "<span" not in payload_str


def test_rows_sft_meta(dataset_root):
    client = make_client(dataset_root)
    rows = client.get("/api/dataset/rows", params={"path": "dataset/conversion/sft.jsonl"}).json()["rows"]
    assert rows[0]["difficulty"] == "easy"
    assert rows[1]["difficulty"] == "medium"


# ---------------------------------------------------------------------------
# /api/dataset/rows  — DPO
# ---------------------------------------------------------------------------

def test_rows_dpo(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/rows", params={"path": "dataset/conversion/dpo.jsonl"})
    assert r.status_code == 200
    data = r.json()
    row = data["rows"][0]
    assert row["kind"] == "dpo"
    assert "factorial" in row["chosen"]
    assert "factorial" in row["rejected"]
    assert "<span" not in row["chosen"]
    assert "<span" not in row["rejected"]


# ---------------------------------------------------------------------------
# /api/dataset/rows  — Holdout
# ---------------------------------------------------------------------------

def test_rows_holdout(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/rows", params={"path": "dataset/eval_holdout/conversion.jsonl"})
    assert r.status_code == 200
    row = r.json()["rows"][0]
    assert row["kind"] == "holdout"
    assert "add" in row["python"]
    assert row["name"] == "add"


# ---------------------------------------------------------------------------
# /api/dataset/rows  — paging
# ---------------------------------------------------------------------------

def test_rows_paging_offset(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/rows",
                   params={"path": "dataset/conversion/sft.jsonl", "offset": 1, "limit": 10})
    data = r.json()
    assert data["total"] == 2
    assert len(data["rows"]) == 1
    assert data["rows"][0]["idx"] == 1


def test_rows_limit_cap(dataset_root):
    """Limit is capped at 40."""
    client = make_client(dataset_root)
    r = client.get("/api/dataset/rows",
                   params={"path": "dataset/conversion/sft.jsonl", "limit": 200})
    assert r.status_code == 200


# ---------------------------------------------------------------------------
# /api/dataset/rows  — security
# ---------------------------------------------------------------------------

def test_rows_path_traversal_rejected(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/rows", params={"path": "../../etc/passwd"})
    assert r.status_code == 400


def test_rows_non_allowlisted_rejected(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/rows", params={"path": "dataset/conversion/secret.jsonl"})
    assert r.status_code == 400


# ---------------------------------------------------------------------------
# /api/dataset/examples (POST)
# ---------------------------------------------------------------------------

def test_add_examples_sft(dataset_root):
    client = make_client(dataset_root)
    line = json.dumps({"messages": [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"}]})
    r = client.post("/api/dataset/examples", json={"target": "sft", "text": line + "\n" + line})
    assert r.status_code == 200
    data = r.json()
    assert data["added"] == 2
    assert data["errors"] == []
    # total should be original 2 + 2 new = 4
    assert data["total"] == 4


def test_add_examples_stats_reflect(dataset_root):
    """After appending, /stats shows updated sft_total."""
    client = make_client(dataset_root)
    line = json.dumps({"messages": [{"role": "user", "content": "q"}, {"role": "assistant", "content": "a"}]})
    client.post("/api/dataset/examples", json={"target": "sft", "text": line})
    stats = client.get("/api/dataset/stats").json()
    assert stats["sft_total"] == 4  # 2 original + 1 sft_auto + 1 new


def test_add_examples_invalid_json_line(dataset_root):
    client = make_client(dataset_root)
    text = "not-json\n" + json.dumps({"messages": [{"role": "user", "content": "q"}, {"role": "assistant", "content": "a"}]})
    r = client.post("/api/dataset/examples", json={"target": "sft", "text": text})
    data = r.json()
    assert data["added"] == 1
    assert len(data["errors"]) == 1
    assert "not valid JSON" in data["errors"][0]


def test_add_examples_dpo_missing_rejected(dataset_root):
    client = make_client(dataset_root)
    line = json.dumps({"prompt": "p", "chosen": "c"})  # missing rejected
    r = client.post("/api/dataset/examples", json={"target": "dpo", "text": line})
    data = r.json()
    assert data["added"] == 0
    assert len(data["errors"]) == 1
    assert "DPO" in data["errors"][0]


def test_add_examples_bad_target(dataset_root):
    client = make_client(dataset_root)
    r = client.post("/api/dataset/examples", json={"target": "evil", "text": "{}"})
    assert r.status_code == 400


# ---------------------------------------------------------------------------
# /api/dataset/rows  — validation
# ---------------------------------------------------------------------------

def test_rows_negative_offset_returns_422(dataset_root):
    client = make_client(dataset_root)
    r = client.get("/api/dataset/rows", params={"path": "dataset/conversion/sft.jsonl", "offset": -1})
    assert r.status_code == 422
