# NethHost v2.0.0 — setup, API and security

NethHost is the Windows host of the Neth Local autonomous coding environment.
The model runs on Neth Cloud (Colab T4), the interface runs on the iPad, and
NethHost executes everything real: files, commands, tests, git, previews and
project memory under `D:\NethLocal`.

```
iPad (Neth Local 3.8.2)          Colab (NethCloud.ipynb)
        │  authenticated REST/WS        │  OpenAI-compatible API
        ▼                               ▼
   NethHost.exe  ◄──── tool-calling loop ────►  GPT-OSS 20B on llama.cpp
        │
   D:\NethLocal\  (projects, memory, logs, previews)
```

## 1. Install

1. Download `NethHost-v2.0.0.exe` from the **NethHost-v2** artifact of the
   *Build Neth Local apps* workflow (or a release).
2. Double-click it. First launch creates the layout, databases and a local API
   key, then starts the server. No administrator rights are needed.

```
NethHost 2.0.0 first-launch setup:
  [  done] folders — D:\NethLocal
  [  done] config — api key ready
  [  done] databases — conversations.db, summaries.db, projects.db
  [  done] toolchain — python=3.12.x, git=2.45, node=v22 (optional), playwright=not installed
NethHost listening on http://192.168.x.x:8629  (iPad → Settings → Add host)
```

If `D:` is missing or smaller than 5 GB free, the host picks the largest fixed
drive; override with `--base X:\SomeDir`. Every setup step is recorded in
`config\install-state.json` and skipped when already done; `--repair
folders|config|databases|toolchain` redoes one step.

## 2. Connect the backend (Colab)

1. Run `colab/NethCloud_ONECELL.ipynb` in Colab (T4). Wait for the connect code
   (`NETHCLOUD1.…`). The notebook now verifies **10k+ context** and the
   **OpenAI tools API** before printing the code.
2. Configure the host (any machine with curl):

```bash
curl -X POST http://<host>:8629/api/backend/config \
  -H "Authorization: Bearer <NethHost key>" \
  -H "Content-Type: application/json" \
  -d '{"url": "<https tunnel url>", "api_key": "<NETHCLOUD api key>", "model": "gpt-oss-20b"}'
```

`GET /api/backend/status` then reports connectivity, latency, the server's
context window and tool capability.

## 3. Talk to the agent

```bash
curl -X POST http://<host>:8629/api/chat \
  -H "Authorization: Bearer <key>" -H "Content-Type: application/json" \
  -d '{"project": "physics-site", "message": "Create a website with an interactive physics simulation."}'
```

Or stream it over the WebSocket `ws://<host>:8629/ws/chat?key=<key>` — events:
`iteration`, `token` (content/reasoning channels), `tool_start`,
`tool_result`, `file_written`, `command_output`, `context` (compaction),
`done`. Send `{"type": "cancel"}` to stop.

### Tool registry

`list_files, read_file, write_file, patch_file, delete_file, create_directory,
run_command, run_python, install_dependencies, start_dev_server,
stop_dev_server, git_status, git_diff, git_commit, browser_open,
browser_screenshot, browser_console`

- Filesystem tools resolve every path inside the project workspace; absolute
  paths, `..` escapes and symlink escapes are rejected.
- `run_command` runs programs without a shell and blocks `powershell`/`cmd`.
- `install_dependencies` requires approval (`"approved": true` in the request)
  and is the only externally-visible mutation besides git commit.
- Git push is intentionally not a tool: pushes happen through the user's own
  git client, never by the agent.
- Browser tools need Playwright (`pip install playwright && playwright install
  chromium`); without it they return a structured hint instead of failing.

### Context compression

The budget is `model_limit − reserve_output` (default 32768 − 4096). At ~72%
usage the older turns are summarized by the same backend into
`memory/summaries.db`; originals stay in `conversations.db`; a
*preserved-notes* block keeps objectives, requirements, file paths, errors and
decisions verbatim. On a backend overflow error the host compacts once
(`emergency`) and retries. `GET /api/context/stats?conversation_id=…` shows
usage; `POST /api/context/compact` forces it.

## 4. Live preview

- Static projects: `http://<host>:8629/preview/<project>/` serves the real
  site with an injected auto-reload client (SSE). Saving a file reloads the
  iPad's browser automatically.
- Node/Vite projects: start a dev server with the agent, then
  `/preview/<project>/__proxy/…` reverse-proxies it — development ports are
  never exposed directly.
- With Playwright installed, `browser_open` captures console errors and failed
  network requests; `GET /api/preview/console?project=…` feeds them to the UI.

## 5. Security notes

- Every `/api` and `/ws` route requires the Bearer key; `/healthz` returns no
  sensitive data. Keys live in `config/config.json` (user-readable only) and
  never in logs, git or child-process environments (environment vars with
  TOKEN/SECRET/PASSWORD/KEY in the name are stripped before running commands).
- The Colab backend key is stored the same way; the notebook prints it once.
- Destructive tools are gated behind explicit approval; the agent cannot
  delete the project root, escape the workspace, or run a shell.
- The server binds the LAN (0.0.0.0:8629). Do not port-forward it to the
  internet; remote access should go through a VPN or tunnel that preserves the
  Authorization header.

## 6. Troubleshooting

| Symptom | Fix |
| --- | --- |
| `no backend configured` | POST `/api/backend/config` with the notebook's URL + key |
| `backend rejected the API key` | The Colab session rotated; paste a fresh connect code |
| 401 from the host | The iPad/app must send `Authorization: Bearer <key>` |
| Preview 404 | Create the project first (`POST /api/projects`) or ask the agent |
| Dev server never opens a port | Check the command output event; use `--port` explicitly |
| Context overflow loop | Reduce `context.model_limit` in config.json to the notebook's window |
| Playwright tools say "not installed" | `pip install playwright && playwright install chromium` |
| Setup repeats every launch | Delete `config\install-state.json` to force a clean re-run |

## 7. Building from source

```
cd host
python -m pip install -r requirements.txt
python -m pytest            # 67 tests
pyinstaller build/NethHost.spec --noconfirm
```

The GitHub Actions job `nethhost` (windows-2022) runs the test suite, builds
the single-file executable with PyInstaller, boots it, verifies `/healthz` and
the 401 auth gate, and uploads **NethHost-v2** as an artifact.
