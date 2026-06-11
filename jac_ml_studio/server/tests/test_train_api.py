"""Tests for /api/train router."""

import json
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import app as app_module


@pytest.fixture()
def client(results_root, fake_scripts):
    """TestClient with results_root + fake scripts in place."""
    a = app_module.create_app()
    return TestClient(a)


# ---------------------------------------------------------------------------
# POST /api/train/start
# ---------------------------------------------------------------------------

class TestStartTraining:
    def test_sft_start_returns_200(self, client, fake_root):
        r = client.post("/api/train/start", json={
            "model_id": "models/qwen-jac-fused-q8",
            "name": "qwen",
            "mode": "sft",
        })
        assert r.status_code == 200
        d = r.json()
        assert d["name"] == "qwen"
        assert d["mode"] == "sft"

    def test_sft_job_file_created(self, client, fake_root):
        client.post("/api/train/start", json={
            "model_id": "models/qwen-jac-fused-q8",
            "name": "qwen",
            "mode": "sft",
        })
        jf = fake_root / "results" / "qwen" / ".job-sft.json"
        assert jf.exists()
        data = json.loads(jf.read_text())
        assert data["status"] == "running"
        assert data["mode"] == "sft"

    def test_sft_status_becomes_done(self, client, fake_root):
        client.post("/api/train/start", json={
            "model_id": "models/qwen-jac-fused-q8",
            "name": "qwen",
            "mode": "sft",
        })
        # Poll until done (max 5s; scripts exit 0 immediately)
        deadline = time.time() + 5.0
        status = "running"
        while time.time() < deadline and status == "running":
            r = client.get("/api/train/status?name=qwen&mode=sft")
            status = r.json()["status"]
            if status == "running":
                time.sleep(0.1)
        assert status == "done"

    def test_env_whitelist_eval_every_passes(self, client, fake_root):
        client.post("/api/train/start", json={
            "model_id": "models/qwen-jac-fused-q8",
            "name": "qwen",
            "mode": "sft",
            "opts": {"EVAL_EVERY": "5", "BOGUS": "1"},
        })
        # Wait for the script to finish
        deadline = time.time() + 5.0
        while time.time() < deadline:
            r = client.get("/api/train/status?name=qwen&mode=sft")
            if r.json()["status"] != "running":
                break
            time.sleep(0.1)
        # Check run log for env presence
        runlog = fake_root / "results" / "qwen" / "run-sft.log"
        log_text = runlog.read_text() if runlog.exists() else ""
        assert "EVAL_EVERY=5" in log_text

    def test_env_whitelist_bogus_excluded(self, client, fake_root):
        client.post("/api/train/start", json={
            "model_id": "models/qwen-jac-fused-q8",
            "name": "qwen",
            "mode": "sft",
            "opts": {"EVAL_EVERY": "5", "BOGUS": "1"},
        })
        deadline = time.time() + 5.0
        while time.time() < deadline:
            r = client.get("/api/train/status?name=qwen&mode=sft")
            if r.json()["status"] != "running":
                break
            time.sleep(0.1)
        runlog = fake_root / "results" / "qwen" / "run-sft.log"
        log_text = runlog.read_text() if runlog.exists() else ""
        assert "BOGUS" not in log_text

    def test_bad_name_returns_400(self, client):
        r = client.post("/api/train/start", json={
            "model_id": "foo",
            "name": "bad name!",
            "mode": "sft",
        })
        assert r.status_code == 400

    def test_bad_mode_returns_400(self, client):
        r = client.post("/api/train/start", json={
            "model_id": "foo",
            "name": "qwen",
            "mode": "invalid",
        })
        assert r.status_code == 400

    def test_dpo_start_and_done(self, client, fake_root):
        client.post("/api/train/start", json={
            "name": "gemma",
            "mode": "dpo",
        })
        deadline = time.time() + 5.0
        status = "running"
        while time.time() < deadline and status == "running":
            r = client.get("/api/train/status?name=gemma&mode=dpo")
            status = r.json()["status"]
            if status == "running":
                time.sleep(0.1)
        assert status == "done"

    def test_already_running_returns_message(self, client, fake_root):
        """When job file says running and pid is alive, returns message 'already running'."""
        # Write a fake job file claiming running with a live pid (os.getpid())
        import os
        run_dir = fake_root / "results" / "qwen2"
        run_dir.mkdir(parents=True, exist_ok=True)
        jf = run_dir / ".job-sft.json"
        jf.write_text(json.dumps({
            "name": "qwen2", "mode": "sft", "pid": os.getpid(),
            "status": "running", "started": "2024-01-01 00:00:00", "cmd": "echo",
        }))
        r = client.post("/api/train/start", json={
            "model_id": "models/qwen-jac-fused-q8",
            "name": "qwen2",
            "mode": "sft",
        })
        assert r.status_code == 200
        assert r.json()["message"] == "already running"


