"""Detached-process job lifecycle. Ported from dashboard_app/services/jobs.sv.jac.

Job json files are the source of truth and survive server restarts; the
__EXIT__ marker in the run log is authoritative over pid liveness (children get
reparented after a server restart, so waitpid fails silently and zombies still
answer kill-0).
"""

import json
import os
import re
import shlex
import signal
import subprocess
import time
from pathlib import Path


# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

def safe(s: str, allow_slash: bool = False) -> bool:
    """Return True iff *s* is safe to embed in a shell command.

    Allowlist: ``[A-Za-z0-9_.-]`` (plus ``/`` when *allow_slash* is True).
    Even with *allow_slash*, any ``..`` path segment is rejected.
    """
    if not s:
        return False
    # Reject any .. path segment (e.g. "a/../b", "..", "../foo")
    if allow_slash:
        # Split on / and check each segment
        for segment in s.split("/"):
            if segment == "..":
                return False
        return re.fullmatch(r"[A-Za-z0-9_./-]+", s) is not None
    return re.fullmatch(r"[A-Za-z0-9_.-]+", s) is not None


# ---------------------------------------------------------------------------
# Process liveness
# ---------------------------------------------------------------------------

def alive(pid: int) -> bool:
    """Return True iff the process *pid* is alive.

    Uses ``os.kill(pid, 0)``:
    - ``PermissionError`` → process exists but we can't signal it → alive
    - ``ProcessLookupError`` → no such process → dead
    - ``pid <= 0`` → always False
    """
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except Exception:
        return False


def reap(pid: int) -> None:
    """Reap a finished child process (non-blocking).

    Only works for direct children of this process; silently ignores errors
    for non-children or already-reaped pids.
    """
    try:
        os.waitpid(pid, os.WNOHANG)
    except Exception:
        return


# ---------------------------------------------------------------------------
# Job JSON persistence
# ---------------------------------------------------------------------------

def read_job(job_file: Path) -> dict | None:
    """Read and return the job dict from *job_file*, or None on any error."""
    p = Path(job_file)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except Exception:
        return None


def write_job(job_file: Path, job: dict) -> None:
    """Atomically write *job* dict as JSON to *job_file*, creating parents."""
    p = Path(job_file)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(job))


# ---------------------------------------------------------------------------
# Live status resolution
# ---------------------------------------------------------------------------

def live_status(job_file: Path, runlog: Path) -> dict | None:
    """Return a refreshed job dict with an up-to-date ``status`` field.

    Resolution order (only applied when stored status is "running"):

    1. Reap the pid so zombies don't pollute kill-0 checks.
    2. Search the last 80 lines of *runlog* for ``__EXIT__ <n>``.
       - Found with n=0 → "done"
       - Found with n≠0 → "failed"
    3. No marker + pid alive  → "running"
    4. No marker + pid dead   → "stopped"

    The resolved status is persisted back to *job_file* before returning.
    Returns None if *job_file* does not exist or cannot be parsed.
    """
    job = read_job(job_file)
    if job is None:
        return None

    status = job.get("status", "idle")
    if status != "running":
        return job

    pid = int(job.get("pid", 0))
    reap(pid)

    # Read last 80 lines of runlog
    log_text = ""
    log_path = Path(runlog)
    if log_path.exists():
        lines = log_path.read_text().split("\n")
        log_text = "\n".join(lines[-80:])

    m = re.search(r"__EXIT__ (\d+)", log_text)
    if m is not None:
        status = "done" if m.group(1) == "0" else "failed"
    elif alive(pid):
        status = "running"
    else:
        status = "stopped"

    job["status"] = status
    write_job(job_file, job)
    return job


# ---------------------------------------------------------------------------
# Stop a running job
# ---------------------------------------------------------------------------

def stop(job_file: Path) -> dict | None:
    """Send SIGTERM to the process group of the job in *job_file*.

    Falls back to ``os.kill(pid, SIGTERM)`` if ``killpg`` fails (e.g. the
    process has already changed its process group).  Marks status "stopped" in
    the job json.  Returns None if *job_file* does not exist.
    """
    job = read_job(job_file)
    if job is None:
        return None

    pid = int(job.get("pid", 0))
    if pid > 0 and alive(pid):
        try:
            os.killpg(os.getpgid(pid), signal.SIGTERM)
        except Exception:
            try:
                os.kill(pid, signal.SIGTERM)
            except Exception:
                pass
        # Give the process a moment to exit, then reap so it doesn't linger
        # as a zombie (zombies still answer kill(0) as "alive").
        time.sleep(0.1)
        reap(pid)

    job["status"] = "stopped"
    write_job(job_file, job)
    return job


# ---------------------------------------------------------------------------
# Spawn helper
# ---------------------------------------------------------------------------

def with_exit_marker(cmd: str, runlog: Path) -> str:
    """Return *cmd* with ``; echo "__EXIT__ $?" >> <runlog>`` appended.

    Uses ``shlex.quote`` so the log path is safe even with spaces or special
    characters.
    """
    return f'{cmd}; echo "__EXIT__ $?" >> {shlex.quote(str(runlog))}'


def spawn_detached(cmd: str, runlog: Path, env: dict, cwd: Path) -> int:
    """Spawn *cmd* as a detached subprocess; return its pid.

    - ``shell=True`` — *cmd* is a fully-formed shell command line.
    - ``start_new_session=True`` — the child gets its own session/process group
      so ``stop()`` can signal the whole group via ``killpg``.
    - stdout + stderr → *runlog* (opened in append mode).
    - The parent's copy of the log fd is closed immediately after ``Popen``
      so the parent does not hold the file open.

    The caller is responsible for ensuring *cmd* ends with the exit marker
    (use :func:`with_exit_marker`).
    """
    log_path = Path(runlog)
    log_path.parent.mkdir(parents=True, exist_ok=True)

    logf = open(log_path, "a")
    try:
        proc = subprocess.Popen(
            cmd,
            shell=True,
            start_new_session=True,
            stdout=logf,
            stderr=subprocess.STDOUT,
            cwd=str(cwd),
            env={**os.environ, **env},
        )
    finally:
        # Close parent's copy of the fd; the child inherits its own.
        logf.close()

    return proc.pid
