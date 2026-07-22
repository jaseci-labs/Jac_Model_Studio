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
import models;
import from pathlib { Path }
import from signal { SIGTERM }
import from subprocess { Popen, STDOUT, PIPE }
import from threading { Lock }

# Single heavy-job (training / CPT / builder / eval / RL generate) slot: this
# box has ONE physical GPU + 48 GB, so only one heavy local job may run at a
# time. The lock file is GLOBAL across users (models.results_dir() is the shared
# root, not the per-user auth.user_results_dir()) because it guards one GPU.
glob _heavy_mutex: any = Lock();

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

"""Process start-time stamp for *pid* (`ps -o lstart=`), "" if the process is
gone. Recorded when an in-process heavy holder claims the lock; comparing it on
later liveness checks defeats pid reuse (a recycled pid has a different start
time)."""
def proc_stamp(pid: int) -> str {
    if pid <= 0 { return ""; }
    try {
        out: any = Popen(["ps", "-p", str(pid), "-o", "lstart="], stdout=PIPE, stderr=PIPE).communicate();
        return str(out[0].decode()).strip();
    } except Exception {
        return "";
    }
}

"""alive() plus the pid-reuse guard: when a stamp was recorded, the live process
must carry the same start time."""
def alive_stamped(pid: int, stamp: str) -> bool {
    if not alive(pid) { return False; }
    if not stamp { return True; }
    return proc_stamp(pid) == stamp;
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

"""Global heavy-job lock file (shared across all users — see _heavy_mutex)."""
def _heavy_lock_file() -> Path {
    return models.results_dir() / ".heavy-lock.json";
}

"""True iff the recorded lock holder is still doing work: detached holders are
resolved via live_status on their job file; in-process holders (no job file,
e.g. rl_generate inside the server) via the recorded pid+stamp."""
def _heavy_live(lock: dict) -> bool {
    jf = str(lock.get("job_file", ""));
    if jf {
        job = live_status(Path(jf), Path(str(lock.get("runlog", ""))));
        return job is not None and str(job.get("status", "")) == "running";
    }
    return alive_stamped(int(str(lock.get("pid") or 0)), str(lock.get("stamp", "")));
}

"""Claim the single heavy-job slot (training/CPT/eval/builder/RL generate all
compete for the same GPU + 48 GB). Returns {"ok": True} or {"ok": False,
"busy_with": holder}. Self-healing: a recorded holder that is no longer running
is stale and is replaced. Detached holders pass their job_file/runlog (so the
lock heals from the job file after a server restart); in-process holders pass
neither and are tracked by server pid + start-time stamp."""
def heavy_acquire(holder: str, job_file: Path | None = None, runlog: Path | None = None) -> dict {
    _heavy_mutex.acquire();
    try {
        lf = _heavy_lock_file();
        cur = read_job(lf);
        if cur is not None and _heavy_live(cur) {
            return {"ok": False, "busy_with": str(cur.get("holder", "?"))};
        }
        pid = int(os.getpid());
        write_job(lf, {
            "holder": holder,
            "job_file": str(job_file) if job_file is not None else "",
            "runlog": str(runlog) if runlog is not None else "",
            "pid": pid if job_file is None else 0,
            "stamp": proc_stamp(pid) if job_file is None else "",
            "started": time.strftime("%Y-%m-%d %H:%M:%S")
        });
        return {"ok": True};
    } finally {
        _heavy_mutex.release();
    }
}

"""Best-effort release: drop the lock if *holder* still owns it. (Stale locks
also self-heal on the next heavy_acquire, so missing a release is harmless.)"""
def heavy_release(holder: str) {
    _heavy_mutex.acquire();
    try {
        lf = _heavy_lock_file();
        cur = read_job(lf);
        if cur is not None and str(cur.get("holder", "")) == holder {
            try {
                lf.unlink();
            } except Exception {}
        }
    } finally {
        _heavy_mutex.release();
    }
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
