#!/usr/bin/env python3
"""Neth Cloud launcher: serve GPT-OSS-20B-Uncensored-HauhauCS-Aggressive (MXFP4 GGUF)
through llama.cpp's OpenAI-compatible server for the Neth Local iPad app.

Subcommands (all restartable; nothing is hardcoded to a specific tunnel URL):
  gpu       Verify the NVIDIA GPU, driver and VRAM against the known T4 profile.
  discover  Find, extract or auto-download the prebuilt llama.cpp CUDA release (no rebuild).
  download  Download the GGUF from Hugging Face (resumable, reuses the HF cache).
  verify    Check the GGUF file: size, magic, version, optional deep SHA-256.
  context   Report VRAM headroom and a recommended context size.
  serve     Launch llama-server and wait until /health reports ok.
  health    Probe /health, /v1/models, /props and confirm the API key is enforced.
  stream    One streaming chat completion; prints tokens and the reasoning channel.
  perf      Measure load status, prompt/generation speed, TTFT and VRAM.
  tunnel    Start a verified cloudflared quick tunnel and print the NETHCLOUD1 connect code.
  stop      Stop the tunnel and the server started by `serve`.

The model file name is verified against the Hugging Face repository listing at
runtime; the values below are the expectation, not an assumption.
"""

import argparse
import base64
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

REPO_ID = "HauhauCS/GPT-OSS-20B-Uncensored-HauhauCS-Aggressive"
EXPECTED_FILES = ["GPT-OSS-20B-Uncensored-HauhauCS-MXFP4-Aggressive.gguf"]
EXPECTED_BYTES = 12_109_565_888
BASE_DIR = Path("/content/nethcloud")
STATE_FILE = BASE_DIR / "session.json"
LOG_FILE = BASE_DIR / "llama-server.log"
BIN_DIRS = [Path("/content/llama-prebuilt"), Path("/content/llama.cpp"), Path("/content")]
MODEL_SEARCH_DIRS = [BASE_DIR, Path("/content"), Path("/root/.cache/huggingface")]
KV_BYTES_PER_TOKEN = 49_152          # gpt-oss-20b: 24 layers, 8 KV heads, head 64, f16
VRAM_OVERHEAD_BYTES = 1_600_000_000  # CUDA context, activations, compute buffers


def say(message: str) -> None:
    print(message, flush=True)


def fail(message: str) -> None:
    raise SystemExit(f"Neth Cloud: {message}")


def run(command, timeout=None, check=False, env=None):
    return subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=check, env=env)


# --------------------------------------------------------------------------- GPU


def gpu() -> dict:
    if not shutil.which("nvidia-smi"):
        fail("No NVIDIA GPU is visible. In Colab choose Runtime → Change runtime type → T4 GPU, then rerun.")
    info = run(["nvidia-smi", "--query-gpu=name,memory.total,memory.used,driver_version",
                "--format=csv,noheader,nounits"])
    if info.returncode != 0:
        fail(f"nvidia-smi failed: {info.stderr.strip()}")
    name, total, used, driver = [part.strip() for part in info.stdout.strip().split("\n")[0].split(",")]
    total_bytes = float(total) * 1024 * 1024
    free_bytes = (float(total) - float(used)) * 1024 * 1024
    say(f"GPU: {name}")
    say(f"Driver: {driver}")
    say(f"VRAM: {float(total) / 1024:.1f} GiB total, {float(used) / 1024:.1f} GiB used, {free_bytes / 1024 ** 3:.1f} GiB free")
    if "T4" in name:
        say("Matches the known working profile (Tesla T4, 15 GiB).")
    else:
        say(f"Note: the verified profile is a Tesla T4; {name} is untested with this notebook.")
    try:
        toolkit = run(["nvidia-smi"]).stdout
        match = re.search(r"CUDA Version:\s*([0-9.]+)", toolkit)
        if match:
            say(f"CUDA runtime reported by the driver: {match.group(1)}")
    except Exception:
        pass
    return {"name": name, "total_bytes": int(total_bytes), "free_bytes": int(free_bytes),
            "driver": driver}


# --------------------------------------------------------------------- discovery

