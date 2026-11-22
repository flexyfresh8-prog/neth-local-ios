# Dependency manifest

## iPad app (Neth Local 3.8.2)

| Component | Version / pin | Source |
| --- | --- | --- |
| llama.cpp (iOS device framework) | pinned by `scripts/prepare-engine.py` | built from source in `scripts/build-ipa.sh` |
| HauhauCS Qwen3.5 4B Uncensored Q4_K_M | pinned revision, SHA-256 checked | Hugging Face |
| Qwen vision projector (optional) | pinned revision, SHA-256 checked | Hugging Face |
| SQLite (system) | iOS system library | — |

No third-party Swift packages: the app links only llama.framework, sqlite3 and
system frameworks.

## Neth Cloud (Colab notebook)

| Component | Version / pin | Source |
| --- | --- | --- |
| llama.cpp CUDA build | b12631 ubuntu-cuda-12.8-x64 + matching cudart | GitHub releases (official ggml-org assets) |
| GPT-OSS-20B-Uncensored-HauhauCS-Aggressive | MXFP4 GGUF, 12.1 GB, size + GGUF header verified | Hugging Face |
| huggingface_hub | latest (Colab) | PyPI |

The notebook downloads only from the official `ggml-org/llama.cpp` release
assets and the pinned HF repo, verifies sizes, and checks the downloaded
server against its own `/health` before tunnelling.

## NethHost v2.0.0 (`host/`)

Pinned ranges in `host/requirements.txt`:

| Package | Range | Why |
| --- | --- | --- |
| fastapi | >=0.115,<1.0 | REST + WebSocket API |
| uvicorn[standard] | >=0.30,<1.0 | ASGI server |
| httpx | >=0.27,<1.0 | backend client + preview proxy |

Optional:

| Package | Purpose |
| --- | --- |
| playwright (+chromium) | browser_open / console error capture |
| pyinstaller >=6.10 | Windows packaging (CI only) |
| pytest, pytest-asyncio | test suite (CI only) |

External programs used when present (never auto-installed system-wide):
git, node/npm (JS projects), Python 3.12 (the packaged runtime).

Integrity: the PyInstaller build runs on GitHub's windows-2022 runner from the
committed spec; the workflow smoke-tests the produced executable (boot,
`/healthz`, 401 auth gate) before publishing the artifact.
