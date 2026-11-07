#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
"""Validate a host-native RP2040 bundle independently of its build directory."""
import argparse
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/rp2040"))
import upload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="rp2040-bundle-") as directory:
        with tarfile.open(args.archive) as archive:
            # Supported CI Python versions predate tarfile's data filter.
            for member in archive.getmembers():
                if member.name.startswith("/") or ".." in Path(member.name).parts or not (member.isfile() or member.isdir()):
                    raise ValueError("Unsafe bundle member")
            archive.extractall(directory)
        roots = list(Path(directory).iterdir())
        assert len(roots) == 1
        root = roots[0]
        assert {p.name for p in root.iterdir()} == {
            "firmware.bin", "firmware.envelope", "recovery.uf2",
            "rp2040-ota-upload", "README.md", "LICENSE",
        }
        upload.validate_image((root / "firmware.bin").read_bytes())
        data = (root / "recovery.uf2").read_bytes()
        assert data and len(data) % 512 == 0
        addresses = set()
        for offset in range(0, len(data), 512):
            words = struct.unpack_from("<8I", data, offset)
            assert words[:2] == (0x0a324655, 0x9e5d5157)
            assert words[2] == 0x2000 and words[4] == 256 and words[7] == 0xe48bff56
            assert 0x10000000 <= words[3] and words[3] + words[4] <= 0x10010000
            assert words[3] % 256 == 0 and words[3] not in addresses
            addresses.add(words[3])
            assert words[5] == offset // 512 and words[6] == len(data) // 512
            assert struct.unpack_from("<I", data, offset + 508)[0] == 0x0ab16f30
        assert 0x10000000 in addresses
        subprocess.run([str(root / "rp2040-ota-upload"), "--help"], cwd=directory, check=True)
        subprocess.run([sys.executable, str(ROOT / "tools/rp2040/ota-upload/test_upload.py"),
                        str(root / "rp2040-ota-upload")], cwd=directory, check=True)
    print("PASS: standalone RP2040 bundle, uploader and loader-only UF2 bounds")


if __name__ == "__main__":
    main()
