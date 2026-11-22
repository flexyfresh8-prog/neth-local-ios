# Neth Cloud GPU — GPT-OSS-20B Uncensored (Aggressive) as a remote backend (v3.7.0)

Neth Cloud connects Neth Local to a llama.cpp OpenAI-compatible server that you start on a
GPU host — the verified reference environment is a **Google Colab NVIDIA Tesla T4**. The
model is **HauhauCS/GPT-OSS-20B-Uncensored-HauhauCS-Aggressive** (MXFP4 GGUF), served by the
same llama.cpp generation your iPad already runs locally.

What is new in 3.7.0:

| Piece | Where | What it does |
| --- | --- | --- |
| Cloud backend | `App/NethCloud.swift` | `CloudServer` connect codes, keychain storage, health checks with retries, remote model discovery |
| Cloud engine | `App/CloudEngine.swift` | SSE streaming → the app's `EngineEvent` pipeline, reasoning-channel wrapping, cancellation, one retry before first token |
| Backend selector | `App/CloudPanel.swift`, `App/ModelsPanel.swift` | Compute device: This iPad / Paired Windows / **Neth Cloud GPU** (mutually exclusive) |
| Colab notebook | `colab/NethCloud_GPTOSS20B_Aggressive.ipynb` | 12 cells: GPU check → discover → deps → download → verify → context → serve → health → stream → perf → tunnel + connect code → shutdown |
| Launcher | `colab/serve_gptoss.py` | All server lifecycle logic (embedded verbatim in the notebook; also usable standalone on any host) |
| Quattro remote | unchanged flow | Tool selection and file plans run through the same grammar-constrained requests over the cloud backend |
| Contract tests | `tests/` | 11 pytest cases + the NethCode Mini benchmark against a real llama-server |

## Verified environment facts

Checked at implementation time, not assumed:

- The HF repository exposes a single GGUF: `GPT-OSS-20B-Uncensored-HauhauCS-MXFP4-Aggressive.gguf`,
  **12,109,565,888 bytes**, MXFP4 4-bit, `gpt-oss` architecture, **not gated** (no HF token
  needed). The launcher still re-checks the file listing at runtime and never hardcodes a
  different name.
- The app's bundled engine pins llama.cpp commit `8af68d4` (2026-11-19); the Colab prebuilt
  is release `b12631` (2026-11-22). Same-era builds, so a GGUF that loads on one loads on the
  other.
- Known working T4 profile: Tesla T4, 15 GiB VRAM, ~12.7 GiB RAM, driver 580.82.07, CUDA
  12.8 llama.cpp binaries (b12631 release `llama-b12631-bin-ubuntu-cuda-12.8-x64`), previous
  official-model measurement ≈ 51.9 tok/s. This checkpoint has different weights — treat
  that number as a baseline, not a target.
- llama-server b12631 accepts `grammar` and `chat_template_kwargs` in
  `/v1/chat/completions` (proven by `tests/test_cloud_contract.py` running against a real
  b12631 server), which is exactly what Quattro's structured tool selection needs.
- VRAM budget: 12.1 GiB weights + ~48 KiB/token KV (f16) + ~1.6 GiB CUDA overhead → a 2048
  context fits comfortably; 32768 is the practical ceiling. The notebook's context cell
  computes this from the live GPU before launching.

## Setup — Google Colab (interactive test environment)

