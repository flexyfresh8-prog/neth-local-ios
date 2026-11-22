"""Browser tools backed by Playwright (optional dependency).

When Playwright + Chromium are installed the host can open a page, screenshot
it, and pull the console messages and failed network requests — the errors the
coding agent needs to fix a broken preview. Without Playwright the tools return
a structured "not installed" result instead of crashing, and the setup guide
explains how to enable them.
"""
from __future__ import annotations

import time

from . import ToolContext, ToolError, ToolRegistry, ToolResult, ToolSpec

# Latest capture, per project, for browser_console and the preview error feed.
CONSOLE_FEED: dict[str, dict] = {}


def _playwright():
    try:
        from playwright.sync_api import sync_playwright  # type: ignore
    except ImportError:
        return None
    return sync_playwright


def register(registry: ToolRegistry) -> None:
    registry.register(ToolSpec(
        name="browser_open",
        description="Open a URL in the automation browser and capture console errors "
                    "and failed network requests.",
        parameters={"type": "object",
                    "properties": {"url": {"type": "string"},
                                   "wait_seconds": {"type": "integer"}},
                    "required": ["url"]},
    ), _browser_open)

    registry.register(ToolSpec(
        name="browser_screenshot",
        description="Screenshot the last opened page into previews/<project>.png.",
        parameters={"type": "object", "properties": {}},
    ), _browser_screenshot)

    registry.register(ToolSpec(
        name="browser_console",
        description="Return the console messages and failed requests from the last "
                    "browser_open call for this project.",
        parameters={"type": "object", "properties": {}},
    ), _browser_console)


def _require(context: ToolContext):
    factory = _playwright()
    if factory is None:
        raise ToolError(
            "Playwright is not installed on this host. The agent can still write and "
            "serve the project; to enable browser checks run: pip install playwright "
            "&& playwright install chromium")
    return factory


async def _browser_open(context: ToolContext, args: dict) -> ToolResult:
    factory = _require(context)
    url = args["url"]
    if not url.startswith(("http://", "https://")):
        raise ToolError("url must start with http:// or https://")
    wait_seconds = min(int(args.get("wait_seconds", 2)), 30)
    console: list[dict] = []
    failures: list[dict] = []

    with factory() as playwright:
        browser = playwright.chromium.launch(headless=True)
        try:
            page = browser.new_page()
            page.on("console", lambda message: console.append({
                "kind": message.type, "text": message.text[:500]}))
            page.on("pageerror", lambda error: console.append({
                "kind": "pageerror", "text": str(error)[:500]}))
            page.on("requestfailed", lambda request: failures.append({
                "url": request.url[:300], "failure": request.failure}))
            page.goto(url, timeout=(wait_seconds + 10) * 1000)
            page.wait_for_timeout(wait_seconds * 1000)
            screenshot = context.layout.previews / f"{context.project}.png"
            screenshot.parent.mkdir(parents=True, exist_ok=True)
            page.screenshot(path=str(screenshot), full_page=False)
        finally:
            browser.close()

    feed = {"url": url, "console": console, "failed_requests": failures,
            "captured_at": time.time()}
    CONSOLE_FEED[context.project] = feed
    errors = [c for c in console if c["kind"] in ("error", "pageerror")]
    summary = (f"opened {url}; {len(console)} console message(s), {len(errors)} error(s), "
               f"{len(failures)} failed request(s); screenshot: {screenshot.name}")
    if errors:
        detail = "\n".join(f"[{c['kind']}] {c['text']}" for c in errors[:20])
        return ToolResult(False, f"{summary}\n{detail}", data=feed)
    return ToolResult(True, summary, data=feed)


async def _browser_screenshot(context: ToolContext, _args: dict) -> ToolResult:
    path = context.layout.previews / f"{context.project}.png"
    if not path.exists():
        raise ToolError("no screenshot yet; call browser_open first")
    return ToolResult(True, str(path), data={"path": str(path)})


async def _browser_console(context: ToolContext, _args: dict) -> ToolResult:
    feed = CONSOLE_FEED.get(context.project)
    if not feed:
        return ToolResult(True, "no browser capture yet for this project; call browser_open first")
    import json
    return ToolResult(True, json.dumps(feed, indent=2)[:8000], data=feed)
