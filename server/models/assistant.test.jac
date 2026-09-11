"""studio - tests for assistant.sv.jac guards: the local (MLX) stream must respect
the heavy GPU lock. No model is loaded: the guard fires first. Run with
`jac test server/models/assistant.test.jac`.
"""

import os;
import tempfile;
import from server.core { jobs }

test "_stream_local refuses while a heavy GPU job holds the slot" {
    os.environ["JAC_STUDIO_DATA_ROOT"] = tempfile.mkdtemp(prefix="studio-asst-");
    assert jobs.heavy_acquire("test:train")["ok"];
    try {
        frames = list(_stream_local([], "any-model", 0.3, 0.9, 64));
        assert str(frames[0]["kind"]) == "error", frames;
        assert "GPU busy" in str(frames[0]["text"]), frames;
    } finally {
        jobs.heavy_release("test:train");
    }
}
