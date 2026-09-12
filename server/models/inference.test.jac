"""studio - tests for inference.sv.jac residency helpers. No model is loaded: the
resident slot is faked with placeholder objects. Run with
`jac test server/models/inference.test.jac`.
"""

test "evict is a no-op when nothing is resident" {
    _S["current_id"] = "";
    assert evict() == "", "nothing to evict";
}

test "evict drops a resident model and frees the slot" {
    _S["model"] = object();
    _S["tokenizer"] = object();
    _S["current_id"] = "qwen-q4";
    assert evict() == "qwen-q4";
    assert _S["current_id"] == "", _S["current_id"];
    assert _S["model"] is None and _S["tokenizer"] is None;
    assert loaded_info()["id"] == "";
}

test "evict gives up instead of stalling while the model lock is held" {
    _S["model"] = object();
    _S["tokenizer"] = object();
    _S["current_id"] = "busy-model";
    _S["lock"].acquire();
    try {
        assert evict(0.1) == "", "busy lock → no eviction";
        assert _S["current_id"] == "busy-model";
    } finally {
        _S["lock"].release();
    }
    assert evict() == "busy-model";
}
