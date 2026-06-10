from fastapi.testclient import TestClient

import app as app_module


def test_prompts_endpoint():
    client = TestClient(app_module.create_app())
    body = client.get("/api/prompts").json()
    ids = [c["id"] for c in body["categories"]]
    assert ids == ["py2jac", "idioms", "explain", "general"]
    for c in body["categories"]:
        assert len(c["prompts"]) > 0
        assert all(isinstance(p, str) for p in c["prompts"])
