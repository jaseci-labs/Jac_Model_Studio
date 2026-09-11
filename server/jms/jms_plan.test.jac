"""studio - tests for jms_plan.sv.jac guards. The MLX draft path loads a model
into the server process, so it must respect the heavy GPU lock like train /
eval / gen. No model is loaded: the guard fires first. Run with
`jac test server/jms/jms_plan.test.jac`.
"""

import os;
import tempfile;
import from server.core { jobs }
import from server.jms.jms_projects { JmsProject }

test "_draft_mlx refuses while a heavy GPU job holds the slot" {
    os.environ["JAC_STUDIO_DATA_ROOT"] = tempfile.mkdtemp(prefix="studio-plan-");
    assert jobs.heavy_acquire("test:train")["ok"];
    try {
        r = _draft_mlx(JmsProject(), "any-model", "");
        assert not bool(r["ok"]), r;
        assert "GPU busy" in str(r["error"]), r;
    } finally {
        jobs.heavy_release("test:train");
    }
}
