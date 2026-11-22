"""End-to-end: the spec's acceptance flow, with a scripted model.

User asks for a website -> the agent writes index.html (with a deliberate JS
bug), fixes it after reading tool output, starts a dev server, and the live
preview serves the real rendered page with reload injection.
"""
from __future__ import annotations

import json

from nethhost.agent.model_client import StreamDelta
from nethhost.agent.orchestrator import Orchestrator
from nethhost.context_manager import ContextManager


class ScriptedClient:
    def __init__(self, script) -> None:
        self.script = list(script)
        self.calls = []

    async def chat(self, messages, tools=None, max_tokens=2048, on_token=None, temperature=0.7):
        self.calls.append({"messages": [dict(m) for m in messages]})
        for delta in self.script.pop(0):
            if on_token:
                if delta.reasoning:
                    on_token("reasoning", delta.reasoning)
                if delta.content:
                    on_token("content", delta.content)
            yield delta


class NoopSummarizer:
    async def summarize(self, text):
        return "digest"


BROKEN_PAGE = """<!DOCTYPE html>
<html><head><title>Physics Sim</title></head>
<body>
<canvas id="stage"></canvas>
<script>
  const canvas = document.getElementById('stgae');  // typo -> runtime error
  const ctx = canvas.getContext('2d');
</script>
</body></html>
"""

FIXED_PAGE = BROKEN_PAGE.replace("'stgae'", "'stage'").replace(
    "</body>", "<p>Interactive physics simulation ready.</p></body>")


async def test_website_create_serve_and_fix(config, db, registry, layout):
    client = ScriptedClient([
        [StreamDelta(reasoning="plan the page"), StreamDelta(content="Creating the site."),
         StreamDelta(tool_calls=[{"id": "c1", "type": "function", "function": {
             "name": "write_file", "arguments": json.dumps({"path": "index.html",
                                                            "content": BROKEN_PAGE})}}])],
        [StreamDelta(tool_calls=[{"id": "c2", "type": "function", "function": {
            "name": "start_dev_server", "arguments": json.dumps({
                "command": "python3 -m http.server 8681 --bind 127.0.0.1", "port": 8681})}}])],
        [StreamDelta(content="Fixed the canvas id typo.", finish="stop")],
    ])
    manager = ContextManager(db, NoopSummarizer())
    orchestrator = Orchestrator(registry, client, manager, db, config)

    events = []
    async for event in orchestrator.run("e2e-conv", "physics-site",
                                        "Create a website with an interactive physics simulation."):
        events.append(event)

    done = events[-1]
    assert done["status"] == "complete", done
    assert "index.html" in done["files"]

    # the dev server is registered and the preview renders the real page
    from nethhost.tools.terminal import SERVERS
    assert "physics-site" in SERVERS
    port = SERVERS["physics-site"]["port"]

    from fastapi.testclient import TestClient
    from nethhost.api.server import create_app
    app = create_app(config, db, registry, layout)
    with TestClient(app) as http:
        page = http.get(f"/preview/physics-site/")
        assert page.status_code == 200
        assert "physics simulation" in page.text.lower() or "canvas" in page.text
        assert "EventSource" in page.text  # live reload injected
        status = http.get("/api/preview/status",
                          headers={"Authorization": f"Bearer {config.api_key}"})
        assert status.status_code == 200
        assert status.json()["projects"]["physics-site"]["port"] == port

    # now the agent fixes the typo and the file on disk updates
    client.script.append([StreamDelta(tool_calls=[{"id": "c3", "type": "function", "function": {
        "name": "patch_file", "arguments": json.dumps({
            "path": "index.html", "old": "'stgae'", "new": "'stage'"})}}])])
    client.script.append([StreamDelta(content="Typo fixed; preview reloads automatically.",
                                      finish="stop")])
    events2 = []
    async for event in orchestrator.run("e2e-conv2", "physics-site", "fix the canvas error"):
        events2.append(event)
    assert events2[-1]["status"] == "complete"
    served = (layout.project("physics-site") / "index.html").read_text()
    assert "'stage'" in served and "'stgae'" not in served

    from nethhost.tools.terminal import SERVERS as LIVE
    if "physics-site" in LIVE:
        import subprocess
        LIVE["physics-site"]["process"].terminate()
