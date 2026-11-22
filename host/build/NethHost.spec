# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec for NethHost v2.0.0 (Windows, one-file console app).
# Built by .github/workflows/unsigned-ipa.yml (job: nethhost).
import sys

block_cipher = None

a = Analysis(
    ["../nethhost/__main__.py"],
    pathex=["../"],
    binaries=[],
    datas=[],
    hiddenimports=[
        "uvicorn.logging",
        "uvicorn.loops.auto",
        "uvicorn.protocols.http.auto",
        "uvicorn.protocols.websockets.auto",
        "uvicorn.lifespan.on",
        "anyio._backends._asyncio",
    ],
    hookspath=[],
    runtime_hooks=[],
    excludes=["tkinter", "matplotlib", "numpy", "pandas"],
    cipher=block_cipher,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name="NethHost-v2.0.0",
    console=True,
    disable_windowed_traceback=False,
    upx=False,
)
