"""studio - unit tests for cloudruns.sv.jac (supervised remote GPU runs).

Covers the pure pieces the supervisor contract depends on: runspec
construction (uploads/pull/policy), the detached computation (fabricated
status dict + dead/live pids), opts→CLI-flag rendering, dataset default
resolution from [cloudrun], and start_remote_run's validation gate (which
must reject bad cfgs before any Spheron call or supervisor spawn). No
supervisors or deployments are created. Run with `jac test cloudruns.sv.jac`.
"""

import os;
import time;

test "runspec construction: uploads/pull/policy/remote_dir from cfg" {
    cfg: dict = {
        "name": "t-run",
        "mode": "sft",
        "base_model": "org/model",
        "policy": {"auto_terminate": "never", "max_wall_clock_min": 60},
        "ssh_override": "ssh test@fakehost"
    };
    spec = _build_runspec(cfg, "rid-1", "dep-1", 0.35, "bash fake_train.sh");
    assert str(spec["run_id"]) == "rid-1";
    assert str(spec["name"]) == "t-run";
    assert str(spec["mode"]) == "sft";
    assert str(spec["deployment_id"]) == "dep-1";
    assert float(str(spec["hourly_rate"])) == 0.35;
    assert str(spec["launch_cmd"]) == "bash fake_train.sh";
    # remote_dir is per-run unique: <base>-<name>
    assert str(spec["remote_dir"]) == "studio-run-t-run";
    assert str(spec["ssh_override"]) == "ssh test@fakehost";

    remotes: list[str] = [];
    for u in list(spec["uploads"]) {
        remotes.append(str(u["remote"]));
        assert str(u["local"]).startswith("/");
    }
    assert len(remotes) == 5;
    for want in ["data/train.jsonl", "data/valid.jsonl", "bootstrap.sh", "train_sft.py", "requirements.txt"] {
        assert want in remotes;
    }

    p_remotes: list[str] = [];
    for p in list(spec["pull"]) {
        p_remotes.append(str(p["remote"]));
    }
    for want in ["output/adapter", "train.log", "metrics.jsonl"] {
        assert want in p_remotes;
    }

    pol = dict(spec["policy"]);
    # cfg overrides applied...
    assert str(pol["auto_terminate"]) == "never";
    assert float(str(pol["max_wall_clock_min"])) == 60.0;
    # ...toml/built-in defaults preserved for the rest
    assert float(str(pol["ssh_wait_timeout_s"])) == 900.0;
    assert float(str(pol["provision_timeout_s"])) == 1800.0;
    assert float(str(pol["stall_timeout_min"])) == 30.0;
    assert float(str(pol["poll_interval_s"])) == 10.0;
}

test "runspec without ssh_override omits the key" {
    spec = _build_runspec({"name": "n2", "mode": "sft"}, "rid-2", "dep-2", 0.5, "cmd");
    assert "ssh_override" not in spec;
}

test "detached: stale heartbeat + dead pid only" {
    hb_old = "2020-01-01T00:00:00Z";
    hb_now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime());
    dead_pid = 999999;           # above macOS pid_max → never alive
    live_pid = int(os.getpid());
    # the one detached combination
    assert _is_detached({"status": "running", "heartbeat": hb_old}, dead_pid);
    # supervisor alive → attached (even with a stale heartbeat)
    assert not _is_detached({"status": "running", "heartbeat": hb_old}, live_pid);
    # heartbeat fresh → attached (supervisor may be between writes)
    assert not _is_detached({"status": "running", "heartbeat": hb_now}, dead_pid);
    # terminal statuses are never detached
    assert not _is_detached({"status": "done", "heartbeat": hb_old}, dead_pid);
    assert not _is_detached({"status": "failed", "heartbeat": hb_old}, dead_pid);
    assert not _is_detached({"status": "stopped", "heartbeat": hb_old}, dead_pid);
    # no/garbage heartbeat → not detached (can't prove staleness)
    assert not _is_detached({"status": "running"}, dead_pid);
    assert not _is_detached({"status": "running", "heartbeat": "not-a-time"}, dead_pid);
}

test "opts render to whitelisted CLI flags only" {
    flags = _extra_flags({
        "lora_r": "16", "max_steps": "100", "lr": "1e-4",
        "target_modules": "q_proj,v_proj",
        "bf16": "1", "load_in_4bit": "false",
        "evil": "x",                       # not whitelisted
        "subset": "50; rm -rf /"           # unsafe value → dropped
    });
    assert "--lora_r 16" in flags;
    assert "--max_steps 100" in flags;
    assert "--lr 1e-4" in flags;
    assert "--target_modules q_proj,v_proj" in flags;
    assert "--bf16" in flags;
    assert "--load_in_4bit" not in flags;  # falsy bool stays off
    assert "evil" not in flags;
    assert "subset" not in flags and "rm -rf" not in flags;
    assert flags.startswith(" ");
    assert _extra_flags({}) == "";
}

test "dataset defaults resolve from [cloudrun], cfg overrides win" {
    d = _dataset_rels({});
    assert str(d["train_rel"]).endswith("dataset/mlx/train.jsonl");
    assert str(d["valid_rel"]).endswith("dataset/mlx/valid.jsonl");
    o = _dataset_rels({"dataset": {"train_rel": "custom/train.jsonl"}});
    assert str(o["train_rel"]) == "custom/train.jsonl";
    assert str(o["valid_rel"]).endswith("dataset/mlx/valid.jsonl");
}

test "start_remote_run validation gate rejects before any side effects" {
    r1 = start_remote_run({"name": "bad name!", "mode": "sft", "base_model": "org/m"});
    assert not bool(r1["ok"]);
    assert "invalid name" in str(r1["error"]);

    r2 = start_remote_run({"name": "comparison", "mode": "sft", "base_model": "org/m"});
    assert not bool(r2["ok"]);
    assert "reserved" in str(r2["error"]);

    r3 = start_remote_run({"name": "ok-name", "mode": "dpo", "base_model": "org/m"});
    assert not bool(r3["ok"]);
    assert "sft" in str(r3["error"]);

    r4 = start_remote_run({"name": "ok-name", "mode": "sft", "base_model": "../evil"});
    assert not bool(r4["ok"]);
    assert "base_model" in str(r4["error"]);

    # valid identity but no offer → rejected before any Spheron call
    r5 = start_remote_run({"name": "ok-name", "mode": "sft", "base_model": "org/m"});
    assert not bool(r5["ok"]);
    assert "offer" in str(r5["error"]);
}
