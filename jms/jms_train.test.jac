"""studio - tests for jms_train.sv.jac (guards, data split, cmd + status mapping).

No real training: every test fabricates on-disk state (train.jsonl, run.log +
job.json, a CloudRun node + status.json) and exercises the pure pieces —
start_train's refusals, _prepare_data's holdout-empty split, _mlx_config flag/path
construction, and the unified train_status mapping for both a finished local job
and a fabricated spheron status.json.

Shares a persisted root (jac-testing) — each test isolates the workspace to a temp
dir so nothing lands in the repo. Run with `jac test jms_train.test.jac`.
"""

import os;
import tempfile;
import from jms_projects { create_project }
import from cloudruns { CloudRun }

def _isolate_ws -> None {
    os.environ["JAC_STUDIO_WORKSPACE"] = tempfile.mkdtemp(prefix="studio-jmstrain-");
    os.environ["JAC_STUDIO_DATA_ROOT"] = os.environ["JAC_STUDIO_WORKSPACE"];
}

"""Write *n* well-formed sft-chat rows into the project's dataset/train.jsonl."""
def _write_train(slug: str, n: int) -> None {
    d = jms_project_dir(slug) / "dataset";
    d.mkdir(parents=True, exist_ok=True);
    rows: list[str] = [];
    i = 0;
    while i < n {
        rows.append('{"messages": [{"role": "user", "content": "q' + str(i) + '"}, {"role": "assistant", "content": "a' + str(i) + '"}]}');
        i += 1;
    }
    (d / "train.jsonl").write_text("\n".join(rows) + "\n");
    (d / "holdout.jsonl").write_text("");   # empty → split path exercised
}

test "start_train refuses unknown project, unknown backend, and no train split" {
    _isolate_ws();
    r0 = start_train("no-such-pid", "local-mlx", "qwen-q4", {});
    assert not bool(r0["ok"]) and "unknown project" in str(r0["error"]), r0;

    v = create_project("Train Guards", "test");
    rb = start_train(v.pid, "bogus-backend", "qwen-q4", {});
    assert not bool(rb["ok"]) and "backend must be" in str(rb["error"]), rb;

    rn = start_train(v.pid, "local-mlx", "qwen-q4", {});
    assert not bool(rn["ok"]) and "materialize" in str(rn["error"]), rn;
}

test "start_train refuses when a run is already training" {
    _isolate_ws();
    v = create_project("Train Busy", "test");
    _write_train(v.slug, 3);
    p = _find_project(v.pid);
    rid = "busy0001";
    rd = _run_dir(p, rid);
    rd.mkdir(parents=True, exist_ok=True);
    _run_log(p, rid).write_text("");   # no __EXIT__ marker → still running
    jobs.write_job(_job_file(p, rid), {
        "name": "jmstrain-" + rid, "mode": "jms_train",
        "pid": int(os.getpid()),   # this live process → jobs.alive True
        "status": "running", "started": "t"
    });
    p ++> JmsTrainRun(
        rid=rid, backend="local-mlx", base_model="qwen-q4", status="running",
        cfg_json='{"iters": 10}', adapter_path=str(_adapter_dir(p, rid)), started="t"
    );
    r = start_train(v.pid, "local-mlx", "qwen-q4", {});
    assert not bool(r["ok"]) and "already training" in str(r["error"]), r;
}

test "start_train spheron refuses without a cluster_id" {
    _isolate_ws();
    v = create_project("Train No Cluster", "test");
    _write_train(v.slug, 3);
    # opts carries no cluster_id → refused before any cloudruns delegation.
    r = start_train(v.pid, "spheron", "hf/some-model", {});
    assert not bool(r["ok"]) and "cluster_id required" in str(r["error"]), r;
    # an unknown cluster_id gets as far as cloudruns, which can't resolve it.
    r2 = start_train(v.pid, "spheron", "hf/some-model", {"cluster_id": "no-such-cluster"});
    assert not bool(r2["ok"]) and "CLUSTERS tab" in str(r2["error"]), r2;
}

test "_prepare_data reserves last 10% (min 1) of train as valid when holdout empty" {
    _isolate_ws();
    v = create_project("Train Split", "test");
    _write_train(v.slug, 3);
    p = _find_project(v.pid);
    prep = _prepare_data(p, "split01");
    assert int(str(prep["train"])) == 3, prep;
    assert int(str(prep["valid"])) == 1, prep;   # max(1, 3*10//100) == 1
    assert bool(prep["split_from_train"]), prep;
    dd = _data_dir(p, "split01");
    assert (dd / "train.jsonl").exists() and (dd / "valid.jsonl").exists(), prep;
    vlines = [ln for ln in (dd / "valid.jsonl").read_text().split("\n") if ln.strip()];
    assert len(vlines) == 1, vlines;
}

