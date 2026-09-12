"""studio - tests for inference.sv.jac residency helpers. No model is loaded: the
resident slot is faked with placeholder objects. Run with
`jac test server/models/inference.test.jac`.
"""

test "evict is a no-op when nothing is resident" {
    _S["current_id"] = "";
    _S["model"] = None;
    assert evict() == True, "handled immediately";
    assert _S["current_id"] == "";
    assert not _S["evict_pending"];
}

test "evict drops a resident model and frees the slot" {
    _S["model"] = object();
    _S["tokenizer"] = object();
    _S["current_id"] = "qwen-q4";
    assert evict() == True;
    assert _S["current_id"] == "", _S["current_id"];
    assert _S["model"] is None and _S["tokenizer"] is None;
    assert loaded_info()["id"] == "";
}

test "evict defers instead of stalling while the model lock is held" {
    _S["model"] = object();
    _S["tokenizer"] = object();
    _S["current_id"] = "busy-model";
    _S["lock"].acquire();
    try {
        assert evict(0.1) == False, "busy lock → deferred, not stalled";
        assert _S["evict_pending"], "eviction marked pending for the stream";
        assert _S["current_id"] == "busy-model";
    } finally {
        _S["lock"].release();
    }
    assert evict() == True;
    assert _S["current_id"] == "" and not _S["evict_pending"];
}