LLAMA_RELEASE_TAG = "b12631"
LLAMA_RELEASE_BASE = f"https://github.com/ggml-org/llama.cpp/releases/download/{LLAMA_RELEASE_TAG}"
# Verified release assets (HEAD-checked 2026-11-22): 220 MB server + 594 MB CUDA runtime.
LLAMA_PACKAGES = [
    "llama-b12631-bin-ubuntu-cuda-12.8-x64.tar.gz",
    "cudart-llama-b12631-bin-ubuntu-cuda-12.8-x64.tar.gz",
]


def _extract_archive(archive: Path) -> None:
    marker = archive.with_name(archive.name + ".extracted")
    if marker.exists():
        return
    say(f"Extracting {archive.name} …")
    if archive.name.endswith((".tar.gz", ".tgz")):
        with tarfile.open(archive) as bundle:
            bundle.extractall(archive.parent, filter="data")
    elif archive.name.endswith(".zip"):
        target = archive.parent / archive.stem
        target.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(target)
    else:
        return
    marker.write_text("extracted\n")


def _extract_archives() -> None:
    """Extract any prebuilt release archives found under the bin dirs (idempotent)."""
    for base in BIN_DIRS:
        if not base.is_dir():
            continue
        for archive in sorted(base.glob("**/*")):
            if archive.is_file() and archive.name.endswith((".tar.gz", ".tgz", ".zip")) \
                    and not archive.name.endswith(".extracted"):
                try:
                    _extract_archive(archive)
                except Exception as error:  # noqa: BLE001 - keep trying the other archives
                    say(f"Could not extract {archive}: {error}")


def _download(url: str, dest: Path) -> None:
    if dest.exists() and dest.stat().st_size > 50_000_000:
        say(f"Already present: {dest.name} ({dest.stat().st_size:,} bytes)")
        return
    partial = dest.with_suffix(dest.suffix + ".part")
    headers = {"User-Agent": "neth-local-colab/3.7.0"}
    offset = 0
    if partial.exists():
        offset = partial.stat().st_size
        headers["Range"] = f"bytes={offset}-"
        say(f"Resuming {dest.name} from {offset:,} bytes")
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=120) as response:
        if offset and response.status != 206:
            say("Server ignored the resume request; restarting this download.")
            offset = 0
            partial.unlink()
        total = response.headers.get("Content-Length")
        total = int(total) + offset if total else None
        last_report = offset
        with partial.open("ab") as handle:
            received = offset
            while True:
                block = response.read(1 << 22)
                if not block:
                    break
                handle.write(block)
                received += len(block)
                if received - last_report >= (50 << 20):
                    last_report = received
                    progress = f"{received / 1e6:,.0f} MB" + (f" / {total / 1e6:,.0f} MB" if total else "")
                    say(f"  {dest.name}: {progress}")
    partial.rename(dest)
    say(f"Downloaded: {dest} ({dest.stat().st_size:,} bytes)")


def _fetch_prebuilt() -> None:
    base = Path("/content/llama-prebuilt")
    base.mkdir(parents=True, exist_ok=True)
    say(f"Fetching the official llama.cpp {LLAMA_RELEASE_TAG} prebuilt CUDA 12.8 release (~780 MB total)…")
    for package in LLAMA_PACKAGES:
        _download(f"{LLAMA_RELEASE_BASE}/{package}", base / package)
    for archive in sorted(base.glob("*.tar.gz")):
        try:
            _extract_archive(archive)
        except Exception as error:  # noqa: BLE001 - report and continue
            say(f"Could not extract {archive}: {error}")


def _library_dirs(server: Path) -> list:
    """Every directory holding .so files inside the extracted release tree.

    The CUDA release ships llama-server plus its shared libs, and the separate
    cudart archive adds libcudart/libcublas; their layout differs between
    releases, so collecting the .so directories is safer than guessing one.
    """
    root = server.parent
    for base in BIN_DIRS:
        if base.is_dir() and base in server.parents:
            root = base
            break
    dirs = {str(server.parent)}
    try:
        for shared in root.glob("**/*.so*"):
            dirs.add(str(shared.parent))
    except Exception:  # noqa: BLE001 - the binary's own directory is the fallback
        pass
    return sorted(dirs)


def _server_env(server: Path) -> dict:
    env = os.environ.copy()
    existing = env.get("LD_LIBRARY_PATH")
    env["LD_LIBRARY_PATH"] = ":".join(_library_dirs(server) + ([existing] if existing else []))
    return env


