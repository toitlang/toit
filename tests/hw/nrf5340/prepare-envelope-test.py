# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
"""Exercise the Zephyr envelope CLI and prepare two firmware variants for SWD tests."""
import argparse
from pathlib import Path
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[3]
TOIT = ROOT / "build/host/sdk/bin/toit"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--firmware", type=Path, required=True)
    parser.add_argument("--system-snapshot", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=ROOT / "build/nrf5340-envelope")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    envelope = out / "test.envelope"

    def toit(*arguments, failure=None):
        result = subprocess.run([str(TOIT), *map(str, arguments)], capture_output=True, text=True, timeout=60)
        with (out / "host.log").open("a") as log:
            log.write(f"{arguments}\n{result.stdout}{result.stderr}\n")
        if failure:
            assert result.returncode and failure in result.stdout + result.stderr, result.stdout + result.stderr
        else:
            assert result.returncode == 0, result.stdout + result.stderr
        return result

    def firmware(*arguments, **kwargs):
        return toit("tool", "firmware", "--envelope", envelope, *arguments, **kwargs)

    binary = args.firmware.read_bytes()
    descriptor = binary.index(b"TOITZPH1")
    load, extension, limit = struct.unpack_from("<3I", binary, descriptor + 12)
    offset = extension - load
    (out / "host.log").write_text("")
    firmware("create", "zephyr", "--firmware.bin", args.firmware,
             "--system.snapshot", args.system_snapshot)
    firmware("show", "--all", "--output", out / "show-base.json")
    firmware("extract", "-o", out / "base-extracted.bin")
    base = (out / "base-extracted.bin").read_bytes()
    assert base[:offset] == binary[:offset]
    (out / "payload.bin").write_bytes(bytes((i * 13 + 9) & 255 for i in range(5003)))
    toit("compile", "-s", "-o", out / "probe.snapshot", ROOT / "tests/hw/nrf5340/envelope-nrf5340.toit")
    toit("compile", "-s", "-o", out / "worker.snapshot", ROOT / "tests/hw/nrf5340/vm-smoke.toit")
    firmware("container", "install", "worker", out / "worker.snapshot", "--trigger=none")
    variants = []
    for version in ("snapshot", "image"):
        (out / "version.txt").write_text(version)
        assets = out / f"{version}.assets"
        toit("tool", "assets", "-e", assets, "create")
        for key, path in (("version", out / "version.txt"), ("payload", out / "payload.bin")):
            toit("tool", "assets", "-e", assets, "add", key, path)
        if version == "snapshot":
            firmware("container", "install", "probe", out / "probe.snapshot", "--assets", assets)
        else:
            toit("tool", "snapshot-to-image", "--format=binary", "-m32", "--assets", assets,
                 "-o", out / "probe.image", out / "probe.snapshot")
            firmware("container", "install", "probe", out / "probe.image")
        firmware("extract", "-o", out / f"{version}.bin")
        firmware("show", "--all", "--output", out / f"show-{version}.json")
        shutil.copyfile(envelope, out / f"{version}.envelope")
        result = (out / f"{version}.bin").read_bytes()
        assert result[:offset] == binary[:offset]
        assert len(result) <= limit - load
        assert struct.unpack_from("<I", result, offset + 12)[0] == 3
        variants.append(result)
        print(f"{version}: {len(result)} bytes; native prefix preserved PASS")
    assert variants[0] != variants[1]
    # Failed extraction must not touch an existing output artifact.
    sentinel = out / "rejected.bin"
    sentinel.write_bytes(b"keep-existing-output")
    firmware("extract", "--format=elf", "-o", sentinel, failure="binary extraction only")
    (out / "config.json").write_text("{}")
    firmware("extract", "--config", out / "config.json", "-o", sentinel, failure="configuration is not supported")
    wrong = bytearray((out / "probe.image").read_bytes())
    wrong[36] ^= 1
    (out / "wrong-sdk.image").write_bytes(wrong)
    before = envelope.read_bytes()
    firmware("container", "install", "probe", out / "wrong-sdk.image", failure="cannot be verified")
    assert envelope.read_bytes() == before
    # A precompiled image with inline assets cannot also take separate assets.
    firmware("container", "install", "probe", out / "probe.image", "--assets", out / "image.assets")
    firmware("extract", "-o", sentinel, failure="already includes assets")
    firmware("container", "install", "probe", out / "probe.image")
    (out / "large.bin").write_bytes(bytes(limit - load))
    toit("tool", "assets", "-e", out / "large.assets", "create")
    toit("tool", "assets", "-e", out / "large.assets", "add", "large", out / "large.bin")
    firmware("container", "install", "large", out / "probe.snapshot", "--assets", out / "large.assets")
    firmware("extract", "-o", sentinel, failure="exceed the code partition")
    firmware("container", "uninstall", "large")
    firmware("container", "uninstall", "system")
    firmware("extract", "-o", sentinel, failure="requires the system container")
    assert sentinel.read_bytes() == b"keep-existing-output"
    # Removing both applications restores the original system-only extraction.
    firmware("container", "install", "system", args.system_snapshot, "--critical")
    for name in ("probe", "worker"):
        firmware("container", "uninstall", name)
    firmware("extract", "-o", out / "removed.bin")
    assert (out / "removed.bin").read_bytes() == base
    print("ZEPHYR ENVELOPE HOST PASS: snapshots, relocatable assets, removals, SDK and bounds rejection")


if __name__ == "__main__":
    main()
