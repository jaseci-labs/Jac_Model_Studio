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
import metrics;
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

"""Persist *job* as JSON. Written to a per-pid sibling `.tmp` and moved into place
with os.replace, which is atomic on a POSIX filesystem: a concurrent read_job now
sees either the previous job or the new one, never the half-written file that used
to make a live job look missing (`read_job` → None → "job vanished").
# ponytail: ceiling — atomic VISIBILITY only, no fsync. A power cut can still lose
# the last status write; live_status rewrites the job file on every poll, so an
# fsync here would put a disk flush on the status-polling hot path for a file that
# is rebuilt from the run log anyway."""
def write_job(job_file: Path, job: dict) {
    job_file.parent.mkdir(parents=True, exist_ok=True);
    tmp = job_file.parent / f".{job_file.name}.{os.getpid()}.tmp";
    tmp.write_text(json.dumps(job));
    os.replace(str(tmp), str(job_file));
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
    # Bounded backwards read — identical to the old read_text().split("\n")[-80:]
    # join, but a 400 MB training log no longer gets decoded on every status poll.
    log_text = metrics.tail(runlog, 80);
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

"""Sibling mutex file for the heavy-lock read-check-write critical section. Held
for microseconds; it is NOT the holder record (that stays .heavy-lock.json)."""
def _heavy_guard_file() -> Path {
    return models.results_dir() / ".heavy-lock.guard";
}

# A guard older than this is assumed abandoned (the section it protects is a
# couple of file reads). Belt-and-braces next to the pid liveness check below:
# together they guarantee a crashed process can never deadlock the heavy slot.
glob _GUARD_STALE_SEC: float = 15.0;

"""True iff an existing guard file was abandoned — its recorded pid is dead, or it
is older than _GUARD_STALE_SEC. A vanished guard is NOT stale (the create will
just be retried)."""
def _guard_stale(guard: Path) -> bool {
    st: any = None;
    try {
        st = guard.stat();
    } except Exception {
        return False;
    }
    if (time.time() - float(str(st.st_mtime))) > _GUARD_STALE_SEC { return True; }
    txt = "";
    try {
        txt = guard.read_text().strip();
    } except Exception {
        return False;
    }
    if not txt { return False; }
    holder_pid = 0;
    try {
        holder_pid = int(str(txt));
    } except Exception {
        return False;
    }
    return not alive(holder_pid);
}

"""Take the cross-PROCESS guard. os.open(O_CREAT|O_EXCL) is the real primitive:
the kernel lets exactly one process create the file, so only one server process at
a time runs the heavy-lock check-then-write. Returns False if it could not be
taken within *timeout* (or the directory is unwritable) — callers then proceed
anyway, degrading to the old in-process-only behaviour rather than blocking a
training start."""
def _guard_acquire(guard: Path, timeout: float = 2.0) -> bool {
    deadline = time.time() + timeout;
    while True {
        try {
            fd = os.open(str(guard), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644);
            try {
                os.write(fd, str(os.getpid()).encode());
            } except Exception {}
            os.close(fd);
            return True;
        } except FileExistsError {
            if _guard_stale(guard) {
                try { os.unlink(str(guard)); } except Exception {}
                continue;
            }
        } except Exception {
            return False;
        }
        if time.time() >= deadline { return False; }
        time.sleep(0.02);
    }
    return False;
}

"""Drop the guard (best effort — a leaked guard self-heals via _guard_stale)."""
def _guard_release(guard: Path) -> None {
    try {
        guard.unlink();
    } except Exception {}
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
neither and are tracked by server pid + start-time stamp.

The read-check-write is serialised twice: `_heavy_mutex` between threads of one
server, and the O_EXCL guard file between server PROCESSES (a threading.Lock is
per-interpreter, so two `jac start` processes could previously both find the slot
free and both claim it). Both are released on every path, and the guard self-heals
(dead pid / age) so a crashed process cannot wedge the slot shut.
# ponytail: ceiling — unchanged pre-existing window between claiming the slot and
# the spawned job's status reaching "running": during it a detached holder's
# job_file does not yet say running, so _heavy_live reads it as stale. Narrowing
# that needs a job-file state machine, not a lock change."""
def heavy_acquire(holder: str, job_file: Path | None = None, runlog: Path | None = None) -> dict {
    _heavy_mutex.acquire();
    try {
        lf = _heavy_lock_file();
        lf.parent.mkdir(parents=True, exist_ok=True);
        guard = _heavy_guard_file();
        got = _guard_acquire(guard);
        try {
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
            if got { _guard_release(guard); }
        }
    } finally {
        _heavy_mutex.release();
    }
}

"""Best-effort release: drop the lock if *holder* still owns it. (Stale locks
also self-heal on the next heavy_acquire, so missing a release is harmless.)"""
def heavy_release(holder: str) {
    _heavy_mutex.acquire();
    try {
        guard = _heavy_guard_file();
        # Same guard as heavy_acquire so a release can't land between a competing
        # process's read and its write (which would drop the NEW holder's lock).
        got = _guard_acquire(guard);
        try {
            lf = _heavy_lock_file();
            cur = read_job(lf);
            if cur is not None and str(cur.get("holder", "")) == holder {
                try {
                    lf.unlink();
                } except Exception {}
            }
        } finally {
            if got { _guard_release(guard); }
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

"""Read-only cross-app job snapshot for the global activity indicator in the top
bar. The app launches multi-hour detached GPU jobs and the user moves between 4
workspaces and 2 surfaces, so without this there is no signal that anything is
running once you navigate away from the section that started it.

Reuses the existing helpers only — no new state, no writes, and it never touches
the heavy lock's guard file (so it cannot contend with a real acquire).
`heavy` is the current holder's label, "" when the GPU slot is free.
# ponytail: ceiling — `running` rglob's the caller's results tree (same cost as
# the pre-existing `_count_running_jobs`), so poll it on the order of seconds, not
# continuously. If the tree grows enough to matter, keep a counter in the lock file."""
def active_jobs() -> dict {
    running = 0;
    try {
        running = _count_running_jobs();
    } except Exception { running = 0; }
    heavy = "";
    try {
        cur = read_job(_heavy_lock_file());
        if cur is not None and _heavy_live(cur) {
            heavy = str(cur.get("holder", ""));
        }
    } except Exception { heavy = ""; }
    return {"running": running, "heavy": heavy};
}