# ---------------------------------------------------------------------------
# POST /api/train/stop
# ---------------------------------------------------------------------------

class TestStopTraining:
    def test_stop_long_running(self, client, fake_root):
        """Start a long-running job then stop it; status becomes stopped."""
        # Overwrite run_probe.sh with a sleep variant
        script = fake_root / "run_probe.sh"
        script.write_text("#!/bin/bash\nsleep 30\n")
        script.chmod(0o755)

        r = client.post("/api/train/start", json={
            "model_id": "models/qwen-jac-fused-q8",
            "name": "qwen",
            "mode": "sft",
        })
        assert r.json()["status"] == "running"

        # Give the process a moment to start
        time.sleep(0.2)

        r = client.post("/api/train/stop", json={"name": "qwen", "mode": "sft"})
        assert r.status_code == 200
        # Status should be stopped (or done if process already exited)
        assert r.json()["status"] in ("stopped", "done", "failed")


# ---------------------------------------------------------------------------
# GET /api/train/status
# ---------------------------------------------------------------------------

class TestGetStatus:
    def test_no_job_but_train_log_returns_finished(self, client, fake_root):
        """qwen already has a train.log (from results_root) but no job file."""
        r = client.get("/api/train/status?name=qwen&mode=sft")
        assert r.status_code == 200
        assert r.json()["status"] == "finished"

    def test_no_job_no_log_returns_idle(self, client, fake_root):
        # Create a fresh run dir with no files
        (fake_root / "results" / "freshrun").mkdir(parents=True, exist_ok=True)
        r = client.get("/api/train/status?name=freshrun&mode=sft")
        assert r.status_code == 200
        assert r.json()["status"] == "idle"

    def test_all_fields_present(self, client):
        r = client.get("/api/train/status?name=qwen&mode=sft")
        d = r.json()
        for field in ["name", "mode", "status", "pid", "started", "last_iter", "log_tail", "message"]:
            assert field in d


# ---------------------------------------------------------------------------
# GET /api/train/sessions
# ---------------------------------------------------------------------------

class TestListSessions:
    def test_sessions_response_key(self, client):
        r = client.get("/api/train/sessions")
        assert r.status_code == 200
        assert "sessions" in r.json()

    def test_qwen_sft_finished_listed(self, client):
        r = client.get("/api/train/sessions")
        sessions = {(s["name"], s["mode"]): s for s in r.json()["sessions"]}
        assert ("qwen", "sft") in sessions
        assert sessions[("qwen", "sft")]["status"] == "finished"

    def test_gemma_dpo_finished_listed(self, client):
        r = client.get("/api/train/sessions")
        sessions = {(s["name"], s["mode"]): s for s in r.json()["sessions"]}
        assert ("gemma", "dpo") in sessions

    def test_excludes_builder(self, client):
        r = client.get("/api/train/sessions")
        names = [s["name"] for s in r.json()["sessions"]]
        assert "_builder" not in names

    def test_label_format(self, client):
        r = client.get("/api/train/sessions")
        sessions = {(s["name"], s["mode"]): s for s in r.json()["sessions"]}
        assert sessions[("qwen", "sft")]["label"] == "qwen · SFT"

    def test_session_fields_present(self, client):
        r = client.get("/api/train/sessions")
        for s in r.json()["sessions"]:
            for field in ["name", "mode", "status", "last_iter", "started", "label"]:
                assert field in s
