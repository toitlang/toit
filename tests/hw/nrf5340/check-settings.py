# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
"""Qualify isolated Zephyr settings across rollover, reboot and firmware replacement."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("nrf_deploy", ROOT / "tools/nrf5340/deploy.py")
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


def backup(out, label, adapter_speed):
    with deploy.debugger(ROOT / ".cache/nrf5340/openocd/src/openocd", out / f"{label}-swd.log") as debug:
        debug.call(f"adapter speed {adapter_speed}")
        debug.call("nrf53.cpuapp arp_poll")
        running = debug.call("nrf53.cpuapp curstate") == "running"
        debug.call("halt; wait_halt 2000")
        try:
            def read(start, size, name):
                data = bytearray()
                # Short, paced reads avoid this fixture's intermittent FTDI
                # queue stalls under sustained transfers.
                for address in range(start, start + size, 64):
                    words = [int(value, 0) for value in debug.call(
                        f"nrf53.cpuapp read_memory {address} 32 16").split()]
                    if len(words) != 16:
                        raise RuntimeError("Incomplete flash read")
                    data.extend(struct.pack("<16I", *words))
                    time.sleep(.002)
                (out / f"{label}-{name}.bin").write_bytes(data)
                return bytes(data)
            settings = read(deploy.FIRMWARE_LIMIT, deploy.BASE - deploy.FIRMWARE_LIMIT, "settings")
            storage = read(deploy.BASE, deploy.STORAGE_SIZE, "storage")
            return settings, storage
        finally:
            if running and debug.healthy:
                debug.call("resume")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--adapter-speed", type=int, default=250)
    args = parser.parse_args()
    if args.adapter_speed <= 0:
        parser.error("Adapter speed must be positive")
    out = args.log_dir.resolve()
    # Do not overwrite the original backups on a retry.
    out.mkdir(parents=True, exist_ok=False)
    image = out / "qualification.bin"
    image.write_bytes(args.image.read_bytes())
    before_settings, before_storage = backup(out, "before", args.adapter_speed)
    print("Backed up settings and Toit storage", flush=True)

    def flash(label, marker):
        with (out / f"{label}.log").open("w") as log:
            subprocess.run([sys.executable, str(ROOT / "tools/nrf5340/flash.py"), str(image),
                            "--serial", args.serial, "--log-dir", str(out / label),
                            "--adapter-speed", str(args.adapter_speed),
                            "--expect", marker, "--stop-after", marker, "--seconds", "120"],
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=250)
        text = (out / f"{label}.log").read_text()
        if re.search(r"failed|FATAL|EXCEPTION", text, re.I):
            raise RuntimeError(f"Unexpected failure in {label}.log")
        return text

    first = flash("rollover", "NRF5340 SETTINGS REFLASH READY")
    assert re.findall(r"NRF5340 settings phase=(\d+)", first) == ["0", "1", "2"]
    assert "NRF5340 settings rollover PASS" in first
    assert "NRF5340 settings reset persistence PASS" in first
    ready_settings, ready_storage = backup(out, "ready", args.adapter_speed)
    assert ready_storage == before_storage, "Toit storage changed during settings test"
    assert ready_settings != before_settings, "Settings test did not persist any data"
    print("Rollover, two resets, deletion and Toit storage preservation PASS", flush=True)
    second = flash("replacement", "NRF5340 SETTINGS PASS")
    assert re.findall(r"NRF5340 settings phase=(\d+)", second) == ["3"]
    after_settings, after_storage = backup(out, "after", args.adapter_speed)
    assert after_storage == before_storage, "Toit storage changed during firmware replacement"
    summary = {
        "passed": True,
        "adapter_speed_khz": args.adapter_speed,
        "updates": 256,
        "value_bytes": 512,
        "reset_boots": 3,
        "replacement_boots": 1,
        "settings_partition": {"address": deploy.FIRMWARE_LIMIT, "bytes": len(after_settings)},
        "toit_storage_preserved": True,
        "settings_test_keys_deleted": True,
        "firmware_sha256": hashlib.sha256(image.read_bytes()).hexdigest(),
        "storage_sha256": hashlib.sha256(before_storage).hexdigest(),
        "limitations": ["No physical power-loss injection", "No Bluetooth bond pairing in this test"],
    }
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("NRF5340 SETTINGS HOST PASS: firmware replacement and Toit storage preservation", flush=True)


if __name__ == "__main__":
    main()
