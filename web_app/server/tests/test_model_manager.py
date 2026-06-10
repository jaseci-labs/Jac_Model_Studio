from model_manager import ModelManager


def make_loader(calls):
    def loader(path):
        calls.append(path)
        return ("MODEL:" + path, "TOK:" + path)
    return loader


def test_load_sets_state():
    calls = []
    mgr = ModelManager(loader=make_loader(calls))
    secs = mgr.load_sync("qwen-dpo", "/fake/qwen")
    assert mgr.current_id == "qwen-dpo"
    assert mgr.model == "MODEL:/fake/qwen"
    assert mgr.tokenizer == "TOK:/fake/qwen"
    assert secs >= 0.0
    assert calls == ["/fake/qwen"]


def test_load_same_model_is_noop():
    calls = []
    mgr = ModelManager(loader=make_loader(calls))
    mgr.load_sync("qwen-dpo", "/fake/qwen")
    mgr.load_sync("qwen-dpo", "/fake/qwen")
    assert calls == ["/fake/qwen"]


def test_swap_unloads_first():
    calls = []
    mgr = ModelManager(loader=make_loader(calls))
    mgr.load_sync("qwen-dpo", "/fake/qwen")
    mgr.load_sync("gemma-dpo", "/fake/gemma")
    assert mgr.current_id == "gemma-dpo"
    assert calls == ["/fake/qwen", "/fake/gemma"]


def test_unload_clears_state():
    mgr = ModelManager(loader=make_loader([]))
    mgr.load_sync("qwen-dpo", "/fake/qwen")
    mgr.unload()
    assert mgr.current_id is None
    assert mgr.model is None
    assert mgr.tokenizer is None
