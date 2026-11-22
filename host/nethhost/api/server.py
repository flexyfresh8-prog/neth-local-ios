"""FastAPI application: authenticated REST + WebSocket API for the iPad app.

Security model: every /api and /ws route requires the Bearer API key from
config.json (constant-time comparison); only /healthz is open and it returns no
sensitive data. The server binds the LAN so the iPad can reach it, but nothing
is exposed to the public internet without the key, and development ports stay
behind the authenticated preview proxy.
"""
from __future__ import annotations

import asyncio
import hmac
import json
import socket
import uuid
from typing import Any

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

from .. import __version__
from ..agent.model_client import BackendError, ModelClient
from ..agent.orchestrator import Orchestrator, new_conversation_id
from ..config import Config
from ..context_manager import ContextManager
from ..database import Database
from ..paths import Layout
from ..preview.server import PreviewWatcher, build_router
from ..tools import ToolContext, ToolRegistry
from ..tools.terminal import SERVERS


class BackendSummarizer:
    """Compacts conversations through the same backend that runs the agent."""

    def __init__(self, client_factory) -> None:
        self.client_factory = client_factory

    async def summarize(self, text: str) -> str:
        client = self.client_factory()
        prompt = ("Summarize this coding session in under 220 words. Keep: objectives and "
                  "requirements, file paths, errors and fixes, key decisions, pending steps. "
                  "Be concrete.\n\n" + text[-12000:])
        parts: list[str] = []
        async for delta in client.chat(
                [{"role": "user", "content": prompt}], None, 400):
            if delta.content:
                parts.append(delta.content)
        return "".join(parts).strip()


