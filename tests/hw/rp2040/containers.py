#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Build and test persistent RP2040 containers, then restore the storage fixtures."""
import argparse
from pathlib import Path
import struct
import subprocess

from stdio import wait_application

ROOT = Path(__file__).resolve().parents[3]


def assets(entries):
    data = bytearray(struct.pack('<II', 0x6395f9f1, len(entries)))
    for name, value in entries.items():
        for field in (name.encode(), value):
            data.extend(struct.pack('<I', len(field)))
            data.extend(field)
            data.extend(bytes(-len(field) % 4))
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--toit', type=Path, required=True)
    parser.add_argument('--envelope', type=Path, required=True)
    parser.add_argument('--port', required=True)
    parser.add_argument('--id', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--build-only', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    toit = args.toit.resolve()
    native = toit.parents[1] / 'lib/toit/bin/rp2040-ota-upload'

    def run(*arguments):
        subprocess.run([str(toit), *map(str, arguments)], check=True)

    child_snapshot = args.output / 'child.snapshot'
    child_assets = args.output / 'child-assets.bin'
    child_image = args.output / 'child.image'
    child_assets.write_bytes(assets({'marker': b'rp2040-persistent-container-assets'}))
    run('compile', '-s', '-o', child_snapshot, Path(__file__).with_name('container-child.toit'))
    run('tool', 'snapshot-to-image', '--format=binary', '-m32', '--assets', child_assets,
        '-o', child_image, child_snapshot)
    installer_assets = args.output / 'installer-assets.bin'
    installer_assets.write_bytes(assets({'container': child_image.read_bytes()}))
    cases = [
        ('container-install', 'container-install-rp2040: PASS installed image and assets survived reset'),
        ('container-persistence', 'container-persistence-rp2040: PASS image, metadata, assets, firmware replacement and uninstall'),
        ('storage-write-rp2040', 'storage-write-rp2040: PASS buckets, regions, page boundaries, and reopen'),
        ('storage-exhaustion', 'storage-exhaustion: PASS rejected writes, aliases, reopen and reclaimed space'),
        ('vm-smoke', 'RP2040 VM/GC/timer smoke: PASS'),
    ]
    images = []
    for name, marker in cases:
        snapshot = args.output / f'{name}.snapshot'
        envelope = args.output / f'{name}.envelope'
        binary = args.output / f'{name}.bin'
        run('compile', '-s', '-o', snapshot, Path(__file__).with_name(f'{name}.toit'))
        options = ['--assets', installer_assets] if name == 'container-install' else []
        run('tool', 'firmware', '-e', args.envelope, 'container', 'install',
            '--output', envelope, *options, 'test', snapshot)
        run('tool', 'firmware', '-e', envelope, 'extract', '--format=binary', '-o', binary)
        images.append((binary, marker))
    if args.build_only:
        return
    for binary, marker in images:
        subprocess.run([str(native), '--port', args.port, '--id', args.id, str(binary)], check=True)
        child_prefix = 'container-child-rp2040: PASS assets, GC and token='
        if binary.stem == 'container-persistence':
            stream, console = wait_application(args.port, 'container-persistence-rp2040: READY cleanup',
                                               [child_prefix + 'boot', child_prefix + 'after-update'])
            with stream:
                console.command('cleanup')
                console.expect(marker)
                print(marker, flush=True)
        else:
            required = [child_prefix + token for token in ('rpc', 'boot', 'after-reset')] \
                if binary.stem == 'container-install' else []
            stream, _ = wait_application(args.port, marker, required)
            stream.close()
    print('RP2040 installed containers, reboot, firmware replacement and storage restoration: PASS', flush=True)


if __name__ == '__main__':
    main()
