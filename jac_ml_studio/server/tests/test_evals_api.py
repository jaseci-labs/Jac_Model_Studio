"""Tests for /api/evals endpoints."""
import os
import time
import pytest
from fastapi.testclient import TestClient


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture()
def fake_jac(dataset_root):
    """Write a fake jac that writes canned metrics rows and exits 0."""
    venv_bin = dataset_root / ".venv" / "bin"
    venv_bin.mkdir(parents=True, exist_ok=True)
    jac_path = venv_bin / "jac"
    jac_path.write_text(
        "#!/bin/bash\n"
        "# fake jac: writes a canned metrics row to whichever out var is set\n"
        "if [ -n \"$JAC_EVAL_METRICS_OUT\" ]; then\n"
        "  echo '{\"step\":0,\"total\":13,\"runs\":10,\"test_pass\":8,"
        "\"runs_pct\":76,\"test_pass_pct\":61,\"gen_tokens\":4000,"
        "\"eval_tps\":40,\"tokens_to_correct\":500}'"
        " >> \"$JAC_EVAL_METRICS_OUT\"\n"
        "fi\n"
        "if [ -n \"$JAC_IDIOM_OUT\" ]; then\n"
        "  echo '{\"mode\":\"mlx\",\"total\":13,\"runs\":10,\"idiomatic\":8,"
        "\"python_shaped\":2,\"avg_sim\":0.34,\"avg_feat\":6.1}'"
        " >> \"$JAC_IDIOM_OUT\"\n"
        "fi\n"
        "echo \"eval done\"\n"
        "exit 0\n"
    )
    jac_path.chmod(0o755)
    return dataset_root


@pytest.fixture()
def fake_jac_fail(dataset_root):
    """A jac that exits 2 — simulates a failing eval."""
    venv_bin = dataset_root / ".venv" / "bin"
    venv_bin.mkdir(parents=True, exist_ok=True)
    jac_path = venv_bin / "jac"
    jac_path.write_text(
        "#!/bin/bash\n"
        "echo 'eval error'\n"
        "exit 2\n"
    )
    jac_path.chmod(0o755)
    return dataset_root


@pytest.fixture()
def fake_jac_slow(dataset_root):
    """A jac that sleeps — simulates a long-running eval for stop tests."""
    venv_bin = dataset_root / ".venv" / "bin"
    venv_bin.mkdir(parents=True, exist_ok=True)
    jac_path = venv_bin / "jac"
    jac_path.write_text(
        "#!/bin/bash\n"
        "sleep 30\n"
        "exit 0\n"
    )
    jac_path.chmod(0o755)
    return dataset_root


def make_client(root):
    from app import create_app
    return TestClient(create_app())


