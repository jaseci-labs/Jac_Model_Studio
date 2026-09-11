"""studio - tests for chat.sv.jac guards: the server-side max_tokens cap and the
heavy GPU lock. No model is ever loaded — every assertion is on a guard that
fires before inference touches mlx. The heavy lock lives under a temp data root.
Run with `jac test server/models/chat.test.jac`.
"""

import os;
import tempfile;
import from server.core { jobs }
import server.models.models as models;

"""Point the data root at a temp dir and take the heavy slot like a train job."""
def _hold -> None {
    os.environ["JAC_STUDIO_DATA_ROOT"] = tempfile.mkdtemp(prefix="studio-chat-");
    assert jobs.heavy_acquire("test:train")["ok"];
}

def _free -> None {
    jobs.heavy_release("test:train");
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
