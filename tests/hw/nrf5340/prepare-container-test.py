# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
"""Build the container worker and encode its image as the controller's asset."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
TOIT = ROOT / "build/host/sdk/bin/toit"
OUT = ROOT / "build/nrf5340-containers"


def toit(*arguments):
    subprocess.run([str(TOIT), *map(str, arguments)], check=True)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "payload.bin").write_bytes(bytes((i * 13 + 9) & 255 for i in range(5003)))
    toit("tool", "assets", "-e", OUT / "worker.assets", "create")
    toit("tool", "assets", "-e", OUT / "worker.assets", "add", "payload", OUT / "payload.bin")
    toit("compile", "-s", "-o", OUT / "worker.snapshot",
         ROOT / "tests/hw/nrf5340/container-worker.toit")
    toit("tool", "snapshot-to-image", "--format=binary", "-m32",
         "--assets", OUT / "worker.assets", "-o", OUT / "worker.image", OUT / "worker.snapshot")
    toit("tool", "assets", "-e", OUT / "controller.assets", "create")
    toit("tool", "assets", "-e", OUT / "controller.assets", "add", "worker.image", OUT / "worker.image")
    print(f"Controller assets: {OUT / 'controller.assets'}")


if __name__ == "__main__":
    main()
