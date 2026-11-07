#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
"""Exercise RP2040 envelopes with a built native base; retains hardware fixtures."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/rp2040"))
import upload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path)
    args = parser.parse_args()
    build = args.build.resolve()
    output = build / "envelope-tests"
    output.mkdir(exist_ok=True)
    toit = ROOT / "build/host/sdk/bin/toit"
    env = dict(os.environ)
    env.setdefault("TOIT_PACKAGE_CACHE_PATHS", str(ROOT / "tools/.packages-bootstrap"))

    def run(*args, failure=None):
        result = subprocess.run([str(toit), *map(str, args)], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if failure:
            assert result.returncode != 0, result.stdout
            assert failure in result.stdout, result.stdout
        else:
            if result.returncode:
                raise RuntimeError(result.stdout)
        return result.stdout

    def firmware(envelope, *args, **kwargs):
        return run("run", "--project-root", ROOT / "tools", ROOT / "tools/firmware.toit",
                   "--", "-e", envelope, *args, **kwargs)

    def helper(*args):
        return run("run", "--project-root", ROOT / "tools",
                   ROOT / "tools/rp2040-envelope-test-helper.toit", "--", *args)

    base = build / "toit-rp2040.bin"
    envelope = output / "base.envelope"
    run("tool", "firmware", "-e", envelope, "create", "rp2040",
        "--firmware.bin", base, "--system.snapshot", build / "boot.snapshot")
    snapshot = output / "application.snapshot"
    run("compile", "-s", "-o", snapshot, ROOT / "tests/hw/rp2040/envelope-rp2040.toit")
    assets = output / "assets.bin"
    helper("make-assets", assets, 0)
    installed = output / "installed.envelope"
    firmware(envelope, "container", "install", "--output", installed,
             "--assets", assets, "--critical", "child", snapshot)
    show = output / "show.json"
    firmware(installed, "show", "--output", show)
    info = json.loads(show.read_text())
    assert info["kind"] == "rp2040"
    assert info["envelope-format-version"] == 1002
    assert set(info["containers"]) == {"system", "child"}
    for item in info["containers"].values():
        assert item["flags"] == ["trigger=boot", "critical"]
    extracted_assets = output / "extracted-assets.bin"
    firmware(installed, "container", "extract", "--part=assets", "--output", extracted_assets, "child")
    assert extracted_assets.read_bytes() == assets.read_bytes()
    config = output / "config.json"
    config.write_text(json.dumps({"enabled": True, "name": "rp2040-envelope-test"}))
    binary = output / "firmware.bin"
    firmware(installed, "extract", "--format=binary", "--config", config, "--output", binary)
    repeated = output / "repeated.bin"
    firmware(installed, "extract", "--format=binary", "--config", config, "--output", repeated)
    assert binary.read_bytes() == repeated.read_bytes()
    upload.validate_image(binary.read_bytes())
    encoded = output / "firmware.ubjson"
    firmware(installed, "extract", "--format=ubjson", "--config", config, "--output", encoded)
    helper("verify-output", encoded, binary, assets)
    firmware(installed, "extract", "--format=image", "--output", output / "bad.uf2",
             failure="Unsupported format for RP2040")
    damaged = bytearray(base.read_bytes())
    struct.pack_into("<I", damaged, 256, 0)
    corrupt = output / "bad-vector.bin"
    corrupt.write_bytes(damaged)
    firmware(output / "bad.envelope", "create-rp2040", "--firmware.bin", corrupt,
             "--system.snapshot", build / "boot.snapshot", failure="Invalid RP2040 application vectors")
    huge = output / "large-assets.bin"
    helper("make-assets", huge, 900000)
    oversized = output / "oversized.envelope"
    firmware(envelope, "container", "install", "--output", oversized,
             "--assets", huge, "child", snapshot)
    firmware(oversized, "extract", "--format=binary", "--output", output / "oversized.bin",
             failure="slot")
    print(f"PASS: envelope round-trip, assets, config, relocation, deterministic extraction and rejection tests; fixtures in {output}")


if __name__ == "__main__":
    main()
