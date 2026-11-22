"""Live preview: rendering, reload injection, SPA fallback, proxy."""
from __future__ import annotations

import asyncio

from fastapi.testclient import TestClient

from nethhost.api.server import create_app
from nethhost.database import Database
from nethhost.preview.server import PreviewWatcher, inject_reload
from nethhost.tools import build_registry
from nethhost.tools.terminal import SERVERS


def make_client(layout, config):
    db = Database(layout.memory)
    registry = build_registry()
    app = create_app(config, db, registry, layout)
    return TestClient(app)


def test_inject_reload_appends_client():
    html = "<html><body><h1>Sim</h1></body></html>"
    injected = inject_reload(html, "demo")
    assert "EventSource" in injected and "demo" in injected
    assert injected.index("EventSource") > injected.index("<h1>")
    assert injected.count("</body>") == 1 or injected.endswith("</script>\n</body></html>") is False


def test_inject_reload_without_body_tag():
    injected = inject_reload("<p>plain</p>", "demo")
    assert injected.startswith("<p>plain</p>")
    assert "EventSource" in injected


def test_static_site_served_and_injected(layout, config):
    project = layout.project("demo")
    (project / "assets").mkdir(parents=True)
    (project / "index.html").write_text("<html><body><h1>hello</h1></body></html>")
    (project / "assets" / "site.css").write_text("body { color: #111; }")
    (project / "app.js").write_text("console.log('hi')")
    with make_client(layout, config) as client:
        response = client.get("/preview/demo/")
        assert response.status_code == 200
        assert "hello" in response.text and "EventSource" in response.text
        css = client.get("/preview/demo/assets/site.css")
        assert css.status_code == 200 and "text/css" in css.headers["content-type"]
        js = client.get("/preview/demo/app.js")
        assert js.status_code == 200 and "text/javascript" in js.headers["content-type"]


def test_spa_fallback_serves_index(layout, config):
    project = layout.project("spa")
    (project).mkdir(parents=True)
    (project / "index.html").write_text("<html><body>spa</body></html>")
    with make_client(layout, config) as client:
        response = client.get("/preview/spa/some/client/route")
        assert response.status_code == 200 and "spa" in response.text


def test_unknown_project_404(layout, config):
    with make_client(layout, config) as client:
        assert client.get("/preview/missing/").status_code == 404


def test_path_escape_blocked_in_preview(layout, config):
    project = layout.project("demo")
    project.mkdir(parents=True)
    (project / "index.html").write_text("<p>x</p>")
    with make_client(layout, config) as client:
        response = client.get("/preview/demo/../secret.txt")
        assert response.status_code in (301, 302, 403, 404)  # normalized or blocked


def test_sse_endpoint_streams(layout, config, monkeypatch):
    import nethhost.preview.server as preview_module
    monkeypatch.setattr(preview_module, "STREAM_CAP_SECONDS", 1.0)
    project = layout.project("demo")
    project.mkdir(parents=True)
    (project / "index.html").write_text("<p>x</p>")
    with make_client(layout, config) as client:
        with client.stream("GET", "/preview/__neth__/events?project=demo") as response:
            assert response.status_code == 200
            assert "text/event-stream" in response.headers["content-type"]
            first = next(response.iter_lines())
            assert "retry" in first
    # the connection ends on its own thanks to the (shortened) stream cap


def test_dev_server_proxy_requires_running_server(layout, config):
    with make_client(layout, config) as client:
        response = client.get("/preview/viteapp/__proxy/index.html")
        assert response.status_code == 404


async def test_watcher_detects_changes(layout):
    watcher = PreviewWatcher(layout.workspace, interval=0.2)
    project = layout.project("demo")
    project.mkdir(parents=True)
    (project / "index.html").write_text("v1")
    queue = watcher.subscribe("demo")
    watcher.start()
    try:
        await asyncio.sleep(0.6)  # let the watcher thread prime its snapshot
        (project / "index.html").write_text("v2-changed")
        message = await asyncio.wait_for(queue.get(), timeout=3)
        assert message == "reload"
    finally:
        watcher.unsubscribe("demo", queue)
