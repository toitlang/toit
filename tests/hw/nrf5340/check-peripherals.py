# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
"""Package and run the wired peripheral suites, then restore application firmware.

Requires the documented E83/ESP32 wiring and the current ESP32 wired fixture.
The supplied envelope must be an application-only Zephyr envelope. This runner
does not flash the ESP32 or modify the network controller.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
# source stem, expected marker suffix, release pin, capture seconds, cleanup
SUITES = {
    "gpio": ("gpio", "GPIO", 13, 60, []),
    "uart": ("uart", "UART", 32, 90, []),
    "uart-flow": ("uart-flow", "UART FLOW", 18, 90, []),
    "i2c": ("i2c", "I2C", 21, 120, ["I2C_CHECK 1024", "I2C_CLOSE"]),
    "i2c-read": ("i2c-read", "I2C READ", 21, 90, []),
    "spi": ("spi", "SPI", 4, 120, ["SPI_CHECK"]),
    "adc": ("adc", "ADC", 13, 90, ["IDLE"]),
    "pwm": ("pwm-paired", "PWM PAIRED", 13, 180,
            [f"PWM_RELEASE {pin}" for pin in (13, 32, 18, 23)]),
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toit", type=Path, required=True, help="SDK matching the envelope")
    parser.add_argument("--envelope", type=Path, required=True)
    parser.add_argument("--log-dir", type=Path, required=True, help="New output directory")
    parser.add_argument("--tests", nargs="+", choices=SUITES, default=list(SUITES))
    parser.add_argument("--prepare-only", action="store_true", help="Package tests without accessing hardware")
    parser.add_argument("--restore-image", type=Path, help="Known normal application binary to restore")
    parser.add_argument("--esp-serial", help="Identified ESP32 persistent serial path")
    parser.add_argument("--nrf-serial", help="Identified Ebyte USB-TTL persistent serial path")
    args = parser.parse_args()
    if not args.prepare_only and not all((args.restore_image, args.esp_serial, args.nrf_serial)):
        parser.error("Hardware runs require --restore-image, --esp-serial and --nrf-serial")
    host = args.toit.resolve()
    envelope = args.envelope.resolve()
    out = args.log_dir.resolve()
    out.mkdir(parents=True, exist_ok=False)
    result = {"passed": False, "prepared": False, "suites": {}, "errors": []}

    def save():
        (out / "summary.json").write_text(json.dumps(result, indent=2) + "\n")

    def run(label, command):
        with (out / f"{label}.log").open("w") as log:
            subprocess.run(list(map(str, command)), cwd=ROOT, stdout=log,
                           stderr=subprocess.STDOUT, check=True)

    def firmware(path, *command):
        return [host, "tool", "firmware", f"--envelope={path}", *command]

    # Freeze the inputs before any debugger or serial access. The base retains
    # only the system container, so no unrelated bundled app runs beside a test.
    base = out / "system.envelope"
    shutil.copyfile(envelope, base)
    metadata = json.loads(subprocess.check_output(
        firmware(base, "show", "--output-format=json"), cwd=ROOT, text=True))
    if metadata["kind"] != "zephyr" or metadata["envelope-format-version"] != 1003:
        raise ValueError("Peripheral qualification requires an application-only Zephyr envelope")
    result["sdk_version"] = metadata["sdk-version"]
    result["input_envelope_sha256"] = digest(base)
    for index, name in enumerate(metadata["containers"]):
        if name != "system":
            run(f"remove-{index}", firmware(base, "container", "uninstall", name))
    for name in dict.fromkeys(args.tests):
        stem, marker, _, _, _ = SUITES[name]
        source = HERE / f"{stem}-nrf5340.toit"
        snapshot = out / f"{name}.snapshot"
        packaged = out / f"{name}.envelope"
        image = out / f"{name}.bin"
        run(f"{name}-compile", [host, "compile", "-s", "-o", snapshot, source])
        run(f"{name}-package", firmware(base, "container", "install", name, snapshot, "-o", packaged))
        run(f"{name}-extract", firmware(packaged, "extract", "-o", image))
        result["suites"][name] = {"passed": False, "status": "prepared", "source": str(source.relative_to(ROOT)),
                                  "source_sha256": digest(source), "image_sha256": digest(image),
                                  "marker": f"NRF5340 {marker} PASS"}
    result["prepared"] = True
    save()
    print(f"Packaged {len(result['suites'])} peripheral suites against {result['sdk_version']}", flush=True)
    if args.prepare_only:
        return

    flash = load_module("qualification_flash", ROOT / "tools/nrf5340/flash.py")
    restore = out / "restore.bin"
    data = args.restore_image.read_bytes()
    flash.validate_image(data)
    restore.write_bytes(data)
    result["restore_image_sha256"] = digest(restore)
    settings = load_module("qualification_settings", HERE / "check-settings.py")
    before = settings.backup(out, "before", 250)
    result["before_sha256"] = dict(zip(("settings", "storage"),
                                       (hashlib.sha256(data).hexdigest() for data in before)))
    save()
    print("Persistent partitions backed up", flush=True)
    try:
        for name, record in result["suites"].items():
            _, _, release, seconds, cleanup = SUITES[name]
            print(f"Running {name}", flush=True)
            record["status"] = "running"
            save()
            command = [sys.executable, "-u", HERE / "check-gpio.py",
                       "--esp-serial", args.esp_serial, "--nrf-serial", args.nrf_serial,
                       "--image", out / f"{name}.bin", "--log-dir", out / name,
                       "--expect", record["marker"], "--release-pin", release, "--seconds", seconds]
            for item in cleanup:
                command += ["--cleanup-command", item]
            run(f"{name}-run", command)
            text = (out / f"{name}-run.log").read_text()
            match = re.search(r"Paired test PASS \((\d+) fixture requests, output released", text)
            if not match or record["marker"] not in text or "VM teardown complete" not in text:
                raise RuntimeError(f"Missing completion evidence for {name}")
            record.update(passed=True, status="passed", fixture_requests=int(match[1]))
            save()
            print(f"{name} PASS ({match[1]} fixture requests)", flush=True)
    except Exception as error:
        record["status"] = "failed"
        result["errors"].append(str(error))
        save()
    finally:
        # Restoration runs after a failed suite too. Never erase or rewrite the
        # persistent partitions to hide a mismatch.
        try:
            print("Restoring normal application", flush=True)
            run("restore", [sys.executable, ROOT / "tools/nrf5340/flash.py", restore,
                            "--serial", args.nrf_serial, "--log-dir", out / "restoration",
                            "--expect", "[toit] Zephyr VM starting", "--seconds", 5])
            result["restored"] = True
            after = settings.backup(out, "after", 250)
            result["settings_preserved"] = before[0] == after[0]
            result["storage_preserved"] = before[1] == after[1]
            if before != after:
                raise RuntimeError("Persistent partitions changed during peripheral qualification")
        except Exception as error:
            result["errors"].append(f"Restoration/verification: {error}")
        result["passed"] = not result["errors"] and all(r["passed"] for r in result["suites"].values())
        save()
    if not result["passed"]:
        raise SystemExit(f"Peripheral qualification failed; see {out / 'summary.json'}")
    print("All selected peripheral suites passed; normal firmware restored and persistent data preserved", flush=True)


if __name__ == "__main__":
    main()
