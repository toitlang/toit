#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Verify deterministic partial NOR writes and recovery on an RP2040."""
import argparse
from pathlib import Path
import subprocess
import sys

import serial

from stdio import wait_application

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/rp2040'))
import upload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--uploader', required=True, type=Path)
    parser.add_argument('--port', required=True)
    parser.add_argument('--id', required=True)
    parser.add_argument('--image', required=True, type=Path)
    parser.add_argument('--restore-image', required=True, type=Path)
    args = parser.parse_args()
    for image in (args.image, args.restore_image):
        upload.validate_image(image.read_bytes())

    def install(image):
        subprocess.run([str(args.uploader), '--port', args.port, '--id', args.id, str(image)], check=True)

    install(args.image)
    stream, console = wait_application(args.port, 'storage-interruption: READY')
    for mode, expected in ((1, 17), (2, 17), (3, 34), (4, 34), (5, 0), (6, 0)):
        with stream:
            stream.write(str(mode).encode())
        stream, console, _ = upload.wait_ready(serial, args.port, args.id, timeout=20)
        with stream:
            console.command('boot')
        stream, console = wait_application(args.port, 'storage-interruption: READY')
        try:
            stream.write(b'v' + bytes([expected]))
            console.expect(f'storage-interruption: PASS value={expected} and unrelated data intact')
            print(f'PASS: storage fault {mode}, recovered value {expected}, unrelated data intact', flush=True)
            console.expect('storage-interruption: READY')
        except BaseException:
            stream.close()
            raise
    stream.close()
    install(args.restore_image)
    stream, _ = wait_application(args.port, 'RP2040 VM/GC/timer smoke: PASS')
    stream.close()
    print('RP2040 storage interruption hardware: PASS; ordinary firmware restored', flush=True)


if __name__ == '__main__':
    main()