def _probe(path: Path) -> bool:
    result = run([str(path), "--version"], timeout=60, env=_server_env(path))
    if result.returncode == 0:
        version = result.stdout.strip().splitlines()[0] if result.stdout.strip() else "llama-server"
        say(f"Found llama-server: {path}")
        say(f"Version: {version}")
        return True
    first = result.stderr.strip().splitlines()[0] if result.stderr.strip() else "no output"
    say(f"Skipping {path}: {first}")
    if "shared libraries" in result.stderr.lower():
        say("  (missing shared libraries — launches set LD_LIBRARY_PATH automatically, "
            "so this usually means the binary was built for a different CUDA version)")
    return False


def discover() -> Path:
    _extract_archives()
    candidates = []
    for base in BIN_DIRS:
        if base.is_dir():
            for path in sorted(base.glob("**/llama-server")):
                if path.is_file() and os.access(path, os.X_OK) and path not in candidates:
                    candidates.append(path)
    on_path = shutil.which("llama-server")
    if on_path and Path(on_path) not in candidates:
        candidates.append(Path(on_path))
    for path in candidates:
        if _probe(path):
            return path
    say("No runnable llama-server yet. Downloading the official prebuilt release…")
    _fetch_prebuilt()
    for base in BIN_DIRS:
        if base.is_dir():
            for path in sorted(base.glob("**/llama-server")):
                if path.is_file() and os.access(path, os.X_OK) and _probe(path):
                    return path
    fail("llama-server could not be provisioned automatically. Download BOTH archives below, upload them "
         "to /content/llama-prebuilt (Colab file panel), then rerun this cell:\n  "
         + "\n  ".join(f"{LLAMA_RELEASE_BASE}/{name}" for name in LLAMA_PACKAGES))


# ---------------------------------------------------------------------- download


def _hub_download():
    try:
        from huggingface_hub import list_repo_files
    except ImportError:
        fail("huggingface_hub is missing. Run the dependency cell (pip install huggingface_hub) first.")
    return list_repo_files


def resolve_filename() -> str:
    token = os.environ.get("HF_TOKEN")
    files = _hub_download()(repo_id=REPO_ID, token=token)
    ggufs = [name for name in files if name.lower().endswith(".gguf")]
    if not ggufs:
        fail(f"{REPO_ID} exposes no GGUF files; found: {', '.join(sorted(files))[:400]}")
    for expected in EXPECTED_FILES:
        if expected in ggufs:
            say(f"Repository file confirmed: {expected}")
            return expected
    mxfp4 = [name for name in ggufs if "mxfp4" in name.lower()]
    chosen = mxfp4[0] if mxfp4 else sorted(ggufs)[0]
    say(f"Repository listing differs from the expected file. Using: {chosen}")
    say(f"Available GGUF files: {', '.join(sorted(ggufs))}")
    return chosen


def local_model_path() -> Path | None:
    for base in MODEL_SEARCH_DIRS:
        if not base.is_dir():
            continue
        for path in sorted(base.glob("**/*.gguf")):
            size = path.stat().st_size
            if size > 1_000_000_000 or path.name.lower() in [n.lower() for n in EXPECTED_FILES]:
                return path
    return None


def download() -> Path:
    existing = local_model_path()
    if existing is not None:
        say(f"Reusing cached model: {existing} ({existing.stat().st_size:,} bytes)")
        return existing
    filename = resolve_filename()
    try:
        from huggingface_hub import hf_hub_download
    except ImportError:
        fail("huggingface_hub is missing. Run the dependency cell first.")
    say(f"Downloading {REPO_ID}/{filename} (expected ≈{EXPECTED_BYTES:,} bytes; resumable)…")
    token = os.environ.get("HF_TOKEN")
    try:
        path = hf_hub_download(repo_id=REPO_ID, filename=filename, local_dir=BASE_DIR, token=token)
    except Exception as error:  # noqa: BLE001 - report the real download problem
        fail(f"Download failed: {error}. The repo is public; set HF_TOKEN if Hugging Face rate-limits this session.")
    model = Path(path)
    say(f"Saved: {model} ({model.stat().st_size:,} bytes)")
    return model


# ------------------------------------------------------------------------ verify


