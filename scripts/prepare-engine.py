"""Prepare the same pinned llama.cpp engine for the Windows and iPad builds."""

from hashlib import sha256
from pathlib import Path
import shutil
import subprocess
import tarfile
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[1]
COMMIT = "8af68d486a9473820d24d00af8f33334ca80124d"
ARCHIVE_HASH = "ee8cc472474089e2f97aa400ed913b24a10ac27802b9375f360d94e9618705ff"
BUILD = ROOT / ".build"
PATCH = ROOT / "ThirdParty" / "llama-qwen-split.patch"
ARCHIVE = BUILD / f"llama-{COMMIT}.tar.gz"
SOURCE = BUILD / f"llama.cpp-{COMMIT}"
STAMP = SOURCE / ".neth-patch"


def digest(path):
    return sha256(path.read_bytes()).hexdigest()


def prepare():
    version = digest(PATCH)
    if STAMP.is_file() and STAMP.read_text() == version:
        return SOURCE
    BUILD.mkdir(exist_ok=True)
    if not ARCHIVE.is_file() or digest(ARCHIVE) != ARCHIVE_HASH:
        pending = ARCHIVE.with_suffix(".partial")
        with urlopen(f"https://codeload.github.com/ggml-org/llama.cpp/tar.gz/{COMMIT}", timeout=60) as data:
            with pending.open("wb") as output:
                shutil.copyfileobj(data, output)
        if digest(pending) != ARCHIVE_HASH:
            raise ValueError("The downloaded llama.cpp archive SHA-256 did not match.")
        pending.replace(ARCHIVE)
    if SOURCE.exists():
        shutil.rmtree(SOURCE)
    with tarfile.open(ARCHIVE, "r:gz") as archive:
        archive.extractall(BUILD, filter="data")
    subprocess.run(["git", "init", "-q", str(SOURCE)], check=True)
    patch = PATCH.read_bytes().replace(b"\r\n", b"\n")
    subprocess.run(["git", "-C", str(SOURCE), "-c", "core.autocrlf=false",
                    "apply", "--unidiff-zero", "--whitespace=error", "-"], input=patch, check=True)
    STAMP.write_text(version)
    return SOURCE


if __name__ == "__main__":
    print(prepare())
