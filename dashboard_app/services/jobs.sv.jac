"""Training job manager: start/stop/poll SFT & DPO runs.

A run is a detached subprocess of the existing run_probe.sh / run_dpo.sh (they
are kill-safe + resumable). We never block a request on a run -- start spawns and
returns, status polls. State persists to results/<name>/.job-<mode>.json so a
later poll (a fresh request) can find the pid.

The child is launched in its own session (start_new_session) so it survives the
server and so stop can signal the whole process group (the script re-execs
caffeinate and spawns the trainer). stdout/stderr -> results/<name>/run-<mode>.log
(orchestrator progress); the trainer's own train.log is written by the script and
is what the Monitor screen charts.
"""

import json;
import os;
import re;
import shlex;
import subprocess;
import time;
import from pathlib { Path }

glob SIGTERM: int = 15;


obj JobStatus {
    has name: str,
        mode: str,
        status: str,
        pid: int,
        started: str,
        last_iter: int,
        log_tail: str,
        message: str;
}


# env knobs each script actually honours; anything else from the client is dropped.
glob SFT_KEYS: list[str] = ["EVAL_EVERY", "SUBSET", "DRY_ITERS", "SKIP_DRY", "LIVE_EVAL"];
glob DPO_KEYS: list[str] = ["DPO_ITERS", "DPO_LR", "DPO_BETA", "DPO_LAYERS", "SUBSET"];

# dataset builder stages the Ingest screen may run (maps stage -> <stage>.jac).
glob BUILDERS: list[str] = [
    "seed_conversion", "idiomatic_batch", "idiomatic_batch2", "idiomatic_batch3",
    "scale_conversion", "dpo_conversion", "build_manifest", "build_splits",
    "build_dpo_splits", "holdout", "graph_holdout", "dataset_stats", "verify_dataset",
];


def _root() -> str {
    # Absolute so the server's open() and the child shell's `cwd`/redirects agree
    # regardless of where each runs.
    if Path("results").exists() { return str(Path(".").resolve()); }
    if Path("../results").exists() { return str(Path("..").resolve()); }
    return str(Path(os.environ.get("DG_ROOT", "..")).resolve());
}


def _safe(s: str, allow_slash: bool) -> bool {
    # Strict allowlist -- these values reach a shell command line.
    if s == "" { return False; }
    if allow_slash {
        return re.fullmatch("[A-Za-z0-9_./-]+", s) is not None;
    }
    return re.fullmatch("[A-Za-z0-9_.-]+", s) is not None;
}


def _job_path(name: str, mode: str) -> str {
    return _root() + "/results/" + name + "/.job-" + mode + ".json";
}


def _run_log(name: str, mode: str) -> str {
    return _root() + "/results/" + name + "/run-" + mode + ".log";
}


def _read_job(name: str, mode: str) -> dict {
    p = Path(_job_path(name, mode));
    if not p.exists() { return {}; }
    try {
        return dict(json.loads(p.read_text()));
    } except Exception {
        return {};
    }
}


def _write_job(name: str, mode: str, data: dict) -> None {
    p = Path(_job_path(name, mode));
    p.parent.mkdir(parents=True, exist_ok=True);
    p.write_text(json.dumps(data));
}


def _reap(pid: int) -> None {
    # The server is the subprocess parent; reap exited children so they don't
    # linger as zombies (a zombie still answers os.kill(pid, 0) -> "alive").
    try {
        os.waitpid(pid, os.WNOHANG);
    } except Exception {
        return;
    }
}


