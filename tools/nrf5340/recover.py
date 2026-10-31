# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
"""Check a recovery bundle against the board; optionally erase and restore it.

Default: halt, compare backups, recheck empty KMU slots, then resume the prior
application state. --erase-and-restore PERMANENTLY LOSES the unreadable original
network firmware, erases both cores, restores the application and installs the
bundle's controller. Recovery leaves the application halted and network off.
No retry or automatic resumption follows an uncertain erase/programming result.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import time
import uuid

from deploy import ROOT, debugger, tcl_path

spec = importlib.util.spec_from_file_location("prepare_recovery", Path(__file__).with_name("prepare-recovery.py"))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)

APP = "nrf53.cpuapp"
NET = "nrf53.cpunet"
DAP = "nrf53.dap"
UICR = 0x00ff8000
SELECT = 0x50039500
KMU_STATUS = 0x5003940c
FORCEOFF = 0x50005614
WORKAROUND = 0x50005618


def load_bundle(directory):
    manifest = json.loads((directory / "manifest.json").read_text())
    if manifest.get("format") != 1 or manifest.get("network_original_recoverable") is not False:
        raise ValueError("Unsupported recovery bundle")
    files = {}
    for name, size, address in (("application.bin", 0x100000, 0),
                                ("application-uicr-restorable.bin", 4096, UICR),
                                ("controller.bin", None, 0x01000000)):
        record = manifest["files"][name]
        if record["program_address"] != address:
            raise ValueError(f"Unexpected programming address: {name}")
        files[name] = prepare.checked_file(dict(record, file=name), directory, size=size)
    prepare.check_vectors(files["application.bin"])
    prepare.check_vectors(files["controller.bin"], network=True)
    # File contents enforce the empty-key policy; live checks below establish
    # that the actual board still has that configuration.
    prepare.check_uicr(files["application-uicr-restorable.bin"],
                       {"nonempty_key_slots": 0, "all_key_slots_readable": True})
    return files


def read(debug, target, address, size):
    if size % 4:
        raise ValueError("Unaligned read size")
    result = bytearray()
    for offset in range(0, size, 256):
        count = min(256, size - offset) // 4
        words = [int(word, 0) for word in
                 debug.call(f"{target} read_memory {address + offset:#x} 32 {count}").split()]
        if len(words) != count or any(not 0 <= word <= 0xffffffff for word in words):
            raise RuntimeError("Malformed debugger memory response")
        result.extend(struct.pack(f"<{count}I", *words))
    return bytes(result)


def word(debug, address):
    return struct.unpack("<I", read(debug, APP, address, 4))[0]


def ap(debug, number, register):
    return int(debug.call(f"{DAP} apreg {number} {register:#x}"), 0)


def compare(debug, target, address, expected, label):
    actual = read(debug, target, address, len(expected))
    if actual != expected:
        raise RuntimeError(f"{label} does not match; refusing to continue")


def check_uicr(debug, expected):
    compare(debug, APP, UICR, expected[:0x800], "UICR configuration")
    if word(debug, SELECT) != 0:
        raise RuntimeError("KMU is in use; refusing to change its selection")
    try:
        for slot in range(128):
            debug.call(f"{APP} mww {SELECT:#x} {slot + 1}")
            compare(debug, APP, UICR + 0x800 + slot * 16, b"\xff" * 16,
                    f"KMU slot {slot + 1}")
            # SELECTED becomes valid after the key access, not the selection
            # write. Also reject BLOCKED even if the returned value was all 1s.
            if word(debug, KMU_STATUS) & 3 != 1:
                raise RuntimeError(f"KMU slot {slot + 1} is not readable")
            debug.call(f"{APP} mww {SELECT:#x} 0")
    finally:
        if debug.healthy:
            debug.call(f"{APP} mww {SELECT:#x} 0")


def checkpoint(directory, stage, **fields):
    # Persist the uncertainty boundary before issuing an erase, even when the
    # RPC may time out after the hardware has already accepted the command.
    with (directory / "state.json").open("w") as output:
        json.dump(dict(stage=stage, **fields), output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())


def recover(debug, files, directory, *, execute=False, device_id=None, erase_timeout=20):
    # Reject unrepresentable programming paths before touching the target,
    # rather than discovering a Tcl quoting problem after the full erase.
    tcl_path(directory)
    if execute and (device_id is None or len(device_id) != 16):
        raise ValueError("Recovery requires the device ID from a previous check-only run")
    debug.call("poll")
    original = debug.call(f"{APP} curstate")
    if original not in ("running", "halted"):
        raise RuntimeError(f"Unknown application state: {original}")
    destructive = False
    preflight_safe = False
    debug.call(f"{APP} arp_halt")
    try:
        debug.call(f"{APP} arp_waitstate halted 2000")
        # Do not interfere with a live network program during a backup check.
        if word(debug, FORCEOFF) != 1:
            raise RuntimeError("Network core must already be held off")
        for number in (2, 3):
            if ap(debug, number, 0xfc) != 0x12880000:
                raise RuntimeError(f"Wrong CTRL-AP identity at AP{number}")
            if ap(debug, number, 0x18) != 1:
                raise RuntimeError(f"AP{number} erase protection is enabled or unknown")
            if ap(debug, number, 8) != 0:
                raise RuntimeError(f"AP{number} erase already in progress")
        if word(debug, 0x00ff020c) != 0x5340:
            raise RuntimeError("Target is not an nRF5340")
        identity = read(debug, APP, 0x00ff0204, 8).hex()
        if device_id is not None and identity != device_id.lower():
            raise RuntimeError("Device identity does not match the requested target")
        compare(debug, APP, 0, files["application.bin"], "Complete application backup")
        check_uicr(debug, files["application-uicr-restorable.bin"])
        preflight_safe = True
        checkpoint(directory, "preflight-passed", device_id=identity)
        if not execute:
            return {"status": "checked-no-erase", "device_id": identity,
                    "original_application_state": original}

        # Re-stage the validated bytes used by this run, never program mutable
        # build paths. UICR writes include only the two supported config words;
        # erased key space must never be written from a masked readback.
        for name, data in files.items():
            (directory / name).write_bytes(data)
        for offset in (0, 0x1c):
            (directory / f"uicr-{offset:x}.bin").write_bytes(
                files["application-uicr-restorable.bin"][offset:offset + 4])
        checkpoint(directory, "erase-may-have-started", device_id=identity)
        destructive = True
        debug.call("poll off")
        debug.call(f"{DAP} apreg 3 4 0")
        debug.call(f"{DAP} apreg 3 4 1")
        deadline = time.monotonic() + erase_timeout
        while True:
            status = ap(debug, 3, 8)
            if status == 0:
                break
            if status != 1 or time.monotonic() >= deadline:
                raise RuntimeError("Recovery did not report erase completion; no retry performed")
            time.sleep(.05)
        checkpoint(directory, "erase-completed", device_id=identity)
        debug.call(f"{DAP} apreg 3 0 1")
        debug.call(f"{DAP} apreg 3 0 0")
        debug.call(f"{DAP} apreg 3 4 0")
        debug.call(f"{APP} arp_examine")
        debug.call(f"targets {APP}")
        debug.call("reset halt")
        debug.call(f"{APP} arp_waitstate halted 2000")
        debug.call(f"{APP} mww {FORCEOFF:#x} 1")
        compare(debug, APP, 0, b"\xff" * 0x100000, "Erased application flash")
        debug.call(f"flash write_image {tcl_path(directory / 'application.bin')} 0 bin")
        compare(debug, APP, 0, files["application.bin"], "Restored application")
        for offset in (0, 0x1c):
            path = directory / f"uicr-{offset:x}.bin"
            debug.call(f"flash write_image {tcl_path(path)} {UICR + offset:#x} bin")
        check_uicr(debug, files["application-uicr-restorable.bin"])
        checkpoint(directory, "application-restored", device_id=identity)

        # Pinned OpenOCD's nrf53_cpunet_release sequence, with errors propagated
        # and reset vector catch installed before releasing the empty core.
        debug.call(f"{APP} mww {WORKAROUND:#x} 1")
        debug.call(f"{APP} mww {FORCEOFF:#x} 0")
        debug.call(f"{APP} mww {FORCEOFF:#x} 1")
        debug.call(f"{NET} arp_examine")
        debug.call(f"{NET} mww 0xe000edfc 0x01000501")
        debug.call(f"{APP} mww {FORCEOFF:#x} 0")
        debug.call(f"{APP} mww {WORKAROUND:#x} 0")
        debug.call(f"{NET} arp_poll")
        debug.call(f"{NET} arp_waitstate halted 2000")
        compare(debug, NET, 0x01000000, b"\xff" * 0x40000, "Erased network flash")
        debug.call(f"targets {NET}")
        debug.call(f"flash write_image {tcl_path(directory / 'controller.bin')} 0x01000000 bin")
        compare(debug, NET, 0x01000000, files["controller.bin"], "Installed controller")
        debug.call(f"targets {APP}")
        debug.call(f"{APP} mww {FORCEOFF:#x} 1")
        compare(debug, APP, 0, files["application.bin"], "Final application and storage")
        checkpoint(directory, "restored-and-verified-not-started", device_id=identity)
        return {"status": "restored-and-verified-not-started", "device_id": identity}
    finally:
        if destructive or not debug.healthy:
            (directory / "not-resumed.txt").write_text(
                "No resume was issued. Inspect state.json and OpenOCD logs before further hardware operations.\n")
        elif preflight_safe and original == "running":
            debug.call(f"targets {APP}")
            debug.call("resume")
        elif not preflight_safe:
            # Unknown target state or a failed key check merits inspection,
            # not automatic execution of a potentially mismatched application.
            (directory / "not-resumed.txt").write_text("Preflight failed; application was not resumed.\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--erase-and-restore", action="store_true",
                        help="Permanently replace original network firmware; requires explicit owner approval")
    parser.add_argument("--device-id", help="Exact FICR ID reported by a previous check-only run")
    parser.add_argument("--openocd", type=Path, default=ROOT / ".cache/nrf5340/openocd/src/openocd")
    parser.add_argument("--log-dir", type=Path, default=ROOT / "build/nrf5340-recovery")
    args = parser.parse_args()
    if args.erase_and_restore and not args.device_id:
        parser.error("--erase-and-restore requires --device-id from a check-only run")
    directory = None
    try:
        files = load_bundle(args.bundle)
        directory = args.log_dir / uuid.uuid4().hex
        directory.mkdir(parents=True)
        checkpoint(directory, "validated-offline", hashes={name: hashlib.sha256(data).hexdigest()
                                                         for name, data in files.items()})
        with debugger(args.openocd, directory / "openocd.log", network=True,
                      recovery=args.erase_and_restore) as debug:
            result = recover(debug, files, directory, execute=args.erase_and_restore,
                             device_id=args.device_id)
        result["log_dir"] = str(directory)
        (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
    except (ValueError, KeyError, TypeError, OSError, RuntimeError) as error:
        if directory is not None and directory.is_dir():
            (directory / "error.json").write_text(json.dumps({"error": str(error)}) + "\n")
        parser.exit(1, f"Recovery stopped: {error}; logs={directory}\n")


if __name__ == "__main__":
    main()
