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
import from pathlib { Path }
import from signal { SIGTERM }
import from subprocess { Popen, STDOUT, PIPE }
import from uuid { uuid4 }

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

"""Process start-time stamp for *pid* (`ps -o lstart=`), "" if the process is
gone. Stored in the job JSON at spawn; comparing it on later liveness checks
defeats pid reuse (a recycled pid has a different start time)."""
def proc_stamp(pid: int) -> str {
    if pid <= 0 { return ""; }
    try {
        out: any = Popen(["ps", "-p", str(pid), "-o", "lstart="], stdout=PIPE, stderr=PIPE).communicate();
        return str(out[0].decode()).strip();
    } except Exception {
        return "";
    }
}

"""alive() plus the pid-reuse guard: when the job recorded a stamp, the live
process must carry the same start time."""
def alive_stamped(pid: int, stamp: str) -> bool {
    if not alive(pid) { return False; }
    if not stamp { return True; }
    return proc_stamp(pid) == stamp;
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
    # Atomic write: pollers read this file concurrently; a plain write_text can
    # be observed half-written and momentarily flip the run to idle/finished.
    job_file.parent.mkdir(parents=True, exist_ok=True);
    tmp = job_file.parent / (job_file.name + ".tmp");
    tmp.write_text(json.dumps(job));
    os.replace(str(tmp), str(job_file));
}

"""Exit code from the run log. run_id-scoped markers (`__EXIT__ <run_id> n`) can
never be credited to a different run; the anchored legacy form (`__EXIT__ n`) is
accepted only for jobs launched before run ids existed."""
def _exit_code(log_text: str, run_id: str = "") -> int {
    m: any = None;
    if run_id {
        m = re.search(rf"^__EXIT__ {run_id} (\d+)$", log_text, re.MULTILINE);
    } else {
        m = re.search(r"^__EXIT__ (\d+)$", log_text, re.MULTILINE);
    }
    if m is None { return -1; }
    return int(str(m.group(1)));
}

"""Refresh a running job's status from the last 80 log lines (`__EXIT__ n` →
done/failed) else pid liveness (alive+stamp → running, dead → stopped). Persists
back to *job_file* only when the status changed. None if the file is missing."""
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
    code = _exit_code(log_text, str(job.get("run_id", "")));
    if code == 0 {
        status = "done";
    } elif code > 0 {
        status = "failed";
    } elif alive_stamped(pid, str(job.get("stamp", ""))) {
        status = "running";
    } else {
        status = "stopped";
    }
    if status != str(job.get("status", "")) {
        job["status"] = status;
        write_job(job_file, job);
    }
    return job;
}

"""SIGTERM the job's process group (killpg, falling back to kill). Refreshes via
*runlog* first when supplied so a finished job isn't killed. No-op on terminal
jobs. When *run_id* is given and the job file holds a different run, nothing is
signalled and the job is returned with status "superseded" (not persisted) — the
caller launched a run that has since been replaced and must not kill the new one."""
def stop(job_file: Path, runlog: Path | None = None, run_id: str = "") -> dict | None {
    job: dict | None = None;
    if runlog is not None {
        job = live_status(job_file, runlog);
    } else {
        job = read_job(job_file);
    }
    if job is None { return None; }
    if run_id and str(job.get("run_id", "")) != run_id {
        return {**job, "status": "superseded"};
    }
    status = str(job.get("status", "idle"));
    if status != "running" { return job; }
    pid = int(str(job.get("pid") or 0));
    if pid > 0 and alive_stamped(pid, str(job.get("stamp", ""))) {
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

"""Append `; echo "__EXIT__ [<run_id>] $?" >> <runlog>` (shell-quoted) to *cmd*."""
def with_exit_marker(cmd: str, runlog: Path, run_id: str = "") -> str {
    tag = f"__EXIT__ {run_id}" if run_id else "__EXIT__";
    return f'{cmd}; echo "{tag} $?" >> {shlex.quote(str(runlog))}';
}

"""The one way to start a detached job: mint a run_id, truncate the runlog (so a
prior run's marker can't be misread), spawn with a run-scoped exit marker, stamp
the pid, and atomically persist {**meta, run_id, pid, stamp, status, started,
cmd}. Returns the job dict."""
def launch(job_file: Path, runlog: Path, inner_cmd: str, env: dict, cwd: Path, meta: dict) -> dict {
    run_id = str(uuid4().hex)[:8];
    runlog.parent.mkdir(parents=True, exist_ok=True);
    runlog.write_text("");
    cmd = with_exit_marker(inner_cmd, runlog, run_id);
    pid = spawn_detached(cmd, runlog=runlog, env=env, cwd=cwd);
    job = {
        **meta,
        "run_id": run_id,
        "pid": pid,
        "stamp": proc_stamp(pid),
        "status": "running",
        "started": time.strftime("%Y-%m-%d %H:%M:%S"),
        "cmd": inner_cmd
    };
    write_job(job_file, job);
    return job;
}

"""Spawn *cmd* (shell) detached in its own session/process group, stdout+stderr →
*runlog* (append), with os.environ + *env*. Returns the child pid. Caller must
append the exit marker (use with_exit_marker)."""
def spawn_detached(cmd: str, runlog: Path, env: dict, cwd: Path) -> int {
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
    return int(str(proc.pid));
}