def verify(model: Path | None = None, deep_hash: bool = False) -> Path:
    model = model or local_model_path() or fail("No GGUF found. Run the download cell first.")
    size = model.stat().st_size
    say(f"File: {model}")
    say(f"Size: {size:,} bytes")
    if size != EXPECTED_BYTES:
        say(f"Size differs from the verified MXFP4 checkpoint ({EXPECTED_BYTES:,} bytes). "
            "The repository may have been updated; llama.cpp will reject an incompatible file.")
    with model.open("rb") as handle:
        magic = handle.read(4)
        version_bytes = handle.read(4)
    if magic != b"GGUF":
        fail("This file is not a GGUF model (bad magic).")
    version = int.from_bytes(version_bytes, "little")
    say(f"GGUF version: {version}")
    if version < 2:
        fail("GGUF version is too old for llama.cpp b12631.")
    if deep_hash:
        import hashlib
        digest = hashlib.sha256()
        started = time.time()
        with model.open("rb") as handle:
            for block in iter(lambda: handle.read(1 << 22), b""):
                digest.update(block)
        say(f"SHA-256: {digest.hexdigest()} (took {time.time() - started:.0f}s)")
    say("Integrity checks passed. The final compatibility test is the model load in `serve`.")
    return model


# ----------------------------------------------------------------------- context


def context_report() -> dict:
    info = gpu()
    model = local_model_path()
    weights = model.stat().st_size if model else EXPECTED_BYTES
    budget = info["total_bytes"] - weights - VRAM_OVERHEAD_BYTES
    say(f"Model weights ≈ {weights / 1024 ** 3:.2f} GiB, fixed overhead ≈ {VRAM_OVERHEAD_BYTES / 1024 ** 3:.1f} GiB")
    say("KV cache (f16, GPT-OSS-20B) ≈ 48 KiB per token:")
    chosen = 2048
    for tokens in [2048, 4096, 8192, 16384, 32768]:
        kib = KV_BYTES_PER_TOKEN * tokens
        fits = kib <= budget
        say(f"  {tokens:>6} tokens → {kib / 1024 ** 2:6.0f} MiB  {'fits' if fits else 'too large'}")
        if fits:
            chosen = tokens
    recommended = min(chosen, 32768)
    say(f"Recommended context: {recommended} (default launch uses 2048; raise it only after measuring VRAM)")
    (BASE_DIR / "context.json").write_text(json.dumps({"recommended": recommended, "budget": budget}))
    return {"recommended": recommended}


# ------------------------------------------------------------------------- serve


def read_state() -> dict:
    if STATE_FILE.is_file():
        return json.loads(STATE_FILE.read_text())
    return {}


def _wait_health(port: int, api_key: str, deadline: float, log) -> None:
    url = f"http://127.0.0.1:{port}/health"
    while time.time() < deadline:
        if log and log.poll() is not None:
            tail = LOG_FILE.read_text(errors="replace").splitlines()[-25:] if LOG_FILE.is_file() else []
            fail("llama-server exited during startup:\n  " + "\n  ".join(tail))
        try:
            request = urllib.request.Request(url, headers={"Authorization": f"Bearer {api_key}"})
            with urllib.request.urlopen(request, timeout=5) as response:
                if response.status == 200:
                    return
        except urllib.error.HTTPError as error:
            if error.code != 503:
                fail(f"Unexpected /health response: HTTP {error.code}")
        except Exception:  # noqa: BLE001 - server not accepting yet
            pass
        time.sleep(2)
    fail("Timed out waiting for /health. Inspect /content/nethcloud/llama-server.log.")


