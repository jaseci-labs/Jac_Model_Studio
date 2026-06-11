"""Tests for /api/builders endpoints."""
import os
import time
import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def fake_jac(dataset_root):
    """Write a fake jac executable into dataset_root/.venv/bin/jac."""
    venv_bin = dataset_root / ".venv" / "bin"
    venv_bin.mkdir(parents=True, exist_ok=True)
    jac_path = venv_bin / "jac"
    jac_path.write_text("#!/bin/bash\necho \"ran $@\"\nexit 0\n")
    jac_path.chmod(0o755)
    return dataset_root


@pytest.fixture()
def fake_jac_slow(dataset_root):
    """A jac that sleeps for 5 seconds (simulates long-running job)."""
    venv_bin = dataset_root / ".venv" / "bin"
    venv_bin.mkdir(parents=True, exist_ok=True)
    jac_path = venv_bin / "jac"
    jac_path.write_text("#!/bin/bash\nsleep 5\necho \"ran $@\"\nexit 0\n")
    jac_path.chmod(0o755)
    return dataset_root


@pytest.fixture()
def fake_jac_fail(dataset_root):
    """A jac that exits with code 2 (simulates failing job)."""
    venv_bin = dataset_root / ".venv" / "bin"
    venv_bin.mkdir(parents=True, exist_ok=True)
    jac_path = venv_bin / "jac"
    jac_path.write_text("#!/bin/bash\necho \"error output\"\nexit 2\n")
    jac_path.chmod(0o755)
    return dataset_root


def make_client(root):
    from app import create_app
    return TestClient(create_app())


EXPECTED_STAGES = [
    "seed_conversion", "idiomatic_batch", "idiomatic_batch2", "idiomatic_batch3",
    "scale_conversion", "dpo_conversion", "build_manifest", "build_splits",
    "build_dpo_splits", "holdout", "graph_holdout", "dataset_stats", "verify_dataset",
]


# ---------------------------------------------------------------------------
# GET /api/builders
# ---------------------------------------------------------------------------

def test_all_builders_listed(fake_jac):
    client = make_client(fake_jac)
    r = client.get("/api/builders")
    assert r.status_code == 200
    data = r.json()
    assert "builders" in data
    stages = [b["stage"] for b in data["builders"]]
    assert stages == EXPECTED_STAGES


def test_all_builders_idle_initially(fake_jac):
    client = make_client(fake_jac)
    builders = client.get("/api/builders").json()["builders"]
    assert len(builders) == 13
    for b in builders:
        assert b["status"] == "idle"


# ---------------------------------------------------------------------------
# POST /api/builders/run
# ---------------------------------------------------------------------------

def test_run_dataset_stats(fake_jac):
    client = make_client(fake_jac)
    r = client.post("/api/builders/run", json={"stage": "dataset_stats"})
    assert r.status_code == 200
    data = r.json()
    assert data["stage"] == "dataset_stats"
    assert data["status"] in ("running", "done")


def test_run_then_poll_done(fake_jac):
    """Spawn a fast builder, poll until done or 3 s timeout."""
    client = make_client(fake_jac)
    client.post("/api/builders/run", json={"stage": "dataset_stats"})
    # Give the fast script time to finish
    deadline = time.monotonic() + 3.0
    status = "running"
    while time.monotonic() < deadline and status == "running":
        time.sleep(0.1)
        status = client.get("/api/builders/dataset_stats").json()["status"]
    assert status == "done"


def test_run_log_contains_ran(fake_jac):
    """The log tail should eventually contain 'ran' from the fake jac script."""
    client = make_client(fake_jac)
    client.post("/api/builders/run", json={"stage": "dataset_stats"})
    time.sleep(0.5)
    data = client.get("/api/builders/dataset_stats").json()
    assert "ran" in data.get("log_tail", "")


def test_run_unknown_stage(fake_jac):
    client = make_client(fake_jac)
    r = client.post("/api/builders/run", json={"stage": "not_a_stage"})
    assert r.status_code == 400


# ---------------------------------------------------------------------------
# GET /api/builders/{stage}
# ---------------------------------------------------------------------------

def test_get_stage_idle(fake_jac):
    client = make_client(fake_jac)
    r = client.get("/api/builders/build_splits")
    assert r.status_code == 200
    assert r.json()["status"] == "idle"


def test_get_unknown_stage(fake_jac):
    client = make_client(fake_jac)
    r = client.get("/api/builders/nonexistent")
    assert r.status_code == 400


# ---------------------------------------------------------------------------
# Already running guard
# ---------------------------------------------------------------------------

def test_already_running(fake_jac_slow):
    """Second run call while the job is still running returns 'already running'."""
    client = make_client(fake_jac_slow)
    client.post("/api/builders/run", json={"stage": "holdout"})
    r2 = client.post("/api/builders/run", json={"stage": "holdout"})
    assert r2.status_code == 200
    assert r2.json()["message"] == "already running"


# ---------------------------------------------------------------------------
# Failing jac binary
# ---------------------------------------------------------------------------

def test_failing_jac(fake_jac_fail):
    """A jac that exits 2 should eventually produce status 'failed'."""
    client = make_client(fake_jac_fail)
    client.post("/api/builders/run", json={"stage": "verify_dataset"})
    deadline = time.monotonic() + 3.0
    status = "running"
    while time.monotonic() < deadline and status == "running":
        time.sleep(0.1)
        status = client.get("/api/builders/verify_dataset").json()["status"]
    assert status == "failed"
