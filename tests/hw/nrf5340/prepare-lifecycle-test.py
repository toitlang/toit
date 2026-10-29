# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
"""Build envelope variants that exercise critical-container error recovery."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
TOIT = ROOT / "build/host/sdk/bin/toit"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--firmware", type=Path, required=True)
    parser.add_argument("--system-snapshot", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=ROOT / "build/nrf5340-lifecycle")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)

    def toit(*arguments):
        subprocess.run([str(TOIT), *map(str, arguments)], check=True)

    for name, source in (("controller", "lifecycle-nrf5340.toit"), ("worker", "lifecycle-worker.toit")):
        toit("compile", "-s", "-o", out / f"{name}.snapshot", ROOT / "tests/hw/nrf5340" / source)
    for mode in ("exit", "throw"):
        envelope = out / f"{mode}.envelope"
        command = ("tool", "firmware", "--envelope", envelope)
        toit(*command, "create", "zephyr", "--firmware.bin", args.firmware,
             "--system.snapshot", args.system_snapshot)
        for name in ("controller", "critical", "ordinary"):
            assets = out / f"{mode}-{name}.assets"
            (out / "value.txt").write_text(mode if name == "controller" else name)
            toit("tool", "assets", "-e", assets, "create")
            toit("tool", "assets", "-e", assets, "add", "failure", out / "value.txt")
            snapshot = out / ("controller.snapshot" if name == "controller" else "worker.snapshot")
            flags = [] if name == "controller" else ["--trigger=none"]
            if name == "critical":
                flags.append("--critical")
            toit(*command, "container", "install", name, snapshot, "--assets", assets, *flags)
        toit(*command, "extract", "-o", out / f"{mode}.bin")
        print(f"{mode}: {(out / f'{mode}.bin').stat().st_size} bytes")


if __name__ == "__main__":
    main()