def serve(model: Path | None, server: Path | None, port: int, context: int, api_key: str,
          flash_attn: str = "on", threads: int = 0, ngl: int = 999, batch: int = 2048,
          ubatch: int = 512, kv_cache: str = "f16") -> None:
    BASE_DIR.mkdir(parents=True, exist_ok=True)
    model = model or local_model_path() or fail("No model file; run the download cell first.")
    server = server or discover()
    threads = threads or max(2, (os.cpu_count() or 4) - 1)
    attempts = [flash_attn, "off"] if flash_attn != "off" else ["off"]
    for attempt in attempts:
        command = [str(server), "-m", str(model), "--host", "127.0.0.1", "--port", str(port),
                   "-ngl", str(ngl), "-c", str(context), "--jinja", "--api-key", api_key,
                   "-b", str(batch), "-ub", str(ubatch), "-t", str(threads)]
        if kv_cache != "f16":
            command += ["-ctk", kv_cache, "-ctv", kv_cache]
        if attempt != "off":
            command += ["--flash-attn", attempt]
        say(f"Launching: {' '.join(command[:-1])} ***")
        log_handle = LOG_FILE.open("w")
        process = subprocess.Popen(command, stdout=log_handle, stderr=subprocess.STDOUT,
                                   env=_server_env(server))
        state = {"server_pid": process.pid, "port": port, "api_key": api_key,
                 "model_path": str(model), "context": context}
        STATE_FILE.write_text(json.dumps(state))
        try:
            _wait_health(port, api_key, deadline=time.time() + 900, log=process)
        except SystemExit as error:
            process.terminate()
            if attempt == attempts[-1]:
                raise
            say(f"Launch with --flash-attn {attempt} failed; retrying without flash attention.")
            say(str(error))
            continue
        say("llama-server is healthy.")
        _offload_report(state)
        return


def _offload_report(state: dict) -> None:
    if LOG_FILE.is_file():
        for line in LOG_FILE.read_text(errors="replace").splitlines():
            low = line.lower()
            if "offloaded" in low or ("cuda" in low and "buffer size" in low) or "kv cache size" in low \
                    or "n_ctx" in low:
                say(f"  {line.strip()}")
    info = run(["nvidia-smi", "--query-gpu=memory.used,memory.total,utilization.gpu",
                "--format=csv,noheader,nounits"])
    if info.returncode == 0:
        used, total, util = [part.strip() for part in info.stdout.split(",")]
        say(f"  VRAM after load: {float(used) / 1024:.2f} / {float(total) / 1024:.1f} GiB (GPU util {util}%)")
    props = _api(state, "props")
    if props:
        n_ctx = props.get("default_generation_settings", {}).get("n_ctx")
        if n_ctx:
            say(f"  Server context window: {n_ctx} tokens")
        say("  Chat template: llama.cpp server default (--jinja; Harmony for GPT-OSS checkpoints)")


def _api(state: dict, path: str, method: str = "GET", payload: dict | None = None,
         auth: bool = True, timeout: float = 120) -> dict | None:
    request = urllib.request.Request(f"http://127.0.0.1:{state['port']}/{path}", method=method)
    if auth:
        request.add_header("Authorization", f"Bearer {state['api_key']}")
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, data=data, timeout=timeout) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as error:
        return {"_status": error.code, "_body": error.read().decode(errors="replace")}
    except Exception as error:  # noqa: BLE001
        return {"_status": 0, "_body": str(error)}


# ------------------------------------------------------------------- health/perf


def _port_diagnosis(port: int) -> None:
    """Print which process, if any, listens on the server port — identifies impostors."""
    probe = run(["ss", "-ltnp"], timeout=15)
    lines = [line.strip() for line in probe.stdout.splitlines() if f":{port} " in line]
    if lines:
        for line in lines:
            say(f"  listening: {line}")
    else:
        say(f"  nothing is listening on 127.0.0.1:{port}")


def health() -> None:
    state = read_state() or fail("No running server. Run the serve cell first.")
    result = _api(state, "health")
    if result != {"status": "ok"}:
        fail(f"/health is not ok: {result}")
    say("/health: ok (200)")
    models = _api(state, "v1/models")
    ids = [entry.get("id") for entry in models.get("data", [])] if isinstance(models, dict) else []
    say(f"/v1/models: {ids}")
    props = _api(state, "props") or {}
    n_ctx = props.get("default_generation_settings", {}).get("n_ctx")
    say(f"/props context window: {n_ctx}")
    no_auth = _api(state, "v1/models", auth=False)
    rejected = isinstance(no_auth, dict) and no_auth.get("_status") in (401, 403)
    say(f"Unauthenticated request rejected: {'yes (HTTP 401)' if rejected else 'NO — check --api-key!'}")
    if not rejected:
        fail("The server accepted a request without an API key; relaunch with --api-key.")


