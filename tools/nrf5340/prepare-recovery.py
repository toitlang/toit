# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
"""Stage a verified nRF5340 recovery bundle without accessing hardware.

This deliberately does not erase or flash a device. The bundle records the
irrecoverable loss of the original network firmware and the live checks still
required before recovery. Relative input paths are relative to --root.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import tempfile

ROOT = Path(__file__).resolve().parents[2]
APP_SIZE = 0x100000
STORAGE_BASE = 0xe0000
FIRMWARE_LIMIT = 0xdc000
UICR_SIZE = 0x1000
UNPROTECTED = 0x50fa50fa


def digest(data):
    return hashlib.sha256(data).hexdigest()


def checked_file(record, root, *, path_key="file", size=None):
    path = root / record[path_key]
    data = path.read_bytes()
    if len(data) != record["size"] or (size is not None and len(data) != size):
        raise ValueError(f"Unexpected size: {path}")
    if digest(data) != record["sha256"]:
        raise ValueError(f"SHA-256 mismatch: {path}")
    return data


def check_vectors(data, *, network=False):
    base = 0x01000000 if network else 0
    ram = 0x21000000 if network else 0x20000000
    ram_size = 0x10000 if network else 0x80000
    limit = 0x40000 if network else APP_SIZE
    if not 8 <= len(data) <= limit:
        raise ValueError("Invalid firmware size")
    stack, entry = struct.unpack_from("<II", data)
    if not ram < stack <= ram + ram_size or stack % 8:
        raise ValueError("Invalid initial stack pointer")
    if not entry & 1 or not base + 8 <= entry & ~1 < base + len(data):
        raise ValueError("Invalid reset vector")


def check_uicr(data, record):
    # Narrowly support this bring-up board's known, empty-KMU configuration.
    # Do not generalize a masked key dump into a restorable backup.
    if record.get("nonempty_key_slots") != 0 or record.get("all_key_slots_readable") is not True:
        raise ValueError("Recovery requires a verified empty KMU")
    expected = bytearray(b"\xff" * UICR_SIZE)
    struct.pack_into("<I", expected, 0, UNPROTECTED)
    struct.pack_into("<I", expected, 0x1c, UNPROTECTED)
    if data != expected:
        raise ValueError("Unsupported UICR configuration or masked key material")


def collect(plan, root):
    if plan.get("network_original_recoverable") is not False:
        raise ValueError("Plan must explicitly record that original network firmware is unrecoverable")
    restore = plan["application_restore"]
    if restore["network"].get("backed_up") is not False:
        raise ValueError("Unexpected network backup claim")
    app = checked_file(restore["application"], root, size=APP_SIZE)
    check_vectors(app)
    uicr = checked_file(restore["application-uicr"], root, size=UICR_SIZE)
    check_uicr(uicr, restore["application-uicr"])
    # Keep the raw dump only as evidence, never as a programming input.
    raw = checked_file(restore["application-uicr-raw"], root, size=UICR_SIZE)
    if raw[:0x800] != uicr[:0x800]:
        raise ValueError("Raw and restorable UICR configuration disagree")
    if raw[0x800:] != struct.pack("<I", 0xdeaddead) * 512:
        raise ValueError("Unexpected raw KMU mask; revalidate the backup procedure")
    files = {
        "application.bin": (app, 0),
        "application-uicr-restorable.bin": (uicr, 0x00ff8000),
        "evidence/application-uicr-raw.bin": (raw, None),
        "evidence/storage.bin": (app[STORAGE_BASE:], None),
        "evidence/settings.bin": (app[FIRMWARE_LIMIT:STORAGE_BASE], None),
    }
    for name in ("controller", "native-probe", "optional-vm"):
        data = checked_file(plan["images"][name], root, path_key="path")
        check_vectors(data, network=name == "controller")
        if name != "controller" and len(data) > FIRMWARE_LIMIT:
            raise ValueError(f"{name} overlaps persistent storage")
        vectors = [int(value, 0) for value in plan["images"][name]["vectors"]]
        if vectors != list(struct.unpack_from("<II", data)):
            raise ValueError(f"{name} vector metadata disagrees with image")
        files[f"{name}.bin"] = (data, 0x01000000 if name == "controller" else 0)
    return files


def prepare(plan_path, root, destination):
    # Validate every input before creating output; hold validated bytes rather
    # than copying source paths that a concurrent build may replace.
    plan_bytes = plan_path.read_bytes()
    files = collect(json.loads(plan_bytes), root)
    destination = destination.absolute()
    if destination.exists():
        raise ValueError(f"Refusing to replace existing bundle: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".recovery-", dir=destination.parent))
    try:
        manifest = {
            "format": 1,
            "status": "prepared-offline-not-authorized",
            "source_plan_sha256": digest(plan_bytes),
            "network_original_recoverable": False,
            "hardware_validated": False,
            "files": {},
            "required_live_checks": [
                "Obtain explicit approval to lose the unreadable original network firmware",
                "Identify the target and halt the application; keep the network core off",
                "Compare all 1 MiB of application flash with application.bin",
                "Recheck application UICR and individually select/read all 128 empty KMU slots",
                "Check both CTRL-AP identities and erase-protection status",
                "Recover via network CTRL-AP once; require ERASEALLSTATUS completion before reset",
                "Restore and verify complete application flash and sanitized application UICR",
                "Program and verify controller before allowing it to run",
                "Compare all 128 KiB of persistent storage after radio tests and VM restoration",
            ],
        }
        for name, (data, address) in files.items():
            path = staging / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(0o444)
            manifest["files"][name] = {
                "size": len(data), "sha256": digest(data), "program_address": address,
            }
        (staging / "source-plan.json").write_bytes(plan_bytes)
        (staging / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        # mkdir reserves the destination without overwriting an existing
        # directory, including one created after the initial existence check.
        destination.mkdir()
        try:
            for path in staging.iterdir():
                if path.name != "manifest.json":
                    os.rename(path, destination / path.name)
            # A consumer must require the manifest; publish it last.
            os.rename(staging / "manifest.json", destination / "manifest.json")
        except BaseException:
            shutil.rmtree(destination)
            raise
        return manifest
    finally:
        shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    try:
        manifest = prepare(args.plan, args.root, args.destination)
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, f"Recovery bundle rejected: {error}\n")
    print(json.dumps({"bundle": str(args.destination.resolve()), "status": manifest["status"],
                      "files": len(manifest["files"])}, indent=2))


if __name__ == "__main__":
    main()
