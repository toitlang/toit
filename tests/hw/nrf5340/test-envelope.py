# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
"""Exercise the firmware CLI against the profiles built by check-build.sh."""
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile


def ar_entries(data):
    assert data[:8] == b"!<arch>\n"
    at = 8
    while at < len(data):
        header = data[at:at + 60]
        assert header[58:] == b"`\n"
        size = int(header[48:58])
        end = at + 60 + size
        yield header[:16].decode().strip().rstrip("/"), at, end + size % 2, data[at + 60:end]
        at = end + size % 2
    assert at == len(data)


def main():
    build = Path(sys.argv[1]).resolve()
    host = build / "host/sdk/bin/toit"

    def cli(envelope, *args, error=None):
        result = subprocess.run([str(host), "tool", "firmware", f"--envelope={envelope}",
                                 *map(str, args)], capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        if error:
            assert result.returncode != 0 and error in output, output
        else:
            assert result.returncode == 0, output

    def unpack(path, controller):
        with tarfile.open(path, "r:") as archive:
            assert sorted(archive.getnames()) == ["application.bin", "manifest.json", "network.bin"]
            manifest = json.load(archive.extractfile("manifest.json"))
            assert manifest["format"] == 1 and manifest["target"] == "nrf5340"
            images = {}
            for name, address in (("application", 0), ("network", 0x01000000)):
                data = archive.extractfile(name + ".bin").read()
                assert manifest[name] == {"file": name + ".bin", "address": address,
                                          "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                images[name] = data
            assert images["network"] == controller.read_bytes()
            assert 8 < len(images["application"]) <= 0xdc000
            return images

    with tempfile.TemporaryDirectory(prefix="envelope-", dir=build) as directory:
        work = Path(directory)
        default = build / "default/toit.envelope"
        cli(default, "extract", "--format=binary", "-o", work / "default.bin")
        for profile, version in (("default", 1003), ("ble", 1004), ("secure", 1004)):
            source = build / profile / "toit.envelope"
            data = source.read_bytes()
            entries = {name: (start, end, payload) for name, start, end, payload in ar_entries(data)}
            info_start, _, info = entries["$envelope"]
            assert struct.unpack_from("<I", info, 4)[0] == version
            malformed = bytearray(data)
            struct.pack_into("<I", malformed, info_start + 64, 1004 if version == 1003 else 1003)
            bad = work / "mismatch.envelope"
            bad.write_bytes(malformed)
            cli(bad, "show", error="version and controller contents disagree")
            if profile == "default":
                continue
            envelope = work / f"{profile}.envelope"
            shutil.copyfile(source, envelope)
            controller = build / profile / "network/zephyr/zephyr.bin"
            bundle = work / f"{profile}.tar"
            cli(envelope, "extract", "--format=binary", "-o", work / "forbidden.bin",
                error="--format=tar")
            assert not (work / "forbidden.bin").exists()
            cli(envelope, "extract", "--format=tar", "-o", bundle)
            original = unpack(bundle, controller)
            snapshot = work / "app.snapshot"
            snapshot.write_bytes(entries["app0"][2])
            cli(envelope, "container", "uninstall", "app0")
            cli(envelope, "extract", "--format=tar", "-o", bundle)
            removed = unpack(bundle, controller)
            assert len(removed["application"]) < len(original["application"])
            cli(envelope, "container", "install", "app0", snapshot)
            cli(envelope, "extract", "--format=tar", "-o", bundle)
            assert unpack(bundle, controller) == original
            start, end, _ = entries["$zephyr-net.bin"]
            bad.write_bytes(data[:start] + data[end:])
            cli(bad, "show", error="version and controller contents disagree")
            print(f"{profile}: bundle hashes, container edits, and rejection checks passed")
    print("Default application-only and both two-core envelope profiles passed")


if __name__ == "__main__":
    main()
