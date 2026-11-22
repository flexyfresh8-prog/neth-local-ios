"""NethHost entry point: first-launch setup, then serve the API.

    NethHost.exe [--port 8629] [--host 0.0.0.0] [--base D:\\NethLocal]
                 [--no-setup] [--repair folders|config|databases|toolchain]
                 [--version]

The console prints the LAN address and where the iPad app should point, then
keeps serving until Ctrl+C. Destructive or administrative actions never happen
here without explicit flags.
"""
from __future__ import annotations

import argparse
import os
import sys

from nethhost import APP_NAME, DEFAULT_PORT, __version__


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog=APP_NAME, description=__doc__)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--base", default=None, help="override the NethLocal root directory")
    parser.add_argument("--no-setup", action="store_true", help="skip first-launch setup")
    parser.add_argument("--repair", choices=["folders", "config", "databases", "toolchain"],
                        default=None, help="redo one setup step on the next launch")
    parser.add_argument("--version", action="store_true")
    args = parser.parse_args(argv)

    if args.version:
        print(f"{APP_NAME} {__version__}")
        return 0

    if args.base:
        os.environ["NETHLOCAL_HOME"] = args.base

    # Windows consoles default to cp1252; non-ASCII output must never crash the host.
    for stream in (sys.stdout, sys.stderr):
        if stream and hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")

    from nethhost.config import Config, InstallState
    from nethhost.paths import Layout, base_dir
    from nethhost.setup_env import bootstrap, repair

    layout = Layout(base_dir())
    config = Config(layout)
    state = InstallState(layout)

    if args.repair:
        repair(layout, state, args.repair)

    if not args.no_setup:
        report = bootstrap(layout, config, state)
        print(f"{APP_NAME} {__version__} first-launch setup:")
        for step in report["steps"]:
            detail = f" -- {step['detail']}" if step.get("detail") else ""
            print(f"  [{step['status']:>6}] {step['name']}{detail}")
    else:
        config.load()

    print(f"Workspace root: {layout.root}")
    print(f"API key: stored in {layout.config_file} (never committed, never logged)")
    print("Connect the Colab backend with POST /api/backend/config or in the iPad Settings.")

    from nethhost.api.server import create_app, lan_address
    from nethhost.database import Database
    from nethhost.tools import build_registry
    import uvicorn

    db = Database(layout.memory)
    registry = build_registry()
    app = create_app(config, db, registry, layout)

    print(f"{APP_NAME} listening on {lan_address(args.port)}  (iPad -> Settings -> Add host)")
    uvicorn.run(app, host=args.host, port=args.port, log_level="info", access_log=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