def poll_until(client, eval_id, timeout=5.0, interval=0.1):
    """Poll GET /{eval_id} until status != running or timeout."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        r = client.get(f"/api/evals/{eval_id}")
        assert r.status_code == 200
        data = r.json()
        if data["status"] != "running":
            return data
        time.sleep(interval)
    return client.get(f"/api/evals/{eval_id}").json()


# ---------------------------------------------------------------------------
# POST /api/evals  — probe
# ---------------------------------------------------------------------------

def test_post_probe_model_id(fake_jac):
    client = make_client(fake_jac)
    r = client.post("/api/evals", json={
        "kind": "probe",
        "model_id": "qwen-dpo",
        "holdout": "function",
    })
    assert r.status_code == 201
    data = r.json()
    assert data["status"] == "running"
    assert data["kind"] == "probe"
    eval_id = data["id"]

    final = poll_until(client, eval_id)
    assert final["status"] == "done"
    assert final["scores"]["test_pass_pct"] == 61

    # log_tail contains "eval done"
    detail = client.get(f"/api/evals/{eval_id}").json()
    assert "eval done" in detail["log_tail"]


# ---------------------------------------------------------------------------
# POST /api/evals  — idiom
# ---------------------------------------------------------------------------

def test_post_idiom_model_id(fake_jac):
    client = make_client(fake_jac)
    r = client.post("/api/evals", json={
        "kind": "idiom",
        "model_id": "qwen-dpo",
        "holdout": "function",
    })
    assert r.status_code == 201
    eval_id = r.json()["id"]

    final = poll_until(client, eval_id)
    assert final["status"] == "done"
    assert abs(final["scores"]["avg_sim"] - 0.34) < 1e-6


# ---------------------------------------------------------------------------
# Validation errors
# ---------------------------------------------------------------------------

def test_unknown_model_id(fake_jac):
    client = make_client(fake_jac)
    r = client.post("/api/evals", json={
        "kind": "probe",
        "model_id": "no-such-model",
        "holdout": "function",
    })
    assert r.status_code == 400


def test_model_id_not_on_disk(fake_jac):
    """qwen-sft dir does not exist in fake_root (only qwen-dpo and gemma-dpo)."""
    client = make_client(fake_jac)
    r = client.post("/api/evals", json={
        "kind": "probe",
        "model_id": "qwen-sft",
        "holdout": "function",
    })
    assert r.status_code == 400


def test_model_path_escape(fake_jac):
    client = make_client(fake_jac)
    r = client.post("/api/evals", json={
        "kind": "probe",
        "model_path": "../../etc",
        "holdout": "function",
    })
    assert r.status_code == 400


def test_bad_kind(fake_jac):
    client = make_client(fake_jac)
    r = client.post("/api/evals", json={
        "kind": "unknown_kind",
        "model_id": "qwen-dpo",
        "holdout": "function",
    })
    assert r.status_code == 400


def test_bad_holdout(fake_jac):
    client = make_client(fake_jac)
    r = client.post("/api/evals", json={
        "kind": "probe",
        "model_id": "qwen-dpo",
        "holdout": "not_a_holdout",
    })
    assert r.status_code == 400


# ---------------------------------------------------------------------------
# Failing jac
# ---------------------------------------------------------------------------

def test_failing_jac(fake_jac_fail):
    client = make_client(fake_jac_fail)
    r = client.post("/api/evals", json={
        "kind": "probe",
        "model_id": "qwen-dpo",
        "holdout": "function",
    })
    assert r.status_code == 201
    eval_id = r.json()["id"]

    final = poll_until(client, eval_id)
    assert final["status"] == "failed"


# ---------------------------------------------------------------------------
# Stop
# ---------------------------------------------------------------------------

def test_stop_running_eval(fake_jac_slow):
    client = make_client(fake_jac_slow)
    r = client.post("/api/evals", json={
        "kind": "probe",
        "model_id": "qwen-dpo",
        "holdout": "function",
    })
    assert r.status_code == 201
    eval_id = r.json()["id"]

    time.sleep(0.3)  # let it get into the sleep
    stop_r = client.post(f"/api/evals/{eval_id}/stop")
    assert stop_r.status_code == 200
    assert stop_r.json()["status"] == "stopped"


# ---------------------------------------------------------------------------
# DELETE
# ---------------------------------------------------------------------------

def test_delete_removes_row_and_dir(fake_jac):
    client = make_client(fake_jac)
    r = client.post("/api/evals", json={
        "kind": "probe",
        "model_id": "qwen-dpo",
        "holdout": "function",
    })
    assert r.status_code == 201
    eval_id = r.json()["id"]

    poll_until(client, eval_id)  # wait until done

    del_r = client.delete(f"/api/evals/{eval_id}")
    assert del_r.status_code == 200
    assert del_r.json() == {"ok": True}

    # Row gone → 404
    assert client.get(f"/api/evals/{eval_id}").status_code == 404

    # Artifact directory gone
    import config
    ed = config.results_dir() / "_evals" / str(eval_id)
    assert not ed.exists()


# ---------------------------------------------------------------------------
# GET list — newest first
# ---------------------------------------------------------------------------

def test_list_newest_first(fake_jac):
    client = make_client(fake_jac)
    ids = []
    for _ in range(3):
        r = client.post("/api/evals", json={
            "kind": "probe",
            "model_id": "qwen-dpo",
            "holdout": "function",
        })
        assert r.status_code == 201
        ids.append(r.json()["id"])

    r = client.get("/api/evals")
    assert r.status_code == 200
    returned_ids = [e["id"] for e in r.json()["evals"]]
    assert returned_ids == list(reversed(ids))


# ---------------------------------------------------------------------------
# 404 for unknown eval
# ---------------------------------------------------------------------------

def test_get_unknown(fake_jac):
    client = make_client(fake_jac)
    assert client.get("/api/evals/99999").status_code == 404


def test_stop_unknown(fake_jac):
    client = make_client(fake_jac)
    assert client.post("/api/evals/99999/stop").status_code == 404


def test_delete_unknown(fake_jac):
    client = make_client(fake_jac)
    assert client.delete("/api/evals/99999").status_code == 404


# ---------------------------------------------------------------------------
# History survives create_app() recreation (same JAC_STUDIO_DB)
# ---------------------------------------------------------------------------

def test_history_survives_restart(fake_jac):
    client1 = make_client(fake_jac)
    r = client1.post("/api/evals", json={
        "kind": "probe",
        "model_id": "qwen-dpo",
        "holdout": "function",
    })
    assert r.status_code == 201
    eval_id = r.json()["id"]
    poll_until(client1, eval_id)

    # Recreate the app — same DB env var is set by tmp_db_global autouse fixture
    client2 = make_client(fake_jac)
    r2 = client2.get(f"/api/evals/{eval_id}")
    assert r2.status_code == 200
    assert r2.json()["status"] == "done"
