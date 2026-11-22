"""API surface: authentication, projects, chat wiring, context stats, backend config."""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from nethhost.api.server import create_app
from nethhost.database import Database
from nethhost.tools import build_registry


@pytest.fixture()
def client(layout, config):
    db = Database(layout.memory)
    registry = build_registry()
    app = create_app(config, db, registry, layout)
    with TestClient(app) as test_client:
        yield test_client, config, db


def test_healthz_open(client):
    test_client, _, _ = client
    response = test_client.get("/healthz")
    assert response.status_code == 200
    assert response.json()["service"] == "NethHost"


def test_api_requires_key(client):
    test_client, _, _ = client
    assert test_client.get("/api/tools").status_code == 401
    assert test_client.get("/api/projects").status_code == 401
    assert test_client.get("/api/tools", headers={"Authorization": "Bearer wrong"}).status_code == 401


def test_api_accepts_correct_key(client):
    test_client, config, _ = client
    response = test_client.get("/api/tools", headers={"Authorization": f"Bearer {config.api_key}"})
    assert response.status_code == 200
    names = [tool["name"] for tool in response.json()]
    for expected in ("write_file", "read_file", "run_command", "git_commit", "browser_open"):
        assert expected in names


def test_project_crud(client):
    test_client, config, _ = client
    headers = {"Authorization": f"Bearer {config.api_key}"}
    created = test_client.post("/api/projects", json={"name": "physics-sim"}, headers=headers)
    assert created.status_code == 200
    listed = test_client.get("/api/projects", headers=headers).json()
    assert any(p["name"] == "physics-sim" for p in listed)


def test_chat_endpoint_runs_orchestrator(client, monkeypatch):
    test_client, config, _ = client
    headers = {"Authorization": f"Bearer {config.api_key}"}

    class FakeClient:
        async def chat(self, messages, tools=None, max_tokens=2048, on_token=None, temperature=0.7):
            from nethhost.agent.model_client import StreamDelta
            yield StreamDelta(content="ok", finish="stop")

    import nethhost.api.server as server_module

    original = server_module.create_app

    test_client.post("/api/projects", json={"name": "demo"}, headers=headers)
    from nethhost.context_manager import ContextManager

    class NoopSummarizer:
        async def summarize(self, text):
            return "digest"

    # Patch the model client factory inside the running app via monkeypatching ModelClient
    monkeypatch.setattr(server_module, "ModelClient", lambda url, key, model="m": FakeClient())

    response = test_client.post("/api/chat", json={"project": "demo", "message": "say hi"},
                                headers=headers)
    assert response.status_code == 200
    body = response.json()
    assert body["result"]["status"] == "complete"


def test_context_stats_endpoint(client):
    test_client, config, db = client
    headers = {"Authorization": f"Bearer {config.api_key}"}
    db.create_conversation("convA", "t", "p")
    db.add_message("convA", "user", "hello " * 100)
    response = test_client.get("/api/context/stats?conversation_id=convA", headers=headers)
    assert response.status_code == 200
    body = response.json()
    assert body["messages"] == 1 and body["estimated_tokens"] > 0


def test_backend_config_validation(client):
    test_client, config, _ = client
    headers = {"Authorization": f"Bearer {config.api_key}"}
    bad = test_client.post("/api/backend/config", json={"url": "ftp://x", "api_key": "k"}, headers=headers)
    assert bad.status_code == 400
    missing = test_client.post("/api/backend/config", json={"url": ""}, headers=headers)
    assert missing.status_code == 400


def test_backend_status_without_config(client):
    test_client, config, _ = client
    headers = {"Authorization": f"Bearer {config.api_key}"}
    response = test_client.get("/api/backend/status", headers=headers)
    assert response.status_code == 200
    assert response.json()["connected"] is False


def test_key_never_in_open_health(client):
    test_client, config, _ = client
    body = test_client.get("/healthz").text
    assert config.api_key not in body