def _alive(pid: int) -> bool {
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


def _tail(path: str, n: int) -> str {
    p = Path(path);
    if not p.exists() { return ""; }
    lines: list = p.read_text().split("\n");
    start: int = 0;
    if len(lines) > n { start = len(lines) - n; }
    return "\n".join(lines[start:]);
}


def _last_iter(name: str, mode: str) -> int {
    if mode == "dpo" {
        log: str = _root() + "/results/" + name + "/dpo/train.log";
    } else {
        log: str = _root() + "/results/" + name + "/train.log";
    }
    p = Path(log);
    if not p.exists() { return 0; }
    last: int = 0;
    for m in re.finditer("Iter (\\d+)", p.read_text()) {
        v: int = int(str(m.group(1)));
        if v > last { last = v; }
    }
    return last;
}


def _live_status(name: str, mode: str) -> str {
    # Recompute live status from the persisted job + pid liveness + exit marker.
    # "idle" = no job for this (name, mode).
    job: dict = _read_job(name, mode);
    if len(job) == 0 { return "idle"; }
    status: str = str(job.get("status", "idle"));
    if status != "running" { return status; }
    pid: int = int(job.get("pid", 0));
    _reap(pid);
    # The exit marker is authoritative (a finished child may still be a zombie
    # that reads as alive); fall back to pid liveness only without one.
    m = re.search("__EXIT__ (\\d+)", _tail(_run_log(name, mode), 80));
    if m is not None {
        status = "done" if str(m.group(1)) == "0" else "failed";
    } elif _alive(pid) {
        status = "running";
    } else {
        status = "stopped";
    }
    job["status"] = status;
    _write_job(name, mode, job);
    return status;
}


def _status_obj(name: str, mode: str, message: str) -> JobStatus {
    job: dict = _read_job(name, mode);
    pid: int = int(job.get("pid", 0));
    status: str = _live_status(name, mode);
    runlog: str = _run_log(name, mode);
    return JobStatus(
        name=name,
        mode=mode,
        status=status,
        pid=pid,
        started=str(job.get("started", "")),
        last_iter=_last_iter(name, mode),
        log_tail=_tail(runlog, 40),
        message=message,
    );
}


def:pub job_status(name: str, mode: str) -> JobStatus {
    if not _safe(name, False) { return _status_obj(name, mode, "bad name"); }
    return _status_obj(name, mode, "");
}


obj Session {
    has name: str,
        mode: str,
        status: str,
        last_iter: int,
        started: str,
        label: str;
}


def:pub list_sessions() -> list[Session] {
    # Every (name, mode) training session in results/, with live status.
    # status: running | done | failed | stopped | finished (a CLI run with a log
    # but no job file). The UI splits these into live (Monitor) vs past (History).
    out: list[Session] = [];
    base = Path(_root() + "/results");
    if not base.exists() { return out; }
    for child in sorted(base.iterdir()) {
        if not child.is_dir() { continue; }
        if child.name == "comparison" or child.name == "_builder" { continue; }
        nm: str = child.name;
        for mode in ["sft", "dpo"] {
            if mode == "dpo" {
                logp: str = str(child) + "/dpo/train.log";
            } else {
                logp: str = str(child) + "/train.log";
            }
            has_log: bool = Path(logp).exists();
            job: dict = _read_job(nm, mode);
            if not has_log and len(job) == 0 { continue; }
            st: str = _live_status(nm, mode);
            if st == "idle" { st = "finished"; }
            out.append(Session(
                name=nm,
                mode=mode,
                status=st,
                last_iter=_last_iter(nm, mode),
                started=str(job.get("started", "")),
                label=nm + " · " + mode.upper(),
            ));
        }
    }
    return out;
}


def:pub builder_status(stage: str) -> JobStatus {
    if stage not in BUILDERS { return _status_obj("_builder", stage, "unknown builder"); }
    return _status_obj("_builder", stage, "");
}


def:pub run_builder(stage: str) -> JobStatus {
    # Spawn `jac run srccurrent/jacgen/<stage>.jac` as a tracked job (name "_builder").
    if stage not in BUILDERS { return _status_obj("_builder", stage, "unknown builder"); }
    existing: dict = _read_job("_builder", stage);
    if str(existing.get("status", "")) == "running" and _alive(int(existing.get("pid", 0))) {
        return _status_obj("_builder", stage, "already running");
    }
    base: str = _root();
    Path(base + "/results/_builder").mkdir(parents=True, exist_ok=True);
    runlog: str = _run_log("_builder", stage);
    env: dict = dict(os.environ);
    env["PATH"] = base + "/.venv/bin:" + str(env.get("PATH", ""));
    target: str = "srccurrent/jacgen/" + stage + ".jac";
    cmd: str = "jac run " + shlex.quote(target) + "; echo \"__EXIT__ $?\" >> " + shlex.quote(runlog);
    logf = open(runlog, "a");
    proc = subprocess.Popen(
        cmd, shell=True, cwd=base, env=env,
        stdout=logf, stderr=subprocess.STDOUT, start_new_session=True,
    );
    _write_job("_builder", stage, {
        "name": "_builder", "mode": stage, "pid": proc.pid, "status": "running",
        "started": time.strftime("%Y-%m-%d %H:%M:%S"), "cmd": "jac run " + target,
    });
    return _status_obj("_builder", stage, "started");
}


def:pub stop_training(name: str, mode: str) -> JobStatus {
    if not _safe(name, False) { return _status_obj(name, mode, "bad name"); }
    job: dict = _read_job(name, mode);
    pid: int = int(job.get("pid", 0));
    if pid > 0 and _alive(pid) {
        try {
            os.killpg(os.getpgid(pid), SIGTERM);
        } except Exception as e {
            os.kill(pid, SIGTERM);
        }
        job["status"] = "stopped";
        _write_job(name, mode, job);
        return _status_obj(name, mode, "stop signal sent");
    }
    return _status_obj(name, mode, "no live process");
}


def:pub start_training(model_id: str, name: str, mode: str, opts: dict) -> JobStatus {
    # Validate everything that reaches the shell.
    if not _safe(name, False) { return _status_obj(name, mode, "invalid name"); }
    if mode != "sft" and mode != "dpo" { return _status_obj(name, mode, "mode must be sft|dpo"); }
    if mode == "sft" and not _safe(model_id, True) {
        return _status_obj(name, mode, "invalid model id");
    }

    # already running?
    existing: dict = _read_job(name, mode);
    if str(existing.get("status", "")) == "running" and _alive(int(existing.get("pid", 0))) {
        return _status_obj(name, mode, "already running");
    }

    base: str = _root();
    Path(base + "/results/" + name).mkdir(parents=True, exist_ok=True);
    runlog: str = _run_log(name, mode);

    # whitelist env overrides.
    keys: list = SFT_KEYS if mode == "sft" else DPO_KEYS;
    env: dict = dict(os.environ);
    for k in keys {
        if k in opts {
            val: str = str(opts[k]);
            if _safe(val, False) { env[k] = val; }
        }
    }

    if mode == "sft" {
        inner: str = "./run_probe.sh " + shlex.quote(model_id) + " " + shlex.quote(name);
    } else {
        inner: str = "./run_dpo.sh " + shlex.quote(name);
    }
    # append an exit marker so a later poll can tell done vs failed.
    cmd: str = inner + "; echo \"__EXIT__ $?\" >> " + shlex.quote(runlog);

    logf = open(runlog, "a");
    # shell=True (str arg) + strict-validated/quoted inputs; new session so stop
    # can signal the whole group (script re-execs caffeinate + spawns the trainer).
    proc = subprocess.Popen(
        cmd,
        shell=True,
        cwd=base,
        env=env,
        stdout=logf,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    );
    _write_job(name, mode, {
        "name": name, "mode": mode, "pid": proc.pid, "status": "running",
        "started": time.strftime("%Y-%m-%d %H:%M:%S"), "cmd": inner,
    });
    return _status_obj(name, mode, "started");
}
