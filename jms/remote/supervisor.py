#!/usr/bin/env python3
"""Orchestration supervisor for one remote GPU training run (Spheron.ai VM).

Spawned detached by the studio server:
    Popen(shell=True, start_new_session=True, stdout=<run-dir>/run-<mode>.log)

It owns a single remote run end-to-end and communicates ONLY through files
in its run dir:

  reads   runspec.json   (what to run, where, policies)
  reads   control.json   ({"action":"stop"} -> graceful stop)
  writes  status.json    (atomic tmp+rename, heartbeat every loop)
  writes  .job-<mode>.json (server jobs.live_status shape)
  writes  train.log / metrics.jsonl mirrors (byte-offset incremental)
  appends "__EXIT__ <code>" to run-<mode>.log at finalize

Spheron REST API is only used for: deployment status/sshCommand polling,
can-terminate check, and DELETE. There is NO exec/log API -- SSH from this
Mac is the only channel to the VM.

Transport seam: the binaries used for ssh/rsync/scp come from env
JMS_SSH_BIN / JMS_RSYNC_BIN / JMS_SCP_BIN (default ssh/rsync/scp) so tests
can substitute a local transport shim with the same argv surface.

stdlib only. CLI:
    supervisor.py --run-dir <dir> [--resume] [--pull-only] [--no-spheron-api]
"""

import argparse
import calendar
import hashlib
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time

SSH_BIN = os.environ.get("JMS_SSH_BIN", "ssh")
RSYNC_BIN = os.environ.get("JMS_RSYNC_BIN", "rsync")
SCP_BIN = os.environ.get("JMS_SCP_BIN", "scp")

DEFAULT_API_URL = "https://api.spheron.network"

# ssh flags that consume a value argument
_SSH_VAL_FLAGS = {"-p", "-i", "-o", "-l", "-F", "-J", "-E", "-L", "-R", "-W", "-b", "-c", "-D", "-e", "-m", "-Q", "-S"}


def _now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _log(msg):
    print("[supervisor %s] %s" % (_now_iso(), msg), flush=True)


def atomic_write_json(path, obj):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


class StopRequested(Exception):
    """control.json stop or SIGTERM."""


class RunFailed(Exception):
    def __init__(self, message, pull_first=False):
        super().__init__(message)
        self.pull_first = pull_first


class Transport:
    """SSH/rsync/scp wrapper around one target host.

    Built from an 'ssh user@host [flags]' command string (from runspec
    ssh_override or the Spheron API's sshCommand). Binary names come from
    JMS_SSH_BIN/JMS_RSYNC_BIN/JMS_SCP_BIN so tests can shim the transport.
    """

    def __init__(self, ssh_cmd_string, run_dir):
        toks = shlex.split(ssh_cmd_string.strip())
        if toks and os.path.basename(toks[0]) == "ssh":
            toks = toks[1:]
        self.extra = []
        self.target = ""
        i = 0
        while i < len(toks):
            t = toks[i]
            if t in _SSH_VAL_FLAGS and i + 1 < len(toks):
                self.extra += [t, toks[i + 1]]
                i += 2
            elif t.startswith("-"):
                self.extra.append(t)
                i += 1
            else:
                if not self.target:
                    self.target = t
                i += 1
        if not self.target:
            raise ValueError("could not parse ssh target from: %r" % ssh_cmd_string)
        self.known_hosts = os.path.join(run_dir, "known_hosts")
        self.base_opts = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=%s" % self.known_hosts,
        ]

    def ssh_argv(self):
        return [SSH_BIN] + self.base_opts + list(self.extra)

    def run(self, cmd, timeout=60, binary=False):
        """Run `cmd` on the remote host. Returns CompletedProcess.
        returncode 255 conventionally means transport (ssh) failure."""
        argv = self.ssh_argv() + [self.target, cmd]
        try:
            return subprocess.run(argv, capture_output=True, text=not binary, timeout=timeout)
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(argv, 255, b"" if binary else "", "ssh timeout")
        except OSError as e:
            return subprocess.CompletedProcess(argv, 255, b"" if binary else "", str(e))

    # -- file copy ----------------------------------------------------------
    def _rsync_e(self):
        return " ".join([SSH_BIN] + self.base_opts + list(self.extra))

    def _scp_opts(self):
        opts = list(self.base_opts)
        extra = list(self.extra)
        out = []
        i = 0
        while i < len(extra):
            if extra[i] == "-p" and i + 1 < len(extra):  # ssh port -> scp -P
                out += ["-P", extra[i + 1]]
                i += 2
            else:
                out.append(extra[i])
                i += 1
        return opts + out

    def copy(self, src, dst, timeout=600):
        """rsync src -> dst (either side may be '<target>:path'). Falls back
        to scp -O -r when rsync is missing on either end (exit 127-ish)."""
        argv = [RSYNC_BIN, "-az", "--partial", "--timeout=120", "-e", self._rsync_e(), src, dst]
        try:
            p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(argv, 255, "", "rsync timeout")
        except OSError:
            p = subprocess.CompletedProcess(argv, 127, "", "rsync binary missing")
        if p.returncode in (127, 126) or "rsync: command not found" in (p.stderr or ""):
            _log("rsync unavailable (rc=%s), falling back to scp -O" % p.returncode)
            argv = [SCP_BIN, "-O", "-r", "-q"] + self._scp_opts() + [src, dst]
            try:
                p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
            except (subprocess.TimeoutExpired, OSError) as e:
                return subprocess.CompletedProcess(argv, 255, "", str(e))
        return p