def stream(state: dict, prompt: str, limit: int = 128) -> tuple[str, dict | None]:
    url = f"http://127.0.0.1:{state['port']}/v1/chat/completions"
    request = urllib.request.Request(url, method="POST")
    request.add_header("Authorization", f"Bearer {state['api_key']}")
    request.add_header("Content-Type", "application/json")
    payload = {
        "messages": [{"role": "user", "content": prompt}],
        "stream": True,
        "max_tokens": limit,
        "stream_options": {"include_usage": True},
    }
    text_parts: list[str] = []
    reasoning_parts: list[str] = []
    usage = None
    started = time.time()
    first = None
    try:
        with urllib.request.urlopen(request, json.dumps(payload).encode(), timeout=600) as response:
            for raw in response:
                line = raw.decode(errors="replace").strip()
                if not line.startswith("data: "):
                    continue
                body = line[6:]
                if body == "[DONE]":
                    break
                chunk = json.loads(body)
                usage = chunk.get("usage") or usage
                choice = (chunk.get("choices") or [{}])[0]
                delta = choice.get("delta", {})
                if delta.get("reasoning_content"):
                    reasoning_parts.append(delta["reasoning_content"])
                    first = first or time.time()
                if delta.get("content"):
                    text_parts.append(delta["content"])
                    first = first or time.time()
                if choice.get("finish_reason") == "length":
                    break
    except urllib.error.HTTPError as error:
        body_text = error.read(4096).decode(errors="replace")
        _port_diagnosis(state["port"])
        fail(f"POST {url} returned HTTP {error.code}. Response body: {body_text[:400]}")
    except Exception as error:  # noqa: BLE001 - unreachable server or mid-stream drop
        _port_diagnosis(state["port"])
        fail(f"POST {url} failed: {error}. If nothing is listening, llama-server exited — "
             "rerun the serve cell (cell 7) and wait for 'llama-server is healthy'.")
    return "".join(text_parts), {
        "reasoning": "".join(reasoning_parts),
        "usage": usage,
        "ttft": (first - started) if first else None,
        "seconds": time.time() - started,
    }


def stream_test() -> None:
    state = read_state() or fail("No running server. Run the serve cell first.")
    text, info = stream(state, "Reply with exactly one short sentence about storage on the iPad.")
    say(f"Reasoning channel: {len(info['reasoning'])} characters")
    say(f"Final channel: {text.strip()[:300]}")
    usage = info.get("usage") or {}
    say(f"TTFT: {info['ttft']:.2f}s" if info.get("ttft") else "TTFT: n/a")
    say(f"Usage: {usage}")
    if not text.strip() and not info["reasoning"].strip():
        fail("The streaming test produced no tokens.")
    say("Streaming test passed.")


def perf() -> None:
    state = read_state() or fail("No running server. Run the serve cell first.")
    say("Measuring one streaming request (second run warms the prompt cache)…")
    stream(state, "Write two sentences about GPU inference.", limit=160)
    text, info = stream(state, "Write two sentences about GPU inference.", limit=160)
    usage = info.get("usage") or {}
    tokens = usage.get("completion_tokens") or 0
    seconds = info.get("seconds") or 0
    if seconds > 0 and tokens > 0:
        say(f"Generation: {tokens} tokens in {seconds:.1f}s → {tokens / seconds:.1f} tok/s (includes TTFT)")
    if info.get("ttft"):
        say(f"First-token latency: {info['ttft']:.2f}s")
    info_gpu = run(["nvidia-smi", "--query-gpu=memory.used,utilization.gpu", "--format=csv,noheader,nounits"])
    if info_gpu.returncode == 0:
        used, util = info_gpu.stdout.strip().split(",")
        say(f"VRAM used: {float(used) / 1024:.2f} GiB · GPU utilisation {util.strip()}%")
    say("Compare with the earlier baseline (~51.9 tok/s for the official GPT-OSS-20B on T4); "
        "this is a measurement, not a guarantee.")


# ------------------------------------------------------------------------ tunnel

_TUNNEL_URL_RE = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com")


def _tunnel_alive(url: str) -> bool:
    """True if the public URL routes to the local llama-server through the tunnel.

    Any response from the origin counts — even 401/503, because llama-server
    answers those while loading or when auth is required. Cloudflare's
    dead-tunnel error page (HTTP 530 carrying "error code: 10xx", e.g. 1033) or
    a connection failure means the tunnel is not connected.
    """
    try:
        with urllib.request.urlopen(f"{url}/health", timeout=15) as response:
            return response.status < 500
    except urllib.error.HTTPError as error:
        if error.code == 530:
            return False  # Cloudflare's dead-tunnel status (1016/1033 pages)
        body = error.read(65536) or b""
        if error.code >= 500 and b"error code: 10" in body:
            return False
        return True  # 401/403/503 from the origin: the tunnel itself routes
    except Exception:  # noqa: BLE001 - refused/timeout/DNS: not routable
        return False


