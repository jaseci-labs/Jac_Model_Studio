"""studio - unit tests for the heavy-job GPU lock in jobs.sv.jac.

Covers the single-slot mutual exclusion that guarantees only one heavy local job
(JMS train / eval / generate) runs at a time on the shared GPU:
a clean acquire, the busy path (correct busy_with), release-then-reacquire, and
self-healing of a stale lock left by a crashed in-process holder.

The lock file lives at a REAL path (models.results_dir()/.heavy-lock.json), so
each test unlinks it before and after to stay hermetic and never clobber a live
lock. Annex file: pairs with jobs.sv.jac. Run with `jac test server/core/jobs.test.jac`.
"""

test "heavy_acquire succeeds on an empty slot" {
    lf = _heavy_lock_file();
    try { lf.unlink(); } except Exception {}
    g = heavy_acquire("test:a");
    assert g["ok"], g;
    try { lf.unlink(); } except Exception {}
}

test "a second heavy_acquire is busy with the current holder" {
    lf = _heavy_lock_file();
    try { lf.unlink(); } except Exception {}
    g1 = heavy_acquire("test:first");
    assert g1["ok"], g1;
    g2 = heavy_acquire("test:second");
    assert not g2["ok"], g2;
    assert g2["busy_with"] == "test:first", g2;
    try { lf.unlink(); } except Exception {}
}

test "release frees the slot for a competing holder" {
    lf = _heavy_lock_file();
    try { lf.unlink(); } except Exception {}
    assert heavy_acquire("test:holder")["ok"];
    assert not heavy_acquire("test:other")["ok"];   # blocked while held
    heavy_release("test:holder");
    g = heavy_acquire("test:other");
    assert g["ok"], g;
    try { lf.unlink(); } except Exception {}
}

test "a stale lock (dead pid, no job file) self-heals" {
    lf = _heavy_lock_file();
    try { lf.unlink(); } except Exception {}
    # A crashed in-process holder: a pid that is not alive and no job file to
    # resolve against. The next acquire must find it not-live and steal the slot.
    write_job(lf, {
        "holder": "test:dead", "job_file": "", "runlog": "",
        "pid": 999999, "stamp": "", "started": "old"
    });
    g = heavy_acquire("test:fresh");
    assert g["ok"], g;
    cur = read_job(lf);
    assert cur is not None and str(cur.get("holder", "")) == "test:fresh", cur;
    try { lf.unlink(); } except Exception {}
}

test "safe rejects bare dot tokens that name the current/parent dir" {
    # `..` as a single token passed the no-slash allowlist, so a cloud-run name of
    # ".." resolved <user_results_dir>/.. = the SHARED users/ dir (escaping the
    # per-user namespace); "." resolved the user dir itself.
    assert not safe(".."), "bare .. must be rejected";
    assert not safe("."), "bare . must be rejected";
    assert not safe("..", allow_slash=True);
    assert not safe(".", allow_slash=True);
    assert safe("a.b"), "dots inside a name stay fine";
    assert safe("..a"), "a leading-dot name that is not a dir alias stays fine";
    assert safe("x/y.jsonl", allow_slash=True);
    assert not safe("x/../y", allow_slash=True);
}
