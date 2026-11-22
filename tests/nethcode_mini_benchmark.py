#!/usr/bin/env python3
"""NethCode Mini benchmark: ask the Neth Cloud model for a working NethCode Mini
application, then check every generated Python source for syntax errors.

Run standalone while the Colab server is up:

    python tests/nethcode_mini_benchmark.py --base http://127.0.0.1:8080 --key <api-key> --runs 5

The report is JSON on stdout and never fabricates a pass: `valid_runs` counts only
sources that really parse with ast.parse.
"""

from __future__ import annotations

import argparse
import ast
import json
import time
import urllib.error
import urllib.request

PROMPT = (
    "Write a complete Python 3 command-line application called NethCode Mini: a to-do list "
    "manager with the commands add, list and done, using argparse and storing tasks in a "
    "JSON file. Include a main() function and `if __name__ == \"__main__\":`. "
    "Return only the program inside one ```python code fence, no explanations."
)

FENCE_START = "```python"
FENCE_END = "```"


def extract_python(reply: str) -> str:
    """Return the fenced Python body, or the raw reply when no fence is present."""
    start = reply.find(FENCE_START)
    if start >= 0:
        body = reply[start + len(FENCE_START):]
        end = body.find(FENCE_END)
        if end >= 0:
            body = body[:end]
        return body.strip("\n")
    return reply.strip()


def syntax_check(source: str) -> dict:
    try:
        ast.parse(source)
        return {"valid": True, "detail": "parsed", "bytes": len(source.encode())}
    except SyntaxError as error:
        return {"valid": False, "detail": f"line {error.lineno}: {error.msg}",
                "bytes": len(source.encode())}


def _chat(base_url: str, key: str, max_tokens: int, system: str | None = None) -> dict:
    request = urllib.request.Request(f"{base_url}/v1/chat/completions", method="POST")
    request.add_header("Authorization", f"Bearer {key}")
    request.add_header("Content-Type", "application/json")
    messages = ([{"role": "system", "content": system}] if system else []) + \
        [{"role": "user", "content": PROMPT}]
    payload = json.dumps({"messages": messages, "max_tokens": max_tokens, "temperature": 0.7,
                          "stream": True, "stream_options": {"include_usage": True}}).encode()
    started = time.time()
    first = None
    parts: list[str] = []
    usage = None
    with urllib.request.urlopen(request, payload, timeout=900) as response:
        for raw in response:
            line = raw.decode(errors="replace").strip()
            if not line.startswith("data: "):
                continue
            body = line[6:]
            if body == "[DONE]":
                break
            chunk = json.loads(body)
            usage = chunk.get("usage") or usage
            choices = chunk.get("choices") or []
            if choices:
                delta = choices[0].get("delta", {})
                if delta.get("content"):
                    first = first or time.time()
                    parts.append(delta["content"])
                if choices[0].get("finish_reason") == "length":
                    break
    return {"reply": "".join(parts), "usage": usage, "ttft": (first - started) if first else None,
            "seconds": time.time() - started}


def run_benchmark(server=None, runs: int = 3, max_tokens: int = 512, base_url: str | None = None,
                  key: str | None = None, system: str | None = None) -> dict:
    if server is not None:
        base_url, key = server.base_url, server.api_key
    results: list[dict] = []
    speeds: list[float] = []
    first_tokens: list[float] = []
    for index in range(runs):
        outcome = _chat(base_url, key, max_tokens, system)
        source = extract_python(outcome["reply"])
        check = syntax_check(source)
        tokens = (outcome.get("usage") or {}).get("completion_tokens") or 0
        speed = tokens / outcome["seconds"] if tokens > 1 and outcome["seconds"] > 0 else None
        if speed:
            speeds.append(speed)
        if outcome["ttft"]:
            first_tokens.append(outcome["ttft"])
        results.append({"run": index + 1, **check, "completion_tokens": tokens,
                        "seconds": round(outcome["seconds"], 2)})
    valid_runs = sum(1 for item in results if item["valid"])
    return {
        "app": "NethCode Mini",
        "runs": runs,
        "valid_runs": valid_runs,
        "syntax_valid_rate": round(valid_runs / max(1, runs), 3),
        "syntax_checks": results,
        "generated_bytes": sum(item["bytes"] for item in results),
        "tokens_per_second": round(sum(speeds) / len(speeds), 2) if speeds else None,
        "first_token_seconds": round(sum(first_tokens) / len(first_tokens), 3) if first_tokens else None,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--max-tokens", type=int, default=512)
    parser.add_argument("--system", default=None, help="extra system prompt, e.g. effort guidance")
    args = parser.parse_args()
    report = run_benchmark(runs=args.runs, max_tokens=args.max_tokens, base_url=args.base,
                           key=args.key, system=args.system)
    print(json.dumps(report, indent=2))
    if report["valid_runs"] == 0:
        raise SystemExit("No generated NethCode Mini source passed the Python syntax check.")


if __name__ == "__main__":
    main()
