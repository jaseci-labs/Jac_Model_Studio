"""Tests for procs.py — detached-process job lifecycle."""

import json
import os
import time
from pathlib import Path

import pytest

import procs


# ---------------------------------------------------------------------------
# safe()
# ---------------------------------------------------------------------------

class TestSafe:
    def test_ok_simple_name(self):
        assert procs.safe("my_model") is True

    def test_ok_dots_and_dashes(self):
        assert procs.safe("model-v1.2") is True

    def test_ok_alphanumeric(self):
        assert procs.safe("abc123") is True

    def test_rejects_empty(self):
        assert procs.safe("") is False

    def test_rejects_semicolon(self):
        assert procs.safe("name;rm") is False

    def test_rejects_space(self):
        assert procs.safe("my model") is False

    def test_rejects_slash_by_default(self):
        assert procs.safe("models/foo") is False

    def test_allow_slash_accepts_path(self):
        assert procs.safe("models/x", allow_slash=True) is True

    def test_allow_slash_rejects_dotdot_segment(self):
        assert procs.safe("a/../b", allow_slash=True) is False

    def test_allow_slash_rejects_bare_dotdot(self):
        assert procs.safe("..", allow_slash=True) is False

    def test_allow_slash_rejects_dotdot_prefix(self):
        assert procs.safe("../secret", allow_slash=True) is False


# ---------------------------------------------------------------------------
# alive() / reap()
# ---------------------------------------------------------------------------

class TestAlive:
    def test_self_is_alive(self):
        assert procs.alive(os.getpid()) is True

    def test_pid_zero_is_false(self):
        assert procs.alive(0) is False

    def test_negative_pid_is_false(self):
        assert procs.alive(-1) is False

    def test_dead_pid_is_false(self):
        # Use a very large unlikely pid
        assert procs.alive(99999999) is False

    def test_reap_does_not_raise(self):
        # reap on a non-child should silently swallow
        procs.reap(os.getpid())
        procs.reap(99999999)


# ---------------------------------------------------------------------------
# read_job / write_job roundtrip
# ---------------------------------------------------------------------------

class TestReadWriteJob:
    def test_roundtrip(self, tmp_path):
        jf = tmp_path / "test.json"
        data = {"name": "x", "mode": "sft", "pid": 42, "status": "running",
                "started": "2024-01-01 00:00:00", "cmd": "echo hi"}
        procs.write_job(jf, data)
        result = procs.read_job(jf)
        assert result == data

    def test_missing_file_returns_none(self, tmp_path):
        assert procs.read_job(tmp_path / "nonexistent.json") is None

    def test_corrupt_json_returns_none(self, tmp_path):
        jf = tmp_path / "bad.json"
        jf.write_text("not json")
        assert procs.read_job(jf) is None

    def test_creates_parent_dirs(self, tmp_path):
        jf = tmp_path / "nested" / "dir" / "job.json"
        procs.write_job(jf, {"status": "running"})
        assert jf.exists()


# ---------------------------------------------------------------------------
# with_exit_marker
# ---------------------------------------------------------------------------

class TestWithExitMarker:
    def test_appends_marker(self, tmp_path):
        log = tmp_path / "run.log"
        result = procs.with_exit_marker("echo hi", log)
        assert "__EXIT__ $?" in result
        assert "echo hi" in result

    def test_log_path_quoted(self, tmp_path):
        log = tmp_path / "path with spaces" / "run.log"
        result = procs.with_exit_marker("echo hi", log)
        # shlex.quote wraps in single quotes when spaces present
        assert "'" in result or str(log) in result


# ---------------------------------------------------------------------------
# spawn_detached + live_status — happy path (exit 0 -> "done")
# ---------------------------------------------------------------------------