1. Open [Colab](https://colab.research.google.com) and upload `colab/NethCloud_GPTOSS20B_Aggressive.ipynb`
   (or open it from Drive). *Runtime → Change runtime type → T4 GPU*.
2. Run cells 1–6 in order. Cell 2 writes the launcher from the notebook itself (the repo is
   private, so nothing is fetched from GitHub); cell 4 downloads the 12.1 GB checkpoint
   (resumable) and cell 6 prints the context recommendation.
3. Run cell 7 (`serve`). It launches `llama-server` with `-ngl 999 --jinja --api-key`,
   waits for `/health`, and prints the GPU-offload and VRAM diagnostics.
4. Run cells 8–10 to verify health, streaming (including the reasoning channel) and speed.
5. Run cell 11 (`tunnel`). It starts a `*.trycloudflare.com` quick tunnel and prints a
   `NETHCLOUD1.…` connect code — the HTTPS URL and this session's API key together.
6. On the iPad: **Models & context → Neth Cloud GPU → Add cloud server**, paste the connect
   code. The app health-checks the server, lists its models, and shows connection status,
   model, context, latency, speed and first-token time. Send a message; the composer shows
   `GPT-OSS 20B · Cloud`.
7. Cell 12 stops the server and the tunnel cleanly. After any Colab reconnect, rerun cells
   7 and 11 (a new tunnel URL and API key are printed each session — old codes stop working).

Free Colab runtimes are interactive, not hosting: they sleep when idle, disconnect after a
few hours, and Google may reclaim them. The notebook never pretends otherwise — it prints a
fresh code after every reconnect. For an always-on endpoint run `serve_gptoss.py` on a
dedicated GPU host (GCP/AWS/Lambda/RunPod): the launcher is plain Python plus your
llama.cpp binaries, and `tunnel` is optional when the host already has a public IP or TLS
endpoint (pass that URL when creating the connect code in the app).

## Setup — this iPad (what the app does with the code)

- The connect code is decoded and validated (HTTPS enforced; plain HTTP is only accepted
  for `127.0.0.1`/`localhost` so you can test against your own machine).
- Servers are stored in the iPad keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`),
  same as Windows pairing secrets. The API key never leaves the keychain except in the
  request's `Authorization: Bearer` header.
- Connection testing, `/v1/models` discovery and `/props` context reporting happen at
  connect time; network errors are retried once for flaky tunnels and reported honestly
  otherwise. When the cloud backend fails mid-session, the error suggests checking the
  notebook, and you can switch back to **This iPad** in one tap — conversation history is
  untouched by backend switches, and the app never silently swaps the model behind a chat.
- Photos are a local-model feature and are disabled while a cloud backend is selected
  (the remote server runs text-only).

## Quattro with the remote model

Quattro's flow does not branch on the backend: tool selection, project manifests and file
continuation are **grammar-constrained JSON generations** (`QuattroPlan.toolGrammar` /
`projectGrammar`), now sent to the cloud server in the same request. Every parsed tool call
is validated against the shortlisted catalog before `QuattroTools` executes it on the
device, so untrusted model text can never become a privileged action. Native Harmony
tool-call deltas, if a server ever emits them, are parsed and *reported*, never executed.

Reasoning: the server applies the model's own Harmony template (`--jinja`), and the app
maps the `reasoning_content` analysis channel into its existing `<think>` handling, so
effort levels (Quick/Balanced/Deep/Max) drive `chat_template_kwargs.reasoning_effort`
(low/medium/high) plus the usual output limits and continuation.

## Why there is no Google sign-in button

Google OAuth with PKCE (system browser, no password storage) would authenticate *identity*,
but Google offers no supported public API to launch, manage or provision Colab runtimes,
and the app deliberately does not scrape browser cookies or replay credentials. Since no
supported Google API is actually needed for the manual notebook-start workflow, 3.7.0 does
not add a decorative OAuth screen. If you later point Neth Cloud at a provider with a real
API (Vertex AI endpoints, RunPod, …), the connect-code flow already covers it.

## Tests

```bash
python -m pip install pytest requests
python tests/fetch_fixture.py --dest tests/fixtures   # b12631 CPU server + small GGUF (HF, ModelScope fallback)
python -m pytest tests/test_cloud_contract.py -v      # 11 contract tests against a live server
python tests/nethcode_mini_benchmark.py --base http://127.0.0.1:8199 --key <key> --runs 5
```

`test_cloud_contract.py` maps to the release checklist: startup, model loading, streaming,
multi-turn history, cancellation (mid-stream disconnect), authentication failures, Quattro
tool-grammar parsing, Quattro project manifests, Quattro file continuation, reconnection
and context reconfiguration, plus a benchmark smoke run. The **NethCode Mini benchmark**
asks the served model for a working NethCode Mini CLI application and checks every
generated Python source with `ast.parse`, reporting a syntax-valid rate, tokens/s and
first-token latency — it never marks a run valid without actually parsing it.

Not runnable outside Apple hardware: on-device Metal/CPU inference regression and iPad UI
behaviour. Those are covered by the macOS compile-and-run check (`scripts/check-chat.swift`,
which now also exercises connect-code parsing, Harmony SSE parsing and request-body
shaping) and the signed-device build in GitHub Actions.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| "Couldn’t reach the cloud server" on connect | The tunnel died or Colab disconnected. Rerun notebook cell 7 (serve) and cell 11 (tunnel), paste the **new** code — old codes never come back. |
| 401 on connect | Stale code from a previous session (each session generates a new key) or a typo. Paste the current code from cell 11. |
| 503 / "still loading" | The 12.1 GB checkpoint is still on its way into VRAM. Wait, or rerun the health cell; the first load after a fresh runtime takes minutes. |
| "Failed to initialize samplers: failed to parse grammar" | The client and server grammar formats disagree — this build (b12631) matches the app's GBNF; update the server before blaming the model. |
| CUDA out of memory at launch | Lower the context (cell 6 computes what fits) or run with `--flash-attn off`; the launcher retries without flash attention automatically if startup fails. |
| Generation stops at odd points | The reply hit the effort output limit; tap **Continue**. Context-limit finishes mean the chat history exceeded the server window — raise the context in the cloud section. |
| Speed far below ~51.9 tok/s | Free Colab shares hosts; rerun the perf cell, check `nvidia-smi` in the notebook for utilisation, and compare with the baseline honestly — this checkpoint's weights differ. |
| Model download interrupted | hf_hub resumes automatically; rerun the download cell (it also reuses any existing copy in the runtime). |
| The whole runtime vanished | Free Colab guarantees nothing. Rerun from cell 4 (model re-download) — storage is not persistent. |

## Security notes

- The server is never started without `--api-key`; the health cell fails hard if the server
  accepts an unauthenticated request.
- Connect codes contain the bearer key. Treat them like passwords: they live in the iPad
  keychain and the notebook output, nowhere else, and die with the Colab session.
- Nothing in the repo embeds a tunnel URL, API key or account credential.
- If you used a fine-grained GitHub token to fetch this repository, revoke it once you are
  done — it was pasted in plain text.

## What is new in 3.8.2

| Piece | Where | What changed |
| --- | --- | --- |
| Context negotiation | launcher `serve()` | `--context 0` (now the default in both notebooks) picks the largest window from a ladder (16,384 → 10,240 on the T4) based on the VRAM budget, then falls back down the ladder when the log shows an out-of-memory exit |
| KV cache | launcher `serve()` | q8_0 is selected automatically for windows ≥ 8,192 tokens, halving the KV cost so 10k+ fits next to the 12.1 GB model on a 16 GB T4 |
| 10,240 floor | launcher | auto mode never silently serves less than 10,240 tokens; if the GPU cannot fit it, the launch says so explicitly |
| Tools verification | launcher `tools_check()` | after `/health` passes, a real `tools` request is sent to `/v1/chat/completions`; the connect code is only printed after a native `tool_calls` answer proves the OpenAI tools API works |
| App side | `App/NethCloud.swift`, `CloudPanel.swift` | the app reads the server window from `/props`, shows it in the Cloud panel, and clamps requests to it; a 10,240-token option was added to the context picker |
| Tool-call surfacing | `App/CloudEngine.swift` | native GPT-OSS `tool_calls` are printed with names and arguments (execution stays in the Quattro catalog) |

Tuning: pass `--context 32768` to pin the ladder at 32k, or `--kv-cache f16|q8_0|q4_0`
to override the automatic KV precision. `--flash-attn off` remains an automatic
retry when a build rejects the flag.
