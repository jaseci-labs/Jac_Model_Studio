"""Tests for /api/system router."""

import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import app as app_module
import routers.system


@pytest.fixture()
def client_with_update(tmp_path, monkeypatch):
    """TestClient with a fake update.sh that writes a marker file."""
    marker = tmp_path / "update_ran"
    script = tmp_path / "update.sh"
    script.write_text(f"#!/bin/bash\ntouch {marker}\nexit 0\n")
    script.chmod(0o755)
    monkeypatch.setattr(routers.system, "APP_DIR", tmp_path)
    a = app_module.create_app()
    return TestClient(a), marker


@pytest.fixture()
def client_no_script(tmp_path, monkeypatch):
    """TestClient with no update.sh present."""
    monkeypatch.setattr(routers.system, "APP_DIR", tmp_path)
    a = app_module.create_app()
    return TestClient(a)


class TestSystemUpdate:
    def test_update_returns_200_ok(self, client_with_update):
        client, _ = client_with_update
        r = client.post("/api/system/update")
        assert r.status_code == 200
        assert r.json()["ok"] is True

    def test_update_marker_appears(self, client_with_update):
        client, marker = client_with_update
        client.post("/api/system/update")
        deadline = time.time() + 2.0
        while time.time() < deadline:
            if marker.exists():
                break
            time.sleep(0.1)
        assert marker.exists(), "update.sh did not run within 2s"

    def test_missing_script_returns_500(self, client_no_script):
        r = client_no_script.post("/api/system/update")
        assert r.status_code == 500
