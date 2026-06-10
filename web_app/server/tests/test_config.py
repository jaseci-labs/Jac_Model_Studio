import config


def test_registry_has_four_models():
    ids = [m["id"] for m in config.MODELS]
    assert ids == ["qwen-dpo", "gemma-dpo", "qwen-sft", "gemma-sft"]


def test_model_by_id():
    assert config.model_by_id("qwen-dpo")["label"] == "Qwen · DPO"
    assert config.model_by_id("nope") is None


def test_data_root_env_override(fake_root):
    assert config.data_root() == fake_root


def test_model_path_and_availability(fake_root):
    m = config.model_by_id("qwen-dpo")
    assert config.model_path(m) == fake_root / "models/qwen-jac-dpo-fused-q8"
    assert config.model_available(m) is True
    assert config.model_available(config.model_by_id("qwen-sft")) is False


def test_dir_size_gb(fake_root):
    m = config.model_by_id("qwen-dpo")
    assert config.dir_size_gb(config.model_path(m)) == round(1000 / 1e9, 2)


def test_total_ram_gb_positive():
    assert config.total_ram_gb() > 0


from fastapi.testclient import TestClient

import app as app_module


def test_models_endpoint(fake_root):
    client = TestClient(app_module.create_app())
    r = client.get("/api/models")
    assert r.status_code == 200
    body = r.json()
    assert [m["id"] for m in body["models"]] == ["qwen-dpo", "gemma-dpo", "qwen-sft", "gemma-sft"]
    assert body["models"][0]["available"] is True
    assert body["models"][2]["available"] is False
    assert body["loaded"] is None
    assert body["ram_gb"] > 0
    assert body["resident_gb"] is None


def test_models_endpoint_reports_loaded(fake_root):
    a = app_module.create_app(loader=lambda p: ("m", "t"))
    client = TestClient(a)
    a.state.manager.load_sync("qwen-dpo", str(fake_root / "models/qwen-jac-dpo-fused-q8"))
    body = client.get("/api/models").json()
    assert body["loaded"] == "qwen-dpo"
    assert body["resident_gb"] is not None


def test_cors_preflight_allows_ui_origin(fake_root):
    client = TestClient(app_module.create_app())
    r = client.options("/api/chats", headers={
        "Origin": "http://localhost:3000",
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "content-type",
    })
    assert r.status_code == 200
    assert r.headers["access-control-allow-origin"] == "http://localhost:3000"