test "_mlx_config builds the right flags, paths, and LoRA params" {
    cfg = _mlx_config("/models/base", "/runs/x/data", "/runs/x/adapter",
                      {"iters": 25, "batch_size": 2, "learning_rate": "2e-4", "lora_r": 16, "lora_alpha": 32});
    assert str(cfg["model"]) == "/models/base", cfg;
    assert str(cfg["data"]) == "/runs/x/data", cfg;
    assert str(cfg["adapter_path"]) == "/runs/x/adapter", cfg;
    assert bool(cfg["train"]) and str(cfg["fine_tune_type"]) == "lora", cfg;
    assert int(str(cfg["iters"])) == 25 and int(str(cfg["batch_size"])) == 2, cfg;
    assert float(str(cfg["learning_rate"])) == 2e-4, cfg;
    # eval/save pinned to iters so tiny sets never trip a mid-run eval
    assert int(str(cfg["steps_per_eval"])) == 25 and int(str(cfg["save_every"])) == 25, cfg;
    lp = dict(cfg["lora_parameters"]);
    assert int(str(lp["rank"])) == 16 and float(str(lp["scale"])) == 32.0, lp;
    # defaults when opts omitted
    d = _mlx_config("/m", "/d", "/a", {});
    assert int(str(d["iters"])) == DEFAULT_ITERS and int(str(d["batch_size"])) == DEFAULT_BATCH, d;
}

test "status maps: local job.json __EXIT__ 0 → completed with parsed metrics" {
    _isolate_ws();
    v = create_project("Train Local Status", "test");
    p = _find_project(v.pid);
    rid = "loc00001";
    rd = _run_dir(p, rid);
    rd.mkdir(parents=True, exist_ok=True);
    _run_log(p, rid).write_text(
        "Iter 1: Train loss 2.500, Learning Rate 1.000e-05, It/sec 1.0, Tokens/sec 100.0\n"
        + "Iter 2: Train loss 2.100, Learning Rate 1.000e-05\n"
        + "Iter 2: Val loss 2.300\n"
        + "__EXIT__ 0\n"
    );
    jobs.write_job(_job_file(p, rid), {
        "name": "jmstrain-" + rid, "mode": "jms_train", "pid": 999999,
        "status": "running", "started": "t"
    });
    p ++> JmsTrainRun(
        rid=rid, backend="local-mlx", base_model="qwen-q4", status="running",
        cfg_json='{"iters": 2}', adapter_path=str(_adapter_dir(p, rid)), started="t"
    );
    st = train_status(v.pid, rid);
    assert str(st["status"]) == "completed", st;
    assert len(list(st["metrics"])) == 2, st;
    assert len(list(st["val_metrics"])) == 1, st;
    assert int(str(dict(st["progress"])["last_iter"])) == 2, st;
    assert int(str(dict(st["progress"])["total_iters"])) == 2, st;
    # node synced to terminal
    r = _find_run(p, rid);
    assert r.status == "completed" and r.finished, r.status;
}

test "status maps: spheron status.json done → completed with cost/phase/metrics" {
    _isolate_ws();
    v = create_project("Train Cloud Status", "test");
    p = _find_project(v.pid);
    rid = "cld00001";
    name = _cloud_name(p, rid);
    cdir = _cloud_dir(p, rid);
    cdir.mkdir(parents=True, exist_ok=True);
    (cdir / "status.json").write_text(
        '{"phase": "finalize", "status": "done", "deployment_id": "dep-1",'
        + ' "cost": {"hourly_rate": 0.35, "elapsed_usd": 0.12, "terminated_at": ""},'
        + ' "progress": {"pct": 100, "step": 2, "max_steps": 2},'
        + ' "artifacts": {"pulled": true, "adapter_dir": "adapter", "bytes": 10},'
        + ' "vm_terminated": false, "heartbeat": ""}'
    );
    (cdir / "metrics.jsonl").write_text(
        '{"step": 1, "loss": 2.0, "eval_loss": 2.1}\n{"step": 2, "loss": 1.5, "eval_loss": 1.6}\n'
    );
    adir = cdir / "adapter";
    adir.mkdir(parents=True, exist_ok=True);
    (adir / "adapter_model.safetensors").write_text("blob");

    root ++> CloudRun(
        run_id="cr-1", name=name, mode="sft", backend="spheron_gpu",
        deployment_id="dep-1", hourly_rate=0.35, supervisor_pid=0,
        created="t", status="running"
    );
    p ++> JmsTrainRun(
        rid=rid, backend="spheron", base_model="hf/some-model", status="running",
        cfg_json='{"iters": 2}', adapter_path="", cloud_run_id="cr-1", started="t"
    );
    st = train_status(v.pid, rid);
    assert str(st["status"]) == "completed", st;
    assert str(st["phase"]) == "finalize", st;
    assert float(str(dict(st["cost"])["hourly_rate"])) == 0.35, st;
    assert len(list(st["metrics"])) == 2, st;
    assert len(list(st["val_metrics"])) == 2, st;
    assert bool(st["adapter_ready"]), st;
    r = _find_run(p, rid);
    assert r.status == "completed" and r.adapter_path, r.status;
}

test "map helpers normalize backend statuses" {
    assert _map_local("done") == "completed";
    assert _map_local("failed") == "failed";
    assert _map_local("running") == "running";
    assert _map_cloud("done") == "completed";
    assert _map_cloud("detached") == "running";   # still billing → treat as running
    assert _map_cloud("stopped") == "stopped";
}
