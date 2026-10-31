# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
"""Verify SWD deployment against an already-flashed system-only firmware."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import uuid

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("nrf_deploy", ROOT / "tools/nrf5340/deploy.py")
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


def storage_id(namespace):
    data = bytearray(hashlib.sha1((namespace + "nrf-deploy").encode()).digest()[:16])
    data[6] = (data[6] & 15) | 0x50
    data[8] = (data[8] & 63) | 0x80
    return str(uuid.UUID(bytes=bytes(data)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--firmware", type=Path, required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--log-dir", type=Path, default=ROOT / "build/nrf5340-deploy/check")
    args = parser.parse_args()
    out = args.log_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    firmware = args.firmware.resolve()
    toit = ROOT / "build/host/sdk/bin/toit"
    sdk = deploy.firmware_sdk(firmware.read_bytes())

    def compile_tool(*arguments):
        subprocess.run([str(toit), *map(str, arguments)], check=True)

    compile_tool("compile", "-s", "-o", out / "app.snapshot", ROOT / "tests/hw/nrf5340/deploy-nrf5340.toit")
    (out / "payload.bin").write_bytes(bytes((index * 13 + 9) & 255 for index in range(5003)))
    images = {}
    for version in ("v1", "v2", "large"):
        (out / f"{version}.txt").write_text(version)
        compile_tool("tool", "assets", "-e", out / f"{version}.assets", "create")
        for key, path in (("version", out / f"{version}.txt"), ("payload", out / "payload.bin")):
            compile_tool("tool", "assets", "-e", out / f"{version}.assets", "add", key, path)
        if version == "large":
            (out / "padding.bin").write_bytes(b"\0" * (48 * 1024))
            compile_tool("tool", "assets", "-e", out / f"{version}.assets", "add", "padding", out / "padding.bin")
        compile_tool("tool", "snapshot-to-image", "--format=binary", "-m32", "--assets", out / f"{version}.assets",
                     "-o", out / f"{version}.image", out / "app.snapshot")
        images[version] = deploy.Image((out / f"{version}.image").read_bytes(), sdk)

    def command(label, *operation, expect=None, failure=None, reference=firmware):
        argv = [sys.executable, str(ROOT / "tools/nrf5340/deploy.py"), "--firmware", str(reference),
                "--log-dir", str(out / label), "--json"]
        if expect:
            argv += ["--serial", args.serial, "--expect", expect, "--seconds", "20"]
        result = subprocess.run([*argv, *map(str, operation)], capture_output=True, text=True, timeout=120)
        (out / f"{label}.stdout").write_text(result.stdout)
        (out / f"{label}.stderr").write_text(result.stderr)
        if failure:
            assert result.returncode != 0 and failure in result.stderr, result.stdout + result.stderr
            print(f"{label}: expected rejection PASS", flush=True)
            return None
        assert result.returncode == 0, result.stdout + result.stderr
        decoded = json.loads(result.stdout)
        print(f"{label}: changed={decoded['changed']} PASS", flush=True)
        return decoded

    # Only remove these test images when rerunning a previously interrupted test.
    command("cleanup-v1", "uninstall", images["v1"].id)
    command("cleanup-v2", "uninstall", images["v2"].id)
    baseline = command("baseline", "list")
    baseline_bytes = (Path(baseline["log_dir"]) / "storage-after.bin").read_bytes()
    own_storage = {storage_id("flash:bucket"), storage_id("flash:region")}
    preserved = [allocation for allocation in baseline["allocations"] if allocation["id"] not in own_storage]

    wrong = bytearray((out / "v1.image").read_bytes())
    wrong[36] ^= 1
    (out / "wrong-sdk.image").write_bytes(wrong)
    command("wrong-sdk", "install", out / "wrong-sdk.image", failure="SDK does not match")
    assert not (out / "wrong-sdk").exists(), "SDK rejection contacted the target"
    wrong_firmware = bytearray(firmware.read_bytes())
    wrong_firmware[0x100] ^= 1
    (out / "wrong-firmware.bin").write_bytes(wrong_firmware)
    command("wrong-firmware", "list", reference=out / "wrong-firmware.bin", failure="Error:")

    # A real body is programmed, then the host connection fails before commit.
    # The next boot must ignore it and the next upload must reclaim the slot.
    fault_dir = out / "before-commit"
    fault_dir.mkdir(exist_ok=True)

    class InterruptedUpload(Exception):
        pass

    class BeforeCommit:
        def __init__(self, debug):
            self.debug = debug

        def call(self, text):
            if text.startswith("flash write_image {"):
                raise InterruptedUpload()
            return self.debug.call(text)

    options = SimpleNamespace(action="install", firmware=firmware, run_boot=True, critical=False, data=0)
    with deploy.debugger(ROOT / ".cache/nrf5340/openocd/src/openocd", fault_dir / "openocd.log") as debug:
        try:
            deploy.operate(BeforeCommit(debug), options, images["v1"], sdk, fault_dir)
            raise AssertionError("Upload was not interrupted before commit")
        except InterruptedUpload:
            assert (fault_dir / "not-resumed.txt").exists()
            held_dir = fault_dir / "list-while-halted"
            held_dir.mkdir(exist_ok=True)
            listing = SimpleNamespace(action="list", firmware=firmware)
            deploy.operate(debug, listing, None, sdk, held_dir)
            assert debug.call("nrf53.cpuapp curstate") == "halted", "Listing resumed an intentionally halted target"
            # We deliberately interrupted before writing the header and can
            # verify that it is erased before explicitly booting the firmware.
            storage = (fault_dir / "storage-before.bin").read_bytes()
            offset = deploy.free_slot(deploy.scan(storage, sdk), images["v1"].size)
            words = debug.call(f"nrf53.cpuapp read_memory {deploy.BASE + offset} 32 12")
            assert all(int(word, 0) == 0xffffffff for word in words.split())
            debug.call("reset run")
    after_fault = command("after-interruption", "list")
    assert not any(allocation["id"] == images["v1"].id for allocation in after_fault["allocations"])
    print("Interrupted upload remained unpublished PASS", flush=True)

    first = command("install-v1", "install", out / "v1.image", expect="NRF5340 DEPLOY v1 PASS")
    assert first["changed"]
    again = command("repeat-v1", "install", out / "v1.image", expect="NRF5340 DEPLOY v1 PASS")
    assert not again["changed"] and first["address"] == again["address"]
    assert again["storage_before_sha256"] == again["storage_after_sha256"]
    command("changed-flags", "install", out / "v1.image", "--critical", failure="different content or flags")
    command("no-space", "install", out / "large.image", failure="No contiguous space")
    command("remove-v1", "uninstall", images["v1"].id)
    removed_again = command("remove-v1-again", "uninstall", images["v1"].id)
    assert not removed_again["changed"]
    command("install-v2", "install", out / "v2.image", expect="NRF5340 DEPLOY v2 PASS")
    command("remove-v2", "uninstall", images["v2"].id)
    final = command("final", "list")
    final_bytes = (Path(final["log_dir"]) / "storage-after.bin").read_bytes()
    for allocation in preserved:
        start, end = allocation["offset"], allocation["offset"] + allocation["size"]
        assert final_bytes[start:end] == baseline_bytes[start:end], f"Changed unrelated allocation {allocation['id']}"
    assert not any(allocation["id"] in {images["v1"].id, images["v2"].id} for allocation in final["allocations"])
    print(f"NRF5340 DEPLOYMENT PASS ({len(preserved)} unrelated allocations preserved, native firmware unchanged)")


if __name__ == "__main__":
    main()