class SpheronAPI:
    """Minimal Bearer-auth client for the 4 endpoints the supervisor needs."""

    def __init__(self):
        self.url = os.environ.get("SPHERON_API_URL", DEFAULT_API_URL).rstrip("/")
        self.key = os.environ.get("SPHERON_API_KEY", "")

    def _request(self, method, path):
        import urllib.request
        import urllib.error
        req = urllib.request.Request(
            self.url + path, method=method,
            headers={"Authorization": "Bearer %s" % self.key,
                     "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")
            raise RuntimeError("HTTP %s %s %s: %s" % (e.code, method, path, body[:300]))
        except Exception as e:
            raise RuntimeError("%s %s: %s" % (method, path, e))
        try:
            return json.loads(body) if body.strip() else {}
        except ValueError:
            return {"raw": body}

    def deployment(self, dep_id):
        return self._request("GET", "/api/deployments/%s" % dep_id)

    def can_terminate(self, dep_id):
        return self._request("GET", "/api/deployments/%s/can-terminate" % dep_id)

    def delete(self, dep_id):
        return self._request("DELETE", "/api/deployments/%s" % dep_id)


def _dep_status(dep):
    for k in ("status", "state", "cur_state"):
        v = dep.get(k)
        if isinstance(v, str) and v:
            return v.lower()
    return ""


def _dep_ssh(dep):
    """Defensively extract an ssh command from a deployment dict."""
    for k in ("sshCommand", "ssh_command", "ssh", "sshCmd"):
        v = dep.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
    conn = dep.get("connection")
    if isinstance(conn, dict):
        for k in ("ssh", "sshCommand", "ssh_command"):
            v = conn.get(k)
            if isinstance(v, str) and v.strip():
                return v.strip()
    return ""


RUNNING_STATES = ("running", "active", "ready", "deployed", "healthy")
DEAD_STATES = ("terminated", "failed", "deleted", "destroyed", "error", "closed", "stopped")


class Supervisor:
    PHASES = ["wait_vm", "provision", "launch", "monitor", "pull", "terminate", "finalize"]

    def __init__(self, run_dir, resume=False, pull_only=False, no_api=False):
        self.run_dir = os.path.abspath(run_dir)
        self.resume = resume
        self.pull_only = pull_only
        self.no_api = no_api
        self.spec = read_json(os.path.join(self.run_dir, "runspec.json"))
        if not self.spec:
            print("fatal: cannot read runspec.json in %s" % self.run_dir, file=sys.stderr)
            sys.exit(2)
        self.policy = dict(self.spec.get("policy") or {})
        self.mode = self.spec.get("mode", "sft")
        self.name = self.spec.get("name", self.spec.get("run_id", ""))
        self.remote_dir = self.spec.get("remote_dir", "studio-run")
        self.api = None if no_api else SpheronAPI()
        self.transport = None
        self.exit_code = None          # remote train exit code, when known
        self._stop_reason = None
        self._offsets_files = ["train.log", "metrics.jsonl"]

        prev = read_json(self.status_path(), {}) or {}
        self.st = {
            "version": 1,
            "run_id": self.spec.get("run_id", ""),
            "name": self.name,
            "mode": self.mode,
            "phase": prev.get("phase", ""),
            "status": "running",
            "message": "",
            "deployment_id": self.spec.get("deployment_id", ""),
            "ssh": prev.get("ssh", ""),
            "supervisor_pid": os.getpid(),
            "heartbeat": _now_iso(),
            "phase_history": prev.get("phase_history", []),
            "cost": prev.get("cost") or {
                "hourly_rate": float(self.spec.get("hourly_rate") or 0.0),
                "started_billing": "",
                "elapsed_usd": 0.0,
                "terminated_at": "",
            },
            "progress": prev.get("progress") or {"step": 0, "max_steps": 0, "loss": None, "eval_loss": None},
            "artifacts": prev.get("artifacts") or {"pulled": False, "adapter_dir": "", "bytes": 0},
            "vm_terminated": bool(prev.get("vm_terminated", False)),
            "ssh_errors": 0,
            "exit_code": prev.get("exit_code"),
            "error": "",
        }
        self._phase_started = time.time()
        self._billing_epoch = None
        if self.st["cost"].get("started_billing"):
            try:
                # timegm, not mktime-timezone: the stamp is UTC and mktime's
                # timezone correction is off by an hour during DST.
                self._billing_epoch = calendar.timegm(time.strptime(
                    self.st["cost"]["started_billing"], "%Y-%m-%dT%H:%M:%SZ"))
            except Exception:
                self._billing_epoch = None

    # -- paths --------------------------------------------------------------
    def status_path(self):
        return os.path.join(self.run_dir, "status.json")

    def job_path(self):
        return os.path.join(self.run_dir, ".job-%s.json" % self.mode)

    def runlog_path(self):
        return os.path.join(self.run_dir, "run-%s.log" % self.mode)

    # -- status/job bookkeeping ---------------------------------------------
    def write_status(self):
        self.st["heartbeat"] = _now_iso()
        if self._billing_epoch and not self.st["cost"].get("terminated_at"):
            hrs = max(0.0, (time.time() - self._billing_epoch) / 3600.0)
            self.st["cost"]["elapsed_usd"] = round(hrs * float(self.st["cost"].get("hourly_rate") or 0.0), 4)
        atomic_write_json(self.status_path(), self.st)

    def write_job(self, status, started=None):
        job = read_json(self.job_path(), {}) or {}
        atomic_write_json(self.job_path(), {
            "name": self.name,
            "mode": self.mode,
            "pid": os.getpid(),
            "status": status,
            "started": started or job.get("started") or _now_iso(),
        })

    def set_phase(self, phase, message=""):
        now = time.time()
        hist = self.st["phase_history"]
        if self.st["phase"] and (not hist or hist[-1]["phase"] != self.st["phase"]):
            hist.append({"phase": self.st["phase"], "at": _now_iso(),
                         "secs": round(now - self._phase_started, 1)})
        elif hist and self.st["phase"] and hist[-1]["phase"] == self.st["phase"]:
            hist[-1]["secs"] = round(now - self._phase_started, 1)
        self.st["phase"] = phase
        self.st["message"] = message or phase
        self._phase_started = now
        _log("phase -> %s %s" % (phase, ("(%s)" % message) if message else ""))
        self.write_status()

    def start_billing(self):
        if not self.st["cost"].get("started_billing"):
            self.st["cost"]["started_billing"] = _now_iso()
            self._billing_epoch = time.time()

    # -- control ------------------------------------------------------------
    def check_control(self):
        ctl = read_json(os.path.join(self.run_dir, "control.json"))
        if isinstance(ctl, dict) and ctl.get("action") == "stop":
            raise StopRequested("stop requested via control.json")

    def install_signal_handlers(self):
        def _onterm(signum, frame):
            raise StopRequested("SIGTERM")
        signal.signal(signal.SIGTERM, _onterm)

    # -- transport resolution -----------------------------------------------
    def resolve_transport(self, require=True):
        """ssh_override always wins for transport (even in API mode -- the
        API then only supplies deployment status). Else API sshCommand."""
        if self.transport:
            return self.transport
        ovr = self.spec.get("ssh_override", "")
        if ovr:
            self.transport = Transport(ovr, self.run_dir)
            self.st["ssh"] = ovr
            return self.transport
        ssh = self.st.get("ssh", "")
        if ssh:
            self.transport = Transport(ssh, self.run_dir)
            return self.transport
        if self.api and self.st["deployment_id"]:
            try:
                dep = self.api.deployment(self.st["deployment_id"])
                ssh = _dep_ssh(dep)
                if ssh:
                    self.st["ssh"] = ssh
                    self.transport = Transport(ssh, self.run_dir)
                    return self.transport
            except Exception as e:
                _log("resolve_transport: api error: %s" % e)
        if require:
            raise RunFailed("no ssh transport available (no ssh_override and no API sshCommand)")
        return None

    # -- phase 1: wait_vm ----------------------------------------------------
    def phase_wait_vm(self):
        self.set_phase("wait_vm", "waiting for VM")
        timeout = float(self.policy.get("ssh_wait_timeout_s", 900))
        deadline = time.time() + timeout
        if self.no_api:
            if not self.spec.get("ssh_override"):
                raise RunFailed("--no-spheron-api requires runspec ssh_override")
            self.resolve_transport()
        else:
            dep_id = self.st["deployment_id"]
            if not dep_id:
                raise RunFailed("runspec has no deployment_id")
            while True:
                self.check_control()
                try:
                    dep = self.api.deployment(dep_id)
                except Exception as e:
                    _log("wait_vm: api poll error: %s" % e)
                    dep = {}
                stt = _dep_status(dep)
                ssh = _dep_ssh(dep)
                self.st["message"] = "vm status: %s" % (stt or "unknown")
                self.write_status()
                if stt in DEAD_STATES:
                    raise RunFailed("deployment %s is %s before boot" % (dep_id, stt))
                if stt in RUNNING_STATES and (ssh or self.spec.get("ssh_override")):
                    if ssh and not self.spec.get("ssh_override"):
                        self.st["ssh"] = ssh
                    break
                if time.time() > deadline:
                    self.terminate_vm(reason="wait_vm timeout")
                    raise RunFailed("timed out waiting for VM to run (%.0fs)" % timeout)
                time.sleep(min(10, float(self.policy.get("poll_interval_s", 10))))
            self.resolve_transport()
        self.start_billing()
        # ssh reachability loop
        self.st["message"] = "waiting for ssh"
        self.write_status()
        while True:
            self.check_control()
            p = self.transport.run("true", timeout=20)
            if p.returncode == 0:
                _log("ssh reachable: %s" % self.st.get("ssh", self.spec.get("ssh_override", "")))
                return
            self.st["ssh_errors"] += 1
            self.write_status()
            if time.time() > deadline:
                self.terminate_vm(reason="ssh wait timeout")
                raise RunFailed("VM never became ssh-reachable (%.0fs)" % timeout)
            time.sleep(10)

    # -- phase 2: provision --------------------------------------------------
    def phase_provision(self):
        self.set_phase("provision", "uploading + bootstrap")
        t = self.transport
        rd = shlex.quote(self.remote_dir)
        p = t.run("mkdir -p %s" % rd, timeout=30)
        if p.returncode != 0:
            raise RunFailed("provision: mkdir failed: %s" % (p.stderr or "").strip()[-300:])
        # skip if already provisioned (idempotent resume)
        if t.run("test -e %s/.provisioned" % rd, timeout=20).returncode == 0:
            _log("provision: remote .provisioned exists, skipping")
            return
        uploads = list(self.spec.get("uploads") or [])
        # ensure bootstrap.sh ships even if the server forgot to list it
        if not any(u.get("remote") == "bootstrap.sh" for u in uploads):
            local_bs = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bootstrap.sh")
            if os.path.exists(local_bs):
                uploads.append({"local": local_bs, "remote": "bootstrap.sh"})
        for u in uploads:
            local = u.get("local", "")
            remote = u.get("remote") or os.path.basename(local.rstrip("/"))
            if not os.path.exists(local):
                raise RunFailed("provision: upload missing locally: %s" % local)
            rdir = os.path.dirname(remote)
            if rdir:
                t.run("mkdir -p %s" % shlex.quote(self.remote_dir + "/" + rdir), timeout=30)
            src = local.rstrip("/") + "/" if os.path.isdir(local) else local
            dst = "%s:%s/%s" % (t.target, self.remote_dir, remote)
            self.st["message"] = "upload %s" % remote
            self.write_status()
            cp = t.copy(src, dst)
            if cp.returncode != 0:
                raise RunFailed("provision: upload %s failed: %s" % (remote, (cp.stderr or "").strip()[-300:]))
        prov_to = float(self.policy.get("provision_timeout_s", 1800))
        self.st["message"] = "running bootstrap.sh"
        self.write_status()
        cmd = "cd %s && bash bootstrap.sh > provision.log 2>&1 && touch .provisioned" % rd
        p = t.run(cmd, timeout=prov_to)
        if p.returncode != 0:
            tail = ""
            tp = t.run("tail -n 40 %s/provision.log 2>/dev/null || true" % rd, timeout=30)
            if tp.returncode == 0:
                tail = (tp.stdout or "").strip()[-1500:]
                with open(os.path.join(self.run_dir, "provision.log"), "a") as f:
                    f.write(tp.stdout or "")
            raise RunFailed("provision failed: %s" % (tail or (p.stderr or "").strip()[-300:]))
        _log("provision: done")

    # -- phase 3: launch -----------------------------------------------------
    def phase_launch(self):
        self.set_phase("launch", "launching training")
        t = self.transport
        rd = shlex.quote(self.remote_dir)
        chk = t.run("cd %s && test -f train.pid && kill -0 $(cat train.pid) 2>/dev/null" % rd, timeout=20)
        if chk.returncode == 0:
            _log("launch: remote train.pid alive, skipping relaunch")
            return
        launch_cmd = self.spec.get("launch_cmd", "")
        if not launch_cmd:
            raise RunFailed("runspec has no launch_cmd")
        inner = "%s > train.log 2>&1; echo __EXIT__ $? >> run.log" % launch_cmd
        # NB: '&' must bind to the *simple* nohup command (not a 'cd && nohup'
        # list) -- otherwise the un-redirected background subshell holds the
        # ssh stdout/stderr pipes open and this call blocks for the whole run.
        remote_cmd = "cd %s || exit 9; nohup bash -c %s < /dev/null > /dev/null 2>&1 & echo $! > train.pid" % (
            rd, shlex.quote(inner))
        p = t.run(remote_cmd, timeout=30)
        if p.returncode != 0:
            raise RunFailed("launch failed: %s" % (p.stderr or "").strip()[-300:])
        _log("launch: started (%s)" % launch_cmd)

    # -- phase 4: monitor ----------------------------------------------------
    def _mirror(self, fname):
        """Incremental byte-offset mirror of remote <remote_dir>/<fname> to
        <run_dir>/<fname>. Returns (transport_ok, bytes_appended)."""
        local = os.path.join(self.run_dir, fname)
        off = os.path.getsize(local) if os.path.exists(local) else 0
        cmd = "tail -c +%d %s 2>/dev/null || true" % (off + 1, shlex.quote(self.remote_dir + "/" + fname))
        p = self.transport.run(cmd, timeout=60, binary=True)
        if p.returncode != 0:
            return False, 0
        data = p.stdout or b""
        if data:
            with open(local, "ab") as f:
                f.write(data)
        return True, len(data)

    def _parse_progress(self):
        path = os.path.join(self.run_dir, "metrics.jsonl")
        try:
            size = os.path.getsize(path)
            with open(path, "rb") as f:
                f.seek(max(0, size - 8192))
                lines = [l for l in f.read().decode("utf-8", "replace").splitlines() if l.strip()]
            for line in reversed(lines):
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                pr = self.st["progress"]
                for k_out, keys in (("step", ("step", "global_step")),
                                    ("max_steps", ("max_steps", "total_steps")),
                                    ("loss", ("loss", "train_loss")),
                                    ("eval_loss", ("eval_loss",))):
                    for k in keys:
                        if k in m:
                            pr[k_out] = m[k]
                            break
                return
        except OSError:
            pass

    def _remote_exit_code(self):
        p = self.transport.run("cat %s 2>/dev/null || true" % shlex.quote(self.remote_dir + "/run.log"), timeout=30)
        if p.returncode != 0:
            return None, False
        hits = re.findall(r"__EXIT__\s+(-?\d+)", p.stdout or "")
        return (int(hits[-1]) if hits else None), True

    def remote_pkill(self):
        cmd = ("cd %s && test -f train.pid && pid=$(cat train.pid) && "
               "{ pkill -TERM -P $pid 2>/dev/null; kill -TERM $pid 2>/dev/null; } || true"
               ) % shlex.quote(self.remote_dir)
        try:
            self.transport.run(cmd, timeout=20)
        except Exception:
            pass

    def phase_monitor(self):
        self.set_phase("monitor", "training")
        poll = float(self.policy.get("poll_interval_s", 10))
        max_wall = float(self.policy.get("max_wall_clock_min", 720)) * 60.0
        stall_s = float(self.policy.get("stall_timeout_min", 30)) * 60.0
        started = time.time()
        last_growth = time.time()
        ssh_fail_since = None
        while True:
            self.check_control()
            ok_any = False
            grew = False
            for fname in self._offsets_files:
                ok, n = self._mirror(fname)
                ok_any = ok_any or ok
                if fname == "train.log" and n > 0:
                    grew = True
            if grew:
                last_growth = time.time()
            self._parse_progress()

            if ok_any:
                ssh_fail_since = None
                code, _ = self._remote_exit_code()
                if code is not None:
                    self.exit_code = code
                    self.st["exit_code"] = code
                    _log("monitor: remote __EXIT__ %d" % code)
                    self.write_status()
                    return
            else:
                self.st["ssh_errors"] += 1
                if ssh_fail_since is None:
                    ssh_fail_since = time.time()
                down = time.time() - ssh_fail_since
                _log("monitor: ssh unreachable for %.0fs" % down)
                if down > 300:
                    dead = False
                    if self.no_api:
                        dead = True
                    elif self.api and self.st["deployment_id"]:
                        try:
                            stt = _dep_status(self.api.deployment(self.st["deployment_id"]))
                            dead = stt in DEAD_STATES
                        except Exception as e:
                            _log("monitor: api check failed: %s" % e)
                    if dead:
                        raise RunFailed("vm lost (ssh dead >5min%s)" % (
                            "" if self.no_api else ", api says deployment dead"), pull_first=True)
                # back off, don't fail
                self.write_status()
                time.sleep(min(60, poll * 2))
                continue

            if time.time() - started > max_wall:
                self.remote_pkill()
                raise RunFailed("watchdog: max wall clock exceeded (%.0f min)"
                                % (max_wall / 60.0), pull_first=True)
            if time.time() - last_growth > stall_s:
                self.remote_pkill()
                raise RunFailed("watchdog: train.log stalled >%.1f min" % (stall_s / 60.0),
                                pull_first=True)
            self.write_status()
            time.sleep(poll)

    # -- phase 5: pull -------------------------------------------------------
    def phase_pull(self):
        self.set_phase("pull", "pulling artifacts")
        t = self.transport
        if t is None:
            _log("pull: no transport, skipping")
            return
        # final log mirror sweep
        for fname in self._offsets_files:
            try:
                self._mirror(fname)
            except Exception:
                pass
        total_bytes = 0
        adapter_dir = ""
        any_pulled = False
        for item in (self.spec.get("pull") or []):
            remote = item.get("remote", "")
            if not remote:
                continue
            local_name = item.get("local") or os.path.basename(remote.rstrip("/"))
            local = os.path.join(self.run_dir, local_name)
            rpath = self.remote_dir + "/" + remote
            probe = t.run("if test -d %s; then echo DIR; elif test -e %s; then echo FILE; else echo MISSING; fi"
                          % (shlex.quote(rpath), shlex.quote(rpath)), timeout=30)
            kind = (probe.stdout or "").strip() if probe.returncode == 0 else "ERR"
            if kind == "MISSING":
                _log("pull: remote missing, skipping: %s" % rpath)
                continue
            if kind == "ERR":
                _log("pull: probe failed for %s" % rpath)
            is_dir = kind == "DIR"
            src = "%s:%s%s" % (t.target, rpath, "/" if is_dir else "")
            if is_dir:
                os.makedirs(local, exist_ok=True)
            else:
                os.makedirs(os.path.dirname(local) or self.run_dir, exist_ok=True)
            ok = False
            for attempt in range(3):
                cp = t.copy(src, local)
                if cp.returncode == 0:
                    ok = True
                    break
                _log("pull: attempt %d failed for %s: %s" % (attempt + 1, remote,
                                                             (cp.stderr or "").strip()[-200:]))
                time.sleep(3)
            if not ok:
                _log("pull: giving up on %s" % remote)
                continue
            any_pulled = True
            if is_dir:
                self._verify_dir(rpath, local)
                for root_, _, files in os.walk(local):
                    for fn in files:
                        try:
                            total_bytes += os.path.getsize(os.path.join(root_, fn))
                        except OSError:
                            pass
                if "adapter" in local_name.lower() or "adapter" in remote.lower():
                    adapter_dir = local
            else:
                try:
                    total_bytes += os.path.getsize(local)
                except OSError:
                    pass
        self.st["artifacts"] = {"pulled": any_pulled, "adapter_dir": adapter_dir, "bytes": total_bytes}
        self.write_status()
        _log("pull: done (pulled=%s bytes=%d)" % (any_pulled, total_bytes))

    def _verify_dir(self, rpath, local):
        """Best-effort sha256 verify of pulled dir; log mismatches only."""
        try:
            p = self.transport.run(
                "cd %s && find . -type f -exec sha256sum {} + 2>/dev/null || true" % shlex.quote(rpath),
                timeout=120)
            if p.returncode != 0 or not (p.stdout or "").strip():
                return
            for line in p.stdout.splitlines():
                m = re.match(r"^([0-9a-f]{64})\s+\*?(.+)$", line.strip())
                if not m:
                    continue
                digest, rel = m.group(1), m.group(2).lstrip("./")
                lp = os.path.join(local, rel)
                try:
                    h = hashlib.sha256()
                    with open(lp, "rb") as f:
                        for chunk in iter(lambda: f.read(1 << 20), b""):
                            h.update(chunk)
                    if h.hexdigest() != digest:
                        _log("pull: VERIFY MISMATCH %s (remote %s local %s)" % (rel, digest[:12], h.hexdigest()[:12]))
                except OSError as e:
                    _log("pull: verify could not read local %s: %s" % (rel, e))
        except Exception as e:
            _log("pull: verify skipped: %s" % e)

    # -- phase 6: terminate --------------------------------------------------
    def terminate_vm(self, reason=""):
        """Terminate unless policy auto_terminate == 'never'. Failure paths
        also terminate (billing safety); 'never' is the only keep-alive."""
        policy = (self.policy.get("auto_terminate") or "on_success").lower()
        if policy == "never":
            _log("terminate: policy=never, leaving VM up (%s)" % reason)
            return
        if self.st.get("vm_terminated"):
            return
        self.set_phase("terminate", reason or "terminating VM")
        if self.no_api or self.api is None:
            _log("terminate: --no-spheron-api, marking vm_terminated")
            self.st["vm_terminated"] = True
            self.st["cost"]["terminated_at"] = _now_iso()
            self.write_status()
            return
        dep_id = self.st["deployment_id"]
        if not dep_id:
            return
        deadline = time.time() + 600  # bounded 10 min on can-terminate
        while time.time() < deadline:
            try:
                chk = self.api.can_terminate(dep_id)
                if bool(chk.get("canTerminate", chk.get("can_terminate", False))):
                    break
                _log("terminate: minimum runtime not met (remaining=%s), waiting"
                     % chk.get("timeRemaining"))
            except Exception as e:
                _log("terminate: can-terminate error: %s" % e)
            time.sleep(15)
        try:
            self.api.delete(dep_id)
            self.st["vm_terminated"] = True
            self.st["cost"]["terminated_at"] = _now_iso()
            _log("terminate: deployment %s deleted" % dep_id)
        except Exception as e:
            self.st["error"] = self.st["error"] or ("terminate failed: %s" % e)
            _log("terminate: DELETE failed: %s" % e)
        self.write_status()

    # -- phase 7: finalize ---------------------------------------------------
    def finalize(self, status, exit_code, message="", error=""):
        self.set_phase("finalize", message or status)
        self.st["status"] = status
        self.st["message"] = message or status
        self.st["error"] = error
        if exit_code is not None:
            self.st["exit_code"] = exit_code
        self.write_status()
        self.write_job(status)
        _log("finalize: status=%s exit=%s %s" % (status, exit_code, error or message))
        # The __EXIT__ line must be the LAST write to run-<mode>.log. Our own
        # stdout is usually that very file, opened by the server with '>' (no
        # O_APPEND), so a separate append-fd and the stdout-fd track different
        # offsets and clobber each other. If stdout IS the run log, write the
        # line through stdout; otherwise append normally.
        line = "__EXIT__ %d\n" % (exit_code if exit_code is not None else 1)
        try:
            sys.stdout.flush()
        except Exception:
            pass
        same = False
        try:
            so, lf = os.fstat(1), os.stat(self.runlog_path())
            same = (so.st_ino == lf.st_ino and so.st_dev == lf.st_dev)
        except OSError:
            same = False
        try:
            if same:
                sys.stdout.write(line)
                sys.stdout.flush()
            else:
                with open(self.runlog_path(), "a") as f:
                    f.write(line)
        except OSError as e:
            print("finalize: could not append __EXIT__ to run log: %s" % e,
                  file=sys.stderr)

    # -- stop / fail flows ---------------------------------------------------
    def do_stop(self, reason):
        """Graceful stop: remote pkill, pull partial, terminate per policy,
        status=stopped. 20s budget when reason is SIGTERM."""
        budget = 20.0 if reason == "SIGTERM" else 300.0
        t0 = time.time()
        _log("stop: %s (budget %.0fs)" % (reason, budget))
        try:
            if self.transport:
                self.remote_pkill()
        except Exception:
            pass
        if time.time() - t0 < budget - 5 and reason != "SIGTERM":
            try:
                self.phase_pull()
            except Exception as e:
                _log("stop: pull failed: %s" % e)
        try:
            self.terminate_vm(reason="stop: %s" % reason)
        except Exception as e:
            _log("stop: terminate failed: %s" % e)
        self.finalize("stopped", 143, message="stopped (%s)" % reason)

    def do_fail(self, err):
        _log("fail: %s" % err)
        if getattr(err, "pull_first", False):
            try:
                self.phase_pull()
            except Exception as e:
                _log("fail: best-effort pull failed: %s" % e)
        try:
            self.terminate_vm(reason="failure: %s" % err)
        except Exception as e:
            _log("fail: terminate failed: %s" % e)
        code = self.exit_code if (self.exit_code not in (None, 0)) else 1
        self.finalize("failed", code, message=str(err), error=str(err))

    # -- resume probing ------------------------------------------------------
    def compute_resume_phase(self):
        """Probe remote + API to decide where to jump. Returns phase name."""
        prev = read_json(self.status_path(), {}) or {}
        if prev.get("status") in ("done", "failed", "stopped"):
            _log("resume: previous run already terminal (%s); nothing to do" % prev["status"])
            return None
        # is the deployment even alive?
        if not self.no_api and self.api and self.st["deployment_id"]:
            try:
                stt = _dep_status(self.api.deployment(self.st["deployment_id"]))
                if stt in DEAD_STATES:
                    raise RunFailed("resume: deployment already %s; finalizing from local mirrors" % stt)
            except RunFailed:
                raise
            except Exception as e:
                _log("resume: api probe error (continuing): %s" % e)
        try:
            self.resolve_transport()
        except RunFailed:
            raise RunFailed("resume: no transport; finalizing from local mirrors")
        if self.transport.run("true", timeout=20).returncode != 0:
            # give wait_vm loop a chance (VM may still be rebooting)
            return "wait_vm"
        rd = shlex.quote(self.remote_dir)
        code, ok = self._remote_exit_code()
        if ok and code is not None:
            self.exit_code = code
            self.st["exit_code"] = code
            return "pull"
        alive = self.transport.run(
            "cd %s && test -f train.pid && kill -0 $(cat train.pid) 2>/dev/null" % rd, timeout=20)
        if alive.returncode == 0:
            return "monitor"
        provisioned = self.transport.run("test -e %s/.provisioned" % rd, timeout=20)
        if provisioned.returncode == 0:
            # provisioned but nothing running and no exit recorded -> (re)launch
            return "launch"
        return "provision"

    # -- main ----------------------------------------------------------------
    def run(self):
        self.install_signal_handlers()
        self.write_job("running", started=_now_iso())
        self.write_status()
        try:
            if self.pull_only:
                self.resolve_transport(require=False)
                self.phase_pull()
                prev_status = (read_json(self.status_path(), {}) or {}).get("status")
                code = self.st.get("exit_code")
                self.finalize("done" if self.st["artifacts"].get("pulled") else "failed",
                              code if code is not None else 0,
                              message="pull-only complete (prior status: %s)" % prev_status)
                return 0

            start_phase = "wait_vm"
            if self.resume:
                start_phase = self.compute_resume_phase()
                if start_phase is None:
                    return 0
                _log("resume: jumping to phase %s" % start_phase)
                self.start_billing()

            order = ["wait_vm", "provision", "launch", "monitor", "pull"]
            for phase in order[order.index(start_phase):]:
                getattr(self, "phase_" + phase)()

            if self.exit_code == 0:
                self.terminate_vm(reason="run succeeded")
                self.finalize("done", 0, message="run complete")
                return 0
            else:
                raise RunFailed("training exited with code %s" % self.exit_code)
        except StopRequested as e:
            self.do_stop(str(e))
            return 0
        except RunFailed as e:
            self.do_fail(e)
            return 1
        except Exception as e:  # unexpected -> still finalize + billing safety
            import traceback
            traceback.print_exc()
            self.do_fail(RunFailed("internal error: %s" % e))
            return 1


def main():
    ap = argparse.ArgumentParser(description="Remote GPU run supervisor")
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--resume", action="store_true")
    ap.add_argument("--pull-only", action="store_true")
    ap.add_argument("--no-spheron-api", action="store_true")
    args = ap.parse_args()
    sup = Supervisor(args.run_dir, resume=args.resume, pull_only=args.pull_only,
                     no_api=args.no_spheron_api)
    sys.exit(sup.run())


if __name__ == "__main__":
    main()
