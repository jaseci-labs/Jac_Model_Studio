"""studio - detached-process job lifecycle. Ports server/procs.py.

Job JSON files are the source of truth and survive server restarts; the `__EXIT__`
marker appended to the run log is authoritative over pid liveness (children get
reparented after a restart, so waitpid fails silently and zombies still answer
kill-0). Internal helpers consumed by train/evals/builders .sv.jac — plain `def`.

Checker notes (jaclang 0.16.1): import native symbols directly (signal.SIGTERM,
subprocess.Popen) to dodge Unknown submodule access; dict/JSON values are `any`, so
`int(str(...))` for the pid; `SIGTERM` is a Final enum → `int(SIGTERM)` for os.kill.
"""

import json;
import os;
import re;
import shlex;
import time;
import auth;
import audit;
import from pathlib { Path }
import from signal { SIGTERM }
import from subprocess { Popen, STDOUT }

"""True iff *s* is safe to embed in a shell command. Allowlist [A-Za-z0-9_.-]
(plus / when allow_slash); any `..` path segment is always rejected."""
def safe(s: str, allow_slash: bool = False) -> bool {
    if not s { return False; }
    if allow_slash {
        for segment in s.split("/") {
            if segment == ".." { return False; }
        }
        return re.fullmatch(r"[A-Za-z0-9_./-]+", s) is not None;
    }
    return re.fullmatch(r"[A-Za-z0-9_.-]+", s) is not None;
}

"""True iff process *pid* is alive (os.kill(pid, 0); PermissionError → alive)."""
def alive(pid: int) -> bool {
    if pid <= 0 { return False; }
    try {
        os.kill(pid, 0);
        return True;
    } except ProcessLookupError {
        return False;
    } except PermissionError {
        return True;
    } except Exception {
        return False;
    }
}

"""Reap a finished direct child (non-blocking); ignore non-children / reaped pids."""
def reap(pid: int) -> None {
    try {
        os.waitpid(pid, os.WNOHANG);
    } except Exception {
        return;
    }
}

"""Max detached jobs per user (running). Override via JAC_MAX_CONCURRENT_JOBS."""
def _max_concurrent_jobs() -> int {
    try {
        return int(str(os.environ.get("JAC_MAX_CONCURRENT_JOBS", "3")));
    } except Exception {
        return 3;
    }
}

"""Count job.json / .job-*.json files with status=running under caller's tree."""
def _count_running_jobs() -> int {
    base = auth.user_results_dir();
    if not base.exists() { return 0; }
    n = 0;
    for jf in base.rglob("*.json") {
        if "job" not in jf.name { continue; }
        job = read_job(jf);
        if job is None { continue; }
        if str(job.get("status", "")) == "running" { n += 1; }
    }
    return n;
}

def read_job(job_file: Path) -> dict | None {
    if not job_file.exists() { return None; }
    try {
        return dict(json.loads(job_file.read_text()));
    } except Exception {
        return None;
    }
}

def write_job(job_file: Path, job: dict) {
    job_file.parent.mkdir(parents=True, exist_ok=True);
    job_file.write_text(json.dumps(job));
}

def _exit_code(log_text: str) -> int {
    m: any = re.search(r"__EXIT__ (\d+)", log_text);
    if m is None { return -1; }
    return int(str(m.group(1)));
}

"""Refresh a running job's status from the last 80 log lines (`__EXIT__ n` →
done/failed) else pid liveness (alive → running, dead → stopped). Persists the
resolved status back to *job_file*. None if the file is missing/unparseable."""
def live_status(job_file: Path, runlog: Path) -> dict | None {
    job = read_job(job_file);
    if job is None { return None; }
    status = str(job.get("status", "idle"));
    if status != "running" { return job; }
    pid = int(str(job.get("pid") or 0));
    reap(pid);
    log_text = "";
    if runlog.exists() {
        lines = runlog.read_text().split("\n");
        log_text = "\n".join(lines[-80:]);
    }
    code = _exit_code(log_text);
    if code == 0 {
        status = "done";
    } elif code > 0 {
        status = "failed";
    } elif alive(pid) {
        status = "running";
    } else {
        status = "stopped";
    }
    job["status"] = status;
    write_job(job_file, job);
    return job;
}

"""SIGTERM the job's process group (killpg, falling back to kill). Refreshes via
*runlog* first when supplied so a finished job isn't killed. No-op on terminal jobs."""
def stop(job_file: Path, runlog: Path | None = None) -> dict | None {
    job: dict | None = None;
    if runlog is not None {
        job = live_status(job_file, runlog);
    } else {
        job = read_job(job_file);
    }
    if job is None { return None; }
    status = str(job.get("status", "idle"));
    if status != "running" { return job; }
    pid = int(str(job.get("pid") or 0));
    if pid > 0 and alive(pid) {
        try {
            os.killpg(os.getpgid(pid), int(SIGTERM));
        } except Exception {
            try {
                os.kill(pid, int(SIGTERM));
            } except Exception {}
        }
        time.sleep(0.1);
        reap(pid);
    }
    job["status"] = "stopped";
    write_job(job_file, job);
    return job;
}

"""Append `; echo "__EXIT__ $?" >> <runlog>` (shell-quoted) to *cmd*."""
def with_exit_marker(cmd: str, runlog: Path) -> str {
    return f'{cmd}; echo "__EXIT__ $?" >> {shlex.quote(str(runlog))}';
}

"""Spawn *cmd* (shell) detached in its own session/process group, stdout+stderr →
*runlog* (append), with os.environ + *env*. Returns the child pid. Caller must
append the exit marker (use with_exit_marker). Enforces per-user concurrent job cap."""
def spawn_detached(cmd: str, runlog: Path, env: dict, cwd: Path) -> int {
    if _count_running_jobs() >= _max_concurrent_jobs() {
        raise ValueError("concurrent job limit reached");
    }
    runlog.parent.mkdir(parents=True, exist_ok=True);
    logf: any = open(runlog, "a");
    proc: any = None;
    try {
        proc = Popen(
            cmd, shell=True, start_new_session=True,
            stdout=logf, stderr=STDOUT, cwd=str(cwd), env={**os.environ, **env}
        );
    } finally {
        logf.close();
    }
    pid = int(str(proc.pid));
    audit.log("job_spawn", {"pid": pid, "cwd": str(cwd), "runlog": str(runlog)});
    return pid;
}