class TestSpawnAndLiveStatus:
    def test_spawn_returns_positive_pid(self, tmp_path):
        log = tmp_path / "run.log"
        cmd = procs.with_exit_marker("echo hi", log)
        pid = procs.spawn_detached(cmd, log, {}, tmp_path)
        assert isinstance(pid, int)
        assert pid > 0

    def test_exit_marker_written(self, tmp_path):
        log = tmp_path / "run.log"
        cmd = procs.with_exit_marker("echo hi", log)
        procs.spawn_detached(cmd, log, {}, tmp_path)
        # Poll up to 5s
        deadline = time.time() + 5
        found = False
        while time.time() < deadline:
            if log.exists() and "__EXIT__ 0" in log.read_text():
                found = True
                break
            time.sleep(0.05)
        assert found, f"Exit marker not found; log: {log.read_text() if log.exists() else '<missing>'}"

    def test_live_status_flips_to_done(self, tmp_path):
        log = tmp_path / "run.log"
        cmd = procs.with_exit_marker("echo hi", log)
        pid = procs.spawn_detached(cmd, log, {}, tmp_path)

        job_file = tmp_path / ".job.json"
        procs.write_job(job_file, {
            "name": "test", "mode": "sft", "pid": pid, "status": "running",
            "started": "2024-01-01", "cmd": cmd,
        })

        # Poll live_status until it settles or timeout
        deadline = time.time() + 5
        result = None
        while time.time() < deadline:
            result = procs.live_status(job_file, log)
            if result and result.get("status") != "running":
                break
            time.sleep(0.1)

        assert result is not None
        assert result["status"] == "done"

    def test_failing_cmd_flips_to_failed(self, tmp_path):
        log = tmp_path / "run.log"
        # Use 'bash -c exit\ 3' so the subshell exits 3 while the wrapper
        # shell still executes the exit-marker redirect afterwards.
        cmd = procs.with_exit_marker("bash -c 'exit 3'", log)
        pid = procs.spawn_detached(cmd, log, {}, tmp_path)

        job_file = tmp_path / ".job.json"
        procs.write_job(job_file, {
            "name": "test", "mode": "sft", "pid": pid, "status": "running",
            "started": "2024-01-01", "cmd": cmd,
        })

        deadline = time.time() + 5
        result = None
        while time.time() < deadline:
            result = procs.live_status(job_file, log)
            if result and result.get("status") != "running":
                break
            time.sleep(0.1)

        assert result is not None
        assert result["status"] == "failed"


# ---------------------------------------------------------------------------
# live_status edge cases
# ---------------------------------------------------------------------------

class TestLiveStatusEdgeCases:
    def test_missing_job_file_returns_none(self, tmp_path):
        result = procs.live_status(tmp_path / "noexist.json", tmp_path / "nolog")
        assert result is None

    def test_no_marker_dead_pid_returns_stopped(self, tmp_path):
        log = tmp_path / "run.log"
        log.write_text("some output with no marker\n")
        job_file = tmp_path / ".job.json"
        # Use a pid that is definitely dead
        procs.write_job(job_file, {
            "name": "test", "mode": "sft", "pid": 99999999, "status": "running",
            "started": "2024-01-01", "cmd": "sleep 999",
        })
        result = procs.live_status(job_file, log)
        assert result is not None
        assert result["status"] == "stopped"

    def test_non_running_status_returned_as_is(self, tmp_path):
        log = tmp_path / "run.log"
        job_file = tmp_path / ".job.json"
        procs.write_job(job_file, {
            "name": "test", "mode": "sft", "pid": 0, "status": "done",
            "started": "2024-01-01", "cmd": "echo",
        })
        result = procs.live_status(job_file, log)
        assert result is not None
        assert result["status"] == "done"


# ---------------------------------------------------------------------------
# stop()
# ---------------------------------------------------------------------------

class TestStop:
    def test_stop_kills_process(self, tmp_path):
        log = tmp_path / "run.log"
        # spawn a long-running process
        cmd = procs.with_exit_marker("sleep 30", log)
        pid = procs.spawn_detached(cmd, log, {}, tmp_path)

        job_file = tmp_path / ".job.json"
        procs.write_job(job_file, {
            "name": "test", "mode": "sft", "pid": pid, "status": "running",
            "started": "2024-01-01", "cmd": "sleep 30",
        })

        result = procs.stop(job_file)
        assert result is not None
        assert result["status"] == "stopped"

        # Process should be dead within 2s
        deadline = time.time() + 2
        while time.time() < deadline:
            if not procs.alive(pid):
                break
            time.sleep(0.1)
        assert not procs.alive(pid), "Process still alive after stop()"

    def test_stop_missing_job_returns_none(self, tmp_path):
        result = procs.stop(tmp_path / "noexist.json")
        assert result is None


# ---------------------------------------------------------------------------
# env passthrough
# ---------------------------------------------------------------------------

class TestEnvPassthrough:
    def test_env_var_appears_in_log(self, tmp_path):
        log = tmp_path / "run.log"
        cmd = procs.with_exit_marker('echo "VAL=$MYVAR"', log)
        procs.spawn_detached(cmd, log, {"MYVAR": "x7"}, tmp_path)

        deadline = time.time() + 5
        found = False
        while time.time() < deadline:
            if log.exists() and "VAL=x7" in log.read_text():
                found = True
                break
            time.sleep(0.05)
        assert found, f"Env var not in log; log: {log.read_text() if log.exists() else '<missing>'}"
