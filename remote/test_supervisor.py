#!/usr/bin/env python3
"""Stdlib unit tests for remote/supervisor.py (no ssh, no network, no GPU).

Run:  python3 remote/test_supervisor.py
"""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import supervisor  # noqa: E402


class FakeTransport:
    """Records remote commands; every command 'succeeds' except the train.pid
    liveness probe (so phase_launch actually launches)."""

    target = "user@fake"

    def __init__(self):
        self.cmds = []

    def run(self, cmd, timeout=60, binary=False):
        self.cmds.append(cmd)
        rc = 1 if "kill -0" in cmd else 0
        return supervisor.subprocess.CompletedProcess([cmd], rc, "", "")


def _sup(run_dir):
    spec = {"run_id": "r1", "name": "t", "mode": "sft", "remote_dir": "studio-run-t-r1",
            "launch_cmd": "python train_sft.py", "policy": {}}
    with open(os.path.join(run_dir, "runspec.json"), "w") as f:
        json.dump(spec, f)
    s = supervisor.Supervisor(run_dir, no_api=True)
    s.transport = FakeTransport()
    return s


class LaunchTests(unittest.TestCase):
    def test_launch_appends_train_log(self):
        # A relaunch after --resume reuses the remote dir. Truncating train.log
        # ('>') desynced the byte-offset mirror (local offset > remote size), so
        # new output was never mirrored and the stall watchdog fired. Append.
        with tempfile.TemporaryDirectory() as d:
            s = _sup(d)
            s.phase_launch()
            launch = [c for c in s.transport.cmds if "nohup" in c]
            self.assertEqual(len(launch), 1, s.transport.cmds)
            self.assertIn(">> train.log", launch[0])
            self.assertNotIn(" > train.log", launch[0])


if __name__ == "__main__":
    unittest.main()
