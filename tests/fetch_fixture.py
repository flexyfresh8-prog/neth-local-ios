#!/usr/bin/env python3
"""Fetch the cloud-contract test fixtures: a prebuilt llama.cpp server and a small GGUF.

The llama.cpp build is the official b12631 ubuntu-x64 release (CPU build is enough for the
contract tests). The model repository is not assumed: the GGUF filename is discovered from
the repository listing at runtime (Hugging Face, with ModelScope as a mirror fallback).
"""

import argparse
import json
import shutil
import sys
import tarfile
import urllib.error
import urllib.request
from pathlib import Path

RELEASE_BASE = "https://github.com/ggml-org/llama.cpp/releases/download/b12631"
SERVER_ARCHIVE = "llama-b12631-bin-ubuntu-x64.tar.gz"

MODEL_REPOS = [
    ("hf", "HuggingFaceTB/SmolLM2-135M-Instruct-GGUF"),
    ("hf", "Qwen/Qwen2.5-0.5B-Instruct-GGUF"),
    ("modelscope", "Qwen/Qwen2.5-0.5B-Instruct-GGUF"),
]
def get_json(url: str, timeout: float = 30):
    request = urllib.request.Request(url, headers={"User-Agent": "neth-cloud-tests/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode())


def download(url: str, target: Path, timeout: float = 600) -> Path:
    partial = target.with_suffix(target.suffix + ".part")
    expected = partial.stat().st_size if partial.is_file() else 0
    request = urllib.request.Request(url, headers={"User-Agent": "neth-cloud-tests/1.0"})
    if expected:
        request.add_header("Range", f"bytes={expected}-")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response, partial.open("ab") as output:
            shutil.copyfileobj(response, output, 1 << 20)
    except urllib.error.HTTPError as error:
        if not (error.code == 416 and partial.is_file()):
            raise
    size = partial.stat().st_size
    if size == 0:
        raise RuntimeError(f"Download produced no data: {url}")
    partial.replace(target)
    return target


def server_candidates(provider: str, name: str) -> list[tuple[str, int]]:
    """Return (url, size) for GGUF files, preferring small q4_k_m checkpoints."""
    if provider == "hf":
        entries = get_json(f"https://huggingface.co/api/models/{name}/tree/main")
        files = [(e["path"], e.get("size", 0)) for e in entries
                 if e.get("path", "").lower().endswith(".gguf") and e.get("type") == "file"]
        base = f"https://huggingface.co/{name}/resolve/main"
    elif provider == "modelscope":
        payload = get_json(f"https://modelscope.cn/api/v1/models/{name}/repo/files?Recursive=true")
        files = [(e["Path"], e.get("Size", 0)) for e in payload.get("Data", {}).get("Files", [])
                 if str(e.get("Path", "")).lower().endswith(".gguf")]
        base = f"https://modelscope.cn/models/{name}/resolve/master"
    else:
        raise ValueError(f"Unknown provider: {provider}")
    def rank(item):
        filename, size = item
        lowered = filename.lower()
        return (0 if "q4_k_m" in lowered else 1 if "q4" in lowered else 2, size)
    return [(f"{base}/{path}", size) for path, size in sorted(files, key=rank)]


def fetch_model(dest: Path) -> tuple[Path, str]:
    tried = []
    for provider, name in MODEL_REPOS:
        try:
            candidates = server_candidates(provider, name)
        except Exception as error:  # noqa: BLE001 - try the next mirror
            tried.append(f"{provider}:{name}: {error}")
            continue
        if not candidates:
            tried.append(f"{provider}:{name}: no GGUF files listed")
            continue
        url, size = candidates[0]
        filename = url.rsplit("/", 1)[-1]
        target = dest / filename
        try:
            print(f"Fetching {provider}:{name} → {filename} ({size:,} bytes)…", flush=True)
            download(url, target)
        except Exception as error:  # noqa: BLE001
            tried.append(f"{provider}:{name}: download failed: {error}")
            continue
        return target, f"{provider}:{name}"
    raise SystemExit("No fixture model could be downloaded:\n  " + "\n  ".join(tried))


def fetch_server(dest: Path) -> Path:
    # The release keeps llama-server next to its libllama-*.so files; it must run in place.
    extract = dest / "llama-b12631"
    if not extract.is_dir():
        archive = dest / SERVER_ARCHIVE
        if not archive.is_file():
            print(f"Fetching {SERVER_ARCHIVE}…", flush=True)
            download(f"{RELEASE_BASE}/{SERVER_ARCHIVE}", archive)
        if extract.is_dir():
            shutil.rmtree(extract)
        with tarfile.open(archive) as tar:
            tar.extractall(dest, filter="data")
    for binary in sorted(extract.glob("**/llama-server")):
        if binary.is_file() and _runs(binary):
            return binary
    raise SystemExit("The downloaded llama-server does not run on this machine.")


def _runs(binary: Path) -> bool:
    import subprocess
    try:
        probe = subprocess.run([str(binary), "--version"], capture_output=True, text=True, timeout=60)
        return probe.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dest", default=str(Path(__file__).resolve().parent / "fixtures"))
    args = parser.parse_args()
    dest = Path(args.dest)
    dest.mkdir(parents=True, exist_ok=True)
    manifest_path = dest / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.is_file() else {}
    if not manifest.get("server") or not Path(manifest["server"]).is_file():
        server = fetch_server(dest)
        manifest["server"] = str(server)
        print(f"llama-server ready: {server}")
    if not manifest.get("model") or not Path(manifest["model"]).is_file():
        model, repo = fetch_model(dest)
        manifest["model"] = str(model)
        manifest["model_repo"] = repo
        print(f"Fixture model ready: {model}")
    manifest_path.write_text(json.dumps(manifest, indent=2))
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    try:
        main()
    except SystemExit as error:
        print(error, file=sys.stderr)
        raise
