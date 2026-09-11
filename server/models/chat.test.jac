"""studio - tests for chat.sv.jac guards: the server-side max_tokens cap and the
heavy GPU lock. No model is ever loaded — every assertion is on a guard that
fires before inference touches mlx. The heavy lock lives under a temp data root.
Run with `jac test server/models/chat.test.jac`.
"""

import os;
import tempfile;
import from server.core { jobs }
import from server.models.inference { clamp_max_tokens, MAX_TOKENS_CAP }
import server.models.models as models;

"""Point the data root at a temp dir and take the heavy slot like a train job."""
def _hold -> None {
    os.environ["JAC_STUDIO_DATA_ROOT"] = tempfile.mkdtemp(prefix="studio-chat-");
    assert jobs.heavy_acquire("test:train")["ok"];
}

def _free -> None {
    jobs.heavy_release("test:train");
}

test "clamp_max_tokens bounds max_tokens to the UI slider range" {
    assert MAX_TOKENS_CAP == 4096, MAX_TOKENS_CAP;
    assert clamp_max_tokens(1024) == 1024;
    assert clamp_max_tokens(1536) == 1536;
    assert clamp_max_tokens(4096) == 4096;
    assert clamp_max_tokens(1000000000) == MAX_TOKENS_CAP;
    assert clamp_max_tokens(0) == 1 and clamp_max_tokens(-5) == 1;
}

test "chat_stream refuses while a heavy GPU job holds the slot" {
    _hold();
    try {
        frames = list(chat_stream([], "any-model"));
        assert str(frames[0]["kind"]) == "error", frames;
        assert "GPU busy" in str(frames[0]["text"]), frames;
    } finally {
        _free();
    }
}

test "warm_model refuses while a heavy GPU job holds the slot" {
    _hold();
    try {
        r = models.warm_model("any-model");
        assert "GPU busy" in str(r["error"]), r;
    } finally {
        _free();
    }
}