def _ensure_cloudflared() -> Path:
    binary = shutil.which("cloudflared") or (BASE_DIR / "bin" / "cloudflared")
    if not binary.is_file():
        (BASE_DIR / "bin").mkdir(parents=True, exist_ok=True)
        url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
        say(f"Downloading cloudflared from {url} …")
        try:
            urllib.request.urlretrieve(url, binary)
            binary.chmod(0o755)
        except Exception as error:  # noqa: BLE001
            fail(f"Could not download cloudflared: {error}. "
                 "Any HTTPS tunnel to the server port works (ngrok, your own VPS with SSH -L, frp, …).")
    version = run([str(binary), "--version"], timeout=60)
    say(f"cloudflared: {version.stdout.strip() or version.stderr.strip()}")
    return binary


def _spawn_tunnel(binary: Path, port: int):
    return subprocess.Popen([str(binary), "tunnel", "--url", f"http://127.0.0.1:{port}",
                             "--no-autoupdate", "--protocol", "http2"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def _tunnel_url(process) -> str | None:
    deadline = time.time() + 90
    while time.time() < deadline:
        line = process.stdout.readline()
        if not line and process.poll() is not None:
            return None
        match = _TUNNEL_URL_RE.search(line or "")
        if match:
            return match.group(0)
    return None


def _origin_ok(port: int) -> bool:
    """True if anything answers HTTP on the local server port (401/503 included)."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=10) as response:
            return True
    except urllib.error.HTTPError:
        return True  # an HTTP answer means the process is alive, whatever the status
    except Exception:  # noqa: BLE001 - refused/timeout: nothing listening
        return False


def tunnel(port: int, name: str) -> None:
    state = read_state() or fail("No running server. Run the serve cell first.")
    if not _origin_ok(port):
        _port_diagnosis(port)
        fail(f"llama-server is not answering on 127.0.0.1:{port} — the session state exists but the "
             "server process is gone (it exited, or the runtime dropped). Rerun the serve cell "
             "(cell 7), wait for 'llama-server is healthy', then rerun this cell.")
    name = name.strip("\"'").strip() or "Neth Cloud"  # Colab's ! passes quotes through verbatim
    old = state.get("tunnel_pid")
    if old:
        try:
            os.kill(old, signal.SIGTERM)
            say(f"Stopped the previous tunnel (pid {old}).")
            time.sleep(1)
        except (ProcessLookupError, PermissionError):
            pass
    binary = _ensure_cloudflared()
    public_url = None
    note = None
    for attempt in range(1, 4):
        process = _spawn_tunnel(binary, port)
        url = _tunnel_url(process)
        if not url:
            process.terminate()
            say(f"Attempt {attempt}/3: cloudflared did not produce a URL.")
            continue
        say(f"Attempt {attempt}/3: {url} — checking the tunnel routes to the server …")
        verified = False
        for _ in range(6):
            if _tunnel_alive(url):
                verified = True
                break
            if process.poll() is not None:
                break
            time.sleep(4)
        if not verified and _origin_ok(port) and process.poll() is None:
            # The public probe keeps failing while the origin is alive and cloudflared
            # holds its edge registration (the URL only appears after registration).
            # Cloudflare restricts some trycloudflare requests from datacenter IPs, so
            # a failed probe from inside Colab does not always mean a dead tunnel.
            verified = True
            note = ("The public URL did not answer from inside Colab (Cloudflare restricts some "
                    "trycloudflare requests from datacenter IPs). The server is alive locally and "
                    "the tunnel is registered — connect from the app; if it shows HTTP 530, rerun "
                    "this cell.")
            say("  Public probe failed, but the server is alive and the tunnel is registered.")
        if verified:
            public_url = url
            state["tunnel_pid"] = process.pid
            break
        process.terminate()
        say("The URL appeared but never routed to the server; starting a fresh tunnel.")
    if not public_url:
        fail("cloudflared could not establish a verified tunnel after 3 attempts "
             "(network blocked or Cloudflare rejected the quick tunnel). Any HTTPS tunnel "
             "to the server port works (ngrok, your own VPS with SSH -L, frp, …).")
    state["url"] = public_url
    STATE_FILE.write_text(json.dumps(state))
    code = base64.urlsafe_b64encode(json.dumps({
        "name": name, "url": public_url, "token": state["api_key"], "model": "gpt-oss-20b",
    }).encode()).decode().rstrip("=")
    say("")
    say("=" * 64)
    say("CONNECT NETH LOCAL (iPad):")
    say(f"  Public URL: {public_url}")
    say(f"  API key:    {state['api_key']}")
    say("  Paste this connect code into Models & context → Neth Cloud GPU → Add cloud server:")
    say(f"NETHCLOUD1.{code}")
    say("=" * 64)
    say("")
    if note:
        say(note)
    else:
        say("Verified: this URL routed to the server at print time. Quick tunnels are ephemeral —")
    say("if the app later shows HTTP 530 / error code 1033, the tunnel or the runtime dropped:")
    say("rerun THIS cell and paste the NEW code (an old code stays dead forever).")
    say("Keep this tab open and foregrounded. iPadOS suspends background Safari tabs quickly,")
    say("which disconnects free Colab runtimes — run Colab on a computer when possible.")
    say("For an always-on endpoint use a paid GPU host (GCP/AWS/Lambda/RunPod) and run the")
    say("same serve + tunnel steps there.")


def stop() -> None:
    state = read_state()
    for key, sig in (("tunnel_pid", signal.SIGTERM), ("server_pid", signal.SIGINT)):
        pid = state.get(key)
        if pid:
            try:
                os.kill(pid, sig)
                say(f"Stopped {key} (pid {pid}).")
            except ProcessLookupError:
                say(f"{key} was already gone.")
            except PermissionError as error:
                say(f"Could not stop {key}: {error}")
    time.sleep(2)
    pid = state.get("server_pid")
    if pid:
        try:
            os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    STATE_FILE.unlink(missing_ok=True)
    say("Shutdown complete. Re-run serve (and tunnel) to start again.")


# --------------------------------------------------------------------------- CLI


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["gpu", "discover", "download", "verify", "context", "serve",
                                            "health", "stream", "perf", "tunnel", "stop"])
    parser.add_argument("--model", type=Path, default=None)
    parser.add_argument("--server", type=Path, default=None)
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--context", type=int, default=2048)
    parser.add_argument("--api-key", default=None)
    parser.add_argument("--flash-attn", default="on", choices=["on", "off"])
    parser.add_argument("--ngl", type=int, default=999, help="GPU layers to offload (999 = all)")
    parser.add_argument("--batch", type=int, default=2048)
    parser.add_argument("--ubatch", type=int, default=512)
    parser.add_argument("--kv-cache", default="f16", choices=["f16", "q8_0", "q4_0"],
                        help="KV cache precision (-ctk/-ctv); q8_0 doubles the affordable context")
    parser.add_argument("--threads", type=int, default=0)
    parser.add_argument("--name", default="Neth Cloud T4")
    parser.add_argument("--deep-hash", action="store_true")
    args = parser.parse_args()

    BASE_DIR.mkdir(parents=True, exist_ok=True)
    if args.command == "gpu":
        gpu()
    elif args.command == "discover":
        discover()
    elif args.command == "download":
        download()
    elif args.command == "verify":
        verify(args.model, deep_hash=args.deep_hash)
    elif args.command == "context":
        context_report()
    elif args.command == "serve":
        api_key = args.api_key or os.environ.get("NETH_API_KEY")
        if not api_key:
            api_key = "nl-" + base64.urlsafe_b64encode(os.urandom(18)).decode().rstrip("=")
            say(f"Generated session API key: {api_key}")
        serve(args.model, args.server, args.port, args.context, api_key,
              flash_attn=args.flash_attn, threads=args.threads, ngl=args.ngl,
              batch=args.batch, ubatch=args.ubatch, kv_cache=args.kv_cache)
    elif args.command == "health":
        health()
    elif args.command == "stream":
        stream_test()
    elif args.command == "perf":
        perf()
    elif args.command == "tunnel":
        tunnel(args.port, args.name)
    elif args.command == "stop":
        stop()


if __name__ == "__main__":
    main()