def create_app(config: Config, db: Database, registry: ToolRegistry,
               layout: Layout | None = None) -> FastAPI:
    layout = layout or config.layout
    watcher = PreviewWatcher(layout.workspace)
    app = FastAPI(title="NethHost", version=__version__, docs_url=None, redoc_url=None)
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"],
                       allow_headers=["*"])

    def auth(authorization: str = Header(default="")) -> None:
        expected = f"Bearer {config.api_key}"
        if not authorization or not hmac.compare_digest(authorization, expected):
            raise HTTPException(401, "missing or invalid API key")

    state: dict[str, Any] = {}

    def model_client() -> ModelClient:
        backend = config.backend
        return ModelClient(backend.get("url", ""), backend.get("api_key", ""),
                           backend.get("model", "gpt-oss-20b"))

    def context_manager() -> ContextManager:
        ctx = config.data.get("context", {})
        return ContextManager(db, BackendSummarizer(model_client),
                              model_limit=int(ctx.get("model_limit", 32768)),
                              reserve_output=int(ctx.get("reserve_output", 4096)),
                              compact_at=float(ctx.get("compact_at", 0.72)))

    def orchestrator() -> Orchestrator:
        return Orchestrator(registry, model_client(), context_manager(), db, config)

    @app.on_event("startup")
    async def _startup() -> None:
        watcher.start()
        state["started"] = True

    @app.get("/healthz")
    async def healthz():
        return {"status": "ok", "service": "NethHost", "version": __version__}

    @app.get("/api/tools", dependencies=[Depends(auth)])
    async def tools():
        return [{"name": spec.name, "description": spec.description,
                 "danger": spec.danger, "needs_approval": spec.needs_approval,
                 "parameters": spec.parameters}
                for spec in [registry.spec(name) for name in registry.names()] if spec]

    @app.get("/api/projects", dependencies=[Depends(auth)])
    async def projects():
        return db.projects()

    @app.post("/api/projects", dependencies=[Depends(auth)])
    async def create_project(body: dict):
        name = str(body.get("name", "")).strip()
        if not name:
            raise HTTPException(400, "name is required")
        from ..paths import safe_name
        safe = safe_name(name)
        directory = layout.project(safe)
        directory.mkdir(parents=True, exist_ok=True)
        project_id = uuid.uuid4().hex[:12]
        db.add_project(project_id, safe, str(directory))
        db.log_event("project_created", {"name": safe})
        return {"id": project_id, "name": safe, "path": str(directory)}

    @app.post("/api/chat", dependencies=[Depends(auth)])
    async def chat(body: dict):
        project = str(body.get("project", "playground"))
        message = str(body.get("message", "")).strip()
        if not message:
            raise HTTPException(400, "message is required")
        conversation_id = str(body.get("conversation_id") or new_conversation_id())
        approved = bool(body.get("approved", False))
        events: list[dict] = []
        async for event in orchestrator().run(conversation_id, project, message,
                                              approved=approved, emit=None):
            events.append(event)
        return {"conversation_id": conversation_id, "events": events,
                "result": events[-1] if events else None}

    @app.websocket("/ws/chat")
    async def ws_chat(websocket: WebSocket):
        token = websocket.query_params.get("key", "")
        if not hmac.compare_digest(token, config.api_key):
            await websocket.close(code=4401)
            return
        await websocket.accept()
        try:
            payload = json.loads(await websocket.receive_text())
            project = str(payload.get("project", "playground"))
            message = str(payload.get("message", ""))
            approved = bool(payload.get("approved", False))
            cancelled = asyncio.Event()

            async def run() -> None:
                async for event in orchestrator().run(
                        str(payload.get("conversation_id") or new_conversation_id()),
                        project, message, approved=approved,
                        cancelled=cancelled.is_set,
                        emit=lambda e: _send(websocket, e)):
                    _send(websocket, event)

            runner = asyncio.create_task(run())
            try:
                while True:
                    incoming = json.loads(await websocket.receive_text())
                    if incoming.get("type") == "cancel":
                        cancelled.set()
            except WebSocketDisconnect:
                cancelled.set()
            finally:
                runner.cancel()
        except WebSocketDisconnect:
            pass

    @app.websocket("/ws/terminal")
    async def ws_terminal(websocket: WebSocket):
        token = websocket.query_params.get("key", "")
        if not hmac.compare_digest(token, config.api_key):
            await websocket.close(code=4401)
            return
        await websocket.accept()
        try:
            payload = json.loads(await websocket.receive_text())
            project = str(payload.get("project", "playground"))
            command = str(payload.get("command", ""))
            directory = layout.project(project)
            directory.mkdir(parents=True, exist_ok=True)

            from .tools.terminal import _quote, _stream_run
            context = ToolContext(layout=layout, project=project, project_dir=directory,
                                  emit=lambda e: _send(websocket, e), approved=True,
                                  workspace_root=layout.workspace)
            result = await _stream_run(context, _quote(command), directory, 300)
            _send(websocket, {"type": "exit", "ok": result.ok, "output": result.output[-8000:]})
        except WebSocketDisconnect:
            pass

    @app.get("/api/context/stats", dependencies=[Depends(auth)])
    async def context_stats(conversation_id: str):
        manager = context_manager()
        return db.context_stats(conversation_id, manager.usable)

    @app.post("/api/context/compact", dependencies=[Depends(auth)])
    async def compact(body: dict):
        conversation_id = str(body.get("conversation_id", ""))
        manager = context_manager()
        done = await manager.compact(conversation_id, reason="manual")
        return {"compacted": done, "stats": db.context_stats(conversation_id, manager.usable)}

    @app.get("/api/backend/status", dependencies=[Depends(auth)])
    async def backend_status():
        if not config.backend.get("url"):
            return {"connected": False,
                    "detail": "no backend configured; paste the Colab endpoint in Settings"}
        status = await model_client().health()
        return {"connected": status.connected, "detail": status.detail,
                "model": status.model, "context": status.context,
                "tools_capable": status.tools_capable, "latency": status.latency}

    @app.post("/api/backend/config", dependencies=[Depends(auth)])
    async def backend_config(body: dict):
        url = str(body.get("url", "")).strip()
        api_key = str(body.get("api_key", "")).strip()
        if url and not url.startswith(("http://", "https://")):
            raise HTTPException(400, "url must start with http:// or https://")
        if not url or not api_key:
            raise HTTPException(400, "url and api_key are required")
        config.set_backend(url, api_key, str(body.get("model") or "") or None)
        db.log_event("backend_configured", {"url": url})
        status = await model_client().health()
        return {"saved": True, "connected": status.connected, "detail": status.detail}

    @app.get("/api/preview/console", dependencies=[Depends(auth)])
    async def preview_console(project: str):
        from .tools.browser import CONSOLE_FEED
        feed = CONSOLE_FEED.get(project)
        if not feed:
            return {"captured": False}
        return {"captured": True, **feed}

    @app.get("/api/preview/status", dependencies=[Depends(auth)])
    async def preview_status():
        entry = {name: {"port": data["port"], "command": data["command"]}
                 for name, data in SERVERS.items()}
        return {"projects": entry}

    app.include_router(build_router(layout.workspace, watcher, SERVERS))
    return app


def _send(websocket: WebSocket, event: dict) -> None:
    try:
        payload = json.dumps(event)
        if websocket.client_state.name == "CONNECTED":
            asyncio.get_running_loop().create_task(websocket.send_text(payload))
    except Exception:
        pass


def lan_address(port: int) -> str:
    """Best-effort LAN IP so the printed instructions actually work on the iPad."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            return f"http://{sock.getsockname()[0]}:{port}"
    except OSError:
        return f"http://127.0.0.1:{port}"
