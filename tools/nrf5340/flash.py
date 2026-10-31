# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
"""Flash application and optional network firmware over SWD, preserving persistent storage."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import time

import serial

ROOT = Path(__file__).resolve().parents[2]
# The E83 board reserves 16 KiB for Zephyr settings followed by 128 KiB for
# Toit storage and its recovery journal. Preserve both across reflashing.
FIRMWARE_LIMIT = 0xdc000


def validate_image(data, *, network=False):
    base, ram, ram_size, limit = ((0x01000000, 0x21000000, 0x10000, 0x40000) if network else
                                  (0, 0x20000000, 0x80000, FIRMWARE_LIMIT))
    if not 8 <= len(data) <= limit:
        raise ValueError("Network firmware must fit in 256 KiB" if network else
                         "Application firmware must fit below 0xdc000; the remainder is persistent settings and Toit storage")
    stack, entry = struct.unpack_from("<II", data)
    if not (ram < stack <= ram + ram_size and stack % 8 == 0 and
            entry & 1 and base + 8 <= (entry & ~1) < base + len(data)):
        raise ValueError("Invalid network-core vector table" if network else "Invalid application-core vector table")


def tcl_path(path):
    if any(c in str(path) for c in '{}\\\n\r'):
        raise ValueError("Firmware path contains unsupported Tcl characters")
    return "{" + str(path) + "}"


def programming_commands(image, speed, network_image=None):
    app = tcl_path(image)
    commands = [f"adapter speed {speed}", "reset halt"]
    if network_image:
        network = tcl_path(network_image)
        # Release sequence from pinned OpenOCD's nrf53_cpunet_release, with
        # examination failures propagated. No recover/erase-all or UICR access.
        # Probe the network target before modifying either firmware image.
        commands += [
            "nrf53.cpuapp mww 0x50005618 1",
            "nrf53.cpuapp mww 0x50005614 0",
            "nrf53.cpuapp mww 0x50005614 1",
            "nrf53.cpunet arp_examine",
            "nrf53.cpunet mww 0xe000edfc 0x01000501",
            "nrf53.cpuapp mww 0x50005614 0",
            "nrf53.cpuapp mww 0x50005618 0",
            "nrf53.cpunet arp_poll",
            "nrf53.cpunet arp_waitstate halted 2000",
            "targets nrf53.cpunet",
            f"flash write_image erase {network} 0x01000000 bin",
            f"verify_image {network} 0x01000000 bin",
            "targets nrf53.cpuapp",
            "nrf53.cpuapp mww 0x50005614 1",
        ]
    commands += [f"flash write_image erase {app} 0 bin", f"verify_image {app} 0 bin",
                 "reset run", "shutdown"]
    return "; ".join(commands)


def stage_images(directory, application, network):
    # Program the exact bytes validated before the debugger starts. Keep the
    # copies and their hashes with the logs, even after an interrupted update.
    tcl_path(directory)
    staged = Path(tempfile.mkdtemp(prefix="images-", dir=directory))
    result = []
    records = []
    for name, address, data in (("application.bin", 0, application),
                                ("network.bin", 0x01000000, network)):
        path = staged / name
        path.write_bytes(data)
        result.append(path)
        records.append({"file": str(path.relative_to(directory)), "address": address,
                        "size": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    (directory / "images.json").write_text(json.dumps(records, indent=2) + "\n")
    return result


def load_bundle(path):
    # Only the uncompressed, three-file format emitted by `firmware extract`
    # is accepted. Never extract archive paths, links or devices to disk.
    if path.stat().st_size > FIRMWARE_LIMIT + 0x40000 + 0x10000:
        raise ValueError("Firmware bundle is too large")
    limits = {"manifest.json": 8192, "application.bin": FIRMWARE_LIMIT, "network.bin": 0x40000}
    try:
        with tarfile.open(path, mode="r:") as archive:
            members = archive.getmembers()
            if sorted(m.name for m in members) != sorted(limits):
                raise ValueError("Firmware bundle must contain exactly manifest.json, application.bin and network.bin")
            files = {}
            for member in members:
                if not member.isfile() or not 0 < member.size <= limits[member.name]:
                    raise ValueError("Invalid firmware bundle member")
                with archive.extractfile(member) as source:
                    files[member.name] = source.read(limits[member.name] + 1)
                if len(files[member.name]) != member.size:
                    raise ValueError("Incomplete firmware bundle member")
        manifest = json.loads(files["manifest.json"])
        if not isinstance(manifest, dict) or type(manifest.get("format")) is not int or \
                manifest["format"] != 1 or manifest.get("target") != "nrf5340":
            raise ValueError("Unsupported firmware bundle target or format")
        for role, name, address in (("application", "application.bin", 0),
                                    ("network", "network.bin", 0x01000000)):
            record = manifest.get(role)
            data = files[name]
            if not isinstance(record, dict) or record.get("file") != name or \
                    type(record.get("address")) is not int or record["address"] != address or \
                    type(record.get("size")) is not int or record["size"] != len(data) or \
                    record.get("sha256") != hashlib.sha256(data).hexdigest():
                raise ValueError("Firmware bundle image metadata or hash mismatch")
            validate_image(data, network=role == "network")
        return files["application.bin"], files["network.bin"]
    except (tarfile.TarError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("Malformed firmware bundle") from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path, help="Application binary linked at address 0, or an nRF5340 .tar bundle")
    parser.add_argument("--network-image", type=Path,
                        help="Matching nRF5340 controller binary linked at 0x01000000; no recovery or mass erase")
    parser.add_argument("--serial", required=True, help="Identified Ebyte USB-TTL persistent path")
    parser.add_argument("--openocd", type=Path, default=ROOT / ".cache/nrf5340/openocd/src/openocd")
    parser.add_argument("--adapter-speed", type=int, default=250, help="SWD clock in kHz")
    parser.add_argument("--log-dir", type=Path, default=ROOT / "build/nrf5340")
    parser.add_argument("--expect", help="Require this console marker")
    parser.add_argument("--stop-after", help="End console capture after this marker")
    parser.add_argument("--stop-after-expected", action="store_true",
                        help="Only honor --stop-after after --expect has appeared (multi-boot tests)")
    parser.add_argument("--seconds", type=float, default=15)
    args = parser.parse_args()
    if args.adapter_speed <= 0:
        parser.error("Adapter speed must be positive")
    image = args.image.resolve()
    try:
        if image.suffix == ".tar":
            if args.network_image:
                parser.error("A bundle already supplies its network image")
            data, network = load_bundle(image)
        else:
            data = image.read_bytes()
            network = args.network_image.read_bytes() if args.network_image else None
        validate_image(data)
        if network is not None:
            validate_image(network, network=True)
        if network is None:
            tcl_path(image)
        tcl_path(args.log_dir.resolve())
    except ValueError as error:
        parser.error(str(error))
    args.log_dir = args.log_dir.resolve()
    args.log_dir.mkdir(parents=True, exist_ok=True)
    network_image = None
    if network is not None:
        image, network_image = stage_images(args.log_dir, data, network)
    console = serial.Serial(None, 115200, timeout=.2)
    console.dtr = False
    console.rts = False
    console.port = args.serial
    console.open()
    console.reset_input_buffer()
    try:
        command = [str(args.openocd), "-s", str(ROOT / ".cache/nrf5340/openocd/tcl"),
                   "-c", "set TOIT_FLASH_DISCARD_RAM 1",
                   *(["-c", "set TOIT_NETWORK_CORE 1; set TOIT_FLASH_NETWORK 1"] if network_image else []),
                   "-f", str(ROOT / "toolchains/nrf5340/openocd.cfg"), "-c",
                   programming_commands(image, args.adapter_speed, network_image)]
        with (args.log_dir / "flash.log").open("w") as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True,
                           timeout=180 if network_image else 120)
        captured = ""
        deadline = time.monotonic() + args.seconds
        with (args.log_dir / "console.log").open("w") as log:
            while time.monotonic() < deadline:
                line = console.readline().decode(errors="replace")
                if line:
                    print(line, end="", flush=True)
                    log.write(line)
                    log.flush()
                    captured += line
                    expected_seen = not args.expect or args.expect in captured
                    if (args.stop_after and args.stop_after in line and
                            (not args.stop_after_expected or expected_seen)):
                        break
        if args.expect and args.expect not in captured:
            raise SystemExit(f"Missing expected console marker: {args.expect}")
    finally:
        console.close()


if __name__ == "__main__":
    main()
