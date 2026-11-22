"""Live preview: serve project files with auto-reload, proxy Node dev servers.

- Static projects: any HTML file gets a tiny reload client injected; a watcher
  thread broadcasts "reload" over SSE when files change, so the iPad shows the
  actual rendered site that updates on save.
- Node/Vite projects: once start_dev_server opens an internal port, /preview/
  <project>/__proxy/... reverse-proxies it through the authenticated API so no
  development port is exposed directly.
"""
from __future__ import annotations

import asyncio
import threading
import time
from pathlib import Path

import httpx
from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse, StreamingResponse

RELOAD_JS = """
<script>
(function () {
  var source = new EventSource('/preview/__neth__/events?project=__PROJECT__');
  source.onmessage = function (event) {
    if (event.data === 'reload') { location.reload(); }
  };
  console.log('[neth-preview] live reload active');
})();
</script>
"""

# Each SSE connection ends after this many seconds; browsers reconnect
# automatically (retry: 2000), which keeps server resources bounded.
STREAM_CAP_SECONDS = 600.0


class PreviewWatcher:
    """Watches project directories for mtime changes and fans out reload events."""

    def __init__(self, workspace: Path, interval: float = 1.0) -> None:
        self.workspace = workspace
        self.interval = interval
        self._snapshots: dict[str, dict[str, float]] = {}
        self._subscribers: dict[str, set[asyncio.Queue]] = {}
        self._loop: asyncio.AbstractEventLoop | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        try:
            self._loop = asyncio.get_running_loop()
        except RuntimeError:  # no running loop yet (startup hook, scripts)
            self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._run, daemon=True, name="neth-preview-watch")
        self._thread.start()

    def subscribe(self, project: str) -> asyncio.Queue:
        queue: asyncio.Queue = asyncio.Queue(maxsize=16)
        self._subscribers.setdefault(project, set()).add(queue)
        return queue

    def unsubscribe(self, project: str, queue: asyncio.Queue) -> None:
        self._subscribers.get(project, set()).discard(queue)

    def _notify(self, project: str) -> None:
        if not self._loop:
            return
        for queue in list(self._subscribers.get(project, set())):
            self._loop.call_soon_threadsafe(lambda q=queue: q.put_nowait("reload"))

    def _snapshot(self, project_dir: Path) -> dict[str, float]:
        state: dict[str, float] = {}
        for current, dirs, files in _walk(project_dir):
            for name in files:
                path = current / name
                try:
                    state[str(path)] = path.stat().st_mtime
                except OSError:
                    continue
        return state

    def _run(self) -> None:
        while True:
            try:
                if self.workspace.exists():
                    for project_dir in self.workspace.iterdir():
                        if not project_dir.is_dir():
                            continue
                        project = project_dir.name
                        snapshot = self._snapshot(project_dir)
                        previous = self._snapshots.get(project)
                        if previous is not None and snapshot != previous:
                            self._notify(project)
                        self._snapshots[project] = snapshot
            except Exception:
                pass  # the watcher must survive transient IO errors
            time.sleep(self.interval)


def _walk(root: Path):
    for current, dirs, files in root.walk():
        dirs[:] = [d for d in dirs if d not in ("node_modules", ".git", "dist")]
        yield Path(current), dirs, files


def inject_reload(html: str, project: str) -> str:
    marker = RELOAD_JS.replace("__PROJECT__", project)
    if "</body>" in html.lower():
        position = html.lower().rfind("</body>")
        return html[:position] + marker + html[position:]
    return html + marker


def build_router(workspace: Path, watcher: PreviewWatcher, dev_servers: dict) -> APIRouter:
    router = APIRouter(prefix="/preview", include_in_schema=False)

    def project_dir(project: str) -> Path:
        candidate = (workspace / project).resolve()
        if not candidate.is_dir() or not candidate.is_relative_to(workspace.resolve()):
            raise HTTPException(404, f"no preview for project '{project}'")
        return candidate

    @router.get("/__neth__/events")
    async def events(request: Request, project: str):
        import nethhost.preview.server as server_module
        queue = watcher.subscribe(project)
        started = time.time()

        async def stream():
            try:
                yield "retry: 2000\n\n"
                while True:
                    if await request.is_disconnected():
                        return
                    remaining = server_module.STREAM_CAP_SECONDS - (time.time() - started)
                    if remaining <= 0:
                        return
                    try:
                        message = await asyncio.wait_for(queue.get(),
                                                         timeout=min(15.0, remaining))
                        yield f"data: {message}\n\n"
                    except asyncio.TimeoutError:
                        yield ": keepalive\n\n"
            finally:
                watcher.unsubscribe(project, queue)
        return StreamingResponse(stream(), media_type="text/event-stream")

    @router.get("/{project}/__proxy/{path:path}")
    @router.get("/{project}/__proxy")
    async def proxy(project: str, path: str = ""):
        entry = dev_servers.get(project)
        if not entry:
            raise HTTPException(404, "no dev server running for this project")
        port = entry["port"]
        url = f"http://127.0.0.1:{port}/{path}"
        async with httpx.AsyncClient(timeout=30) as client:
            response = await client.get(url)
        media = response.headers.get("content-type", "text/plain")
        return PlainTextResponse(response.text if media.startswith("text/") else response.content,
                                 status_code=response.status_code,
                                 media_type=media)

    @router.get("/{project}/{path:path}")
    @router.get("/{project}")
    async def serve(project: str, path: str = ""):
        root = project_dir(project)
        target = (root / path).resolve() if path else root / "index.html"
        if not target.exists() or not target.is_relative_to(root):
            # SPA fallback: unknown extensionless routes go to index.html
            fallback = root / "index.html"
            if fallback.exists() and not path.endswith((".js", ".css", ".png", ".jpg", ".svg", ".ico")):
                target = fallback
            else:
                raise HTTPException(404, f"not found: {path or 'index.html'}")
        if target.is_dir():
            target = target / "index.html"
            if not target.exists():
                raise HTTPException(404, "directory has no index.html")
        if target.suffix.lower() in (".html", ".htm"):
            html = target.read_text("utf-8", errors="replace")
            return HTMLResponse(inject_reload(html, project))
        media_types = {".js": "text/javascript", ".css": "text/css", ".json": "application/json",
                       ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                       ".svg": "image/svg+xml", ".ico": "image/x-icon", ".txt": "text/plain",
                       ".woff": "font/woff", ".woff2": "font/woff2"}
        content = target.read_bytes()
        media = media_types.get(target.suffix.lower(), "application/octet-stream")
        return PlainTextResponse(content, media_type=media)

    @router.get("/{project}/__status")
    async def status(project: str):
        root = project_dir(project)
        entry = dev_servers.get(project)
        return JSONResponse({"project": project, "files": sum(len(f) for _, _, f in _walk(root)),
                             "dev_server_port": entry["port"] if entry else None})

    return router
