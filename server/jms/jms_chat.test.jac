"""studio - unit tests for jms_chat.sv.jac run resolution (`_resolve_run`).

`_resolve_run` resolves (pid, rid) purely from disk (see the module docstring on
why the SSE generator cannot use the graph), so the rid is the only thing keeping
a caller inside the project whose pid they hold. These tests lay down two fake
projects under a temp data root and check a traversal rid cannot reach the other
one. No model is loaded. Run with `jac test server/jms/jms_chat.test.jac`.
"""

import os;
import json;
import tempfile;
import from pathlib { Path }

"""A fake project dir <data_root>/projects/<slug>/ with project.json and, when
*rid* is given, a chattable local-mlx run (mlx_config.json + adapter file)."""
def _fake_project(base: Path, slug: str, pid: str, rid: str, model_dir: str) -> None {
    d = base / "projects" / slug;
    d.mkdir(parents=True, exist_ok=True);
    (d / "project.json").write_text(json.dumps({"pid": pid, "slug": slug}));
    if rid {
        rd = d / "runs" / rid;
        (rd / "adapter").mkdir(parents=True, exist_ok=True);
        (rd / "adapter" / "adapters.safetensors").write_text("x");
        (rd / "mlx_config.json").write_text(json.dumps({"model": model_dir}));
    }
}

test "_resolve_run resolves the caller's own run" {
    base = Path(tempfile.mkdtemp(prefix="jms-chat-"));
    os.environ["JAC_STUDIO_DATA_ROOT"] = str(base);
    model_dir = tempfile.mkdtemp(prefix="jms-chat-model-");
    _fake_project(base, "mine", "aaaaaaaaaaaa", "111111111111", model_dir);
    r = _resolve_run("aaaaaaaaaaaa", "111111111111");
    assert bool(r["ok"]), r;
}

test "_resolve_run refuses a rid that traverses into another project" {
    base = Path(tempfile.mkdtemp(prefix="jms-chat-"));
    os.environ["JAC_STUDIO_DATA_ROOT"] = str(base);
    model_dir = tempfile.mkdtemp(prefix="jms-chat-model-");
    _fake_project(base, "mine", "aaaaaaaaaaaa", "", model_dir);
    _fake_project(base, "victim", "bbbbbbbbbbbb", "222222222222", model_dir);
    victim_run = base / "projects" / "victim" / "runs" / "222222222222";
    for rid in ["../../victim/runs/222222222222", str(victim_run), "..", "."] {
        r = _resolve_run("aaaaaaaaaaaa", rid);
        assert not bool(r["ok"]), (rid, r);
    }
}

import from server.core { jobs }

test "jms_chat_stream refuses while a heavy GPU job holds the slot" {
    os.environ["JAC_STUDIO_DATA_ROOT"] = tempfile.mkdtemp(prefix="jms-chat-busy-");
    assert jobs.heavy_acquire("test:train")["ok"];
    try {
        frames = list(jms_chat_stream("aaaaaaaaaaaa", "111111111111", []));
        assert str(frames[0]["kind"]) == "error", frames;
        assert "GPU busy" in str(frames[0]["text"]), frames;
    } finally {
        jobs.heavy_release("test:train");
    }
}

import from server.jms.jms_projects { create_project }

test "jms_chat_stream refuses a pid the caller does not own" {
    base = Path(tempfile.mkdtemp(prefix="jms-chat-owner-"));
    os.environ["JAC_STUDIO_DATA_ROOT"] = str(base);
    # User A's project: on the shared data_root disk, but NOT in this caller's
    # graph. Knowing the pid must not be enough.
    _fake_project(base, "user-a", "cccccccccccc", "", "");
    frames = list(jms_chat_stream("cccccccccccc", "333333333333", []));
    assert len(frames) == 1 and str(frames[0]["kind"]) == "error", frames;
    assert str(frames[0]["text"]) == "unknown project", frames;
}

test "jms_chat_stream lets the owner past the ownership check" {
    os.environ["JAC_STUDIO_DATA_ROOT"] = tempfile.mkdtemp(prefix="jms-chat-owner-");
    p = create_project("Chat Owner", "test");
    frames = list(jms_chat_stream(p.pid, "444444444444", []));
    assert str(frames[0]["kind"]) == "error", frames;
    assert "unknown run" in str(frames[0]["text"]), frames;
}
