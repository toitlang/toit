#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Reopen actual flash buckets at interrupted copy-on-write states."""
import argparse
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

PAGE = 4096
MARKER = 0xdeadface


def allocations(path):
    data = path.read_bytes()
    result = []
    for offset in range(0, len(data), PAGE):
        header = data[offset:offset + 48]
        if struct.unpack_from('<I', header)[0] != MARKER or header[29] != 1:
            continue
        if struct.unpack_from('<I', header, 4)[0] != zlib.crc32(header[8:], MARKER):
            continue
        size = struct.unpack_from('<H', header, 30)[0] * PAGE
        result.append(data[offset:offset + size])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('toit_run', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='toit-storage-recovery-') as directory:
        flash = Path(directory) / 'flash.bin'
        env = dict(os.environ, TOIT_FLASH_REGISTRY_FILE=str(flash))

        checks = 0

        def run(operation, value, failure=None):
            nonlocal checks
            result = subprocess.run([str(args.toit_run.resolve()), str(Path(__file__).with_name('bucket.toit')),
                                     operation, str(value)], env=env, capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            if failure:
                assert result.returncode != 0 and failure in output, output
            else:
                assert result.returncode == 0, output
                assert f'PASS {operation} {value}' in result.stdout, output
            checks += 1

        def state(*copies):
            # Data-region checksums do not depend on their mapped address.
            # Relocation here tests both physical orders deterministically.
            with flash.open('wb') as stream:
                for copy in copies:
                    stream.write(copy)

        run('write', 17)
        old, = allocations(flash)
        assert old[24] == 1 and struct.unpack_from('<I', old, 25)[0] == 1
        run('write', 34)
        new, = allocations(flash)
        assert old[8:24] == new[8:24]
        for copies in ((old, new), (new, old)):
            state(*copies)
            run('read', 34)
            run('read', 34)
            assert len(allocations(flash)) == 1, 'Superseded allocation leaked'
            run('write', 51)
            run('read', 51)
            assert len(allocations(flash)) == 1

        # Non-header pages are written first, then first-page content, and
        # finally the allocation header. Reopen at every page-write boundary.
        partial = bytearray(b'\xff' * len(new))
        ranges = [(i, min(i + 256, len(new))) for i in range(PAGE, len(new), 256)]
        ranges += [(48, 256)] + [(i, i + 256) for i in range(256, PAGE, 256)]
        for start, end in ranges:
            partial[start:end] = new[start:end]
            state(old, partial)
            run('read', 17)
        for cut in range(49):
            partial[:48] = b'\xff' * 48
            partial[:cut] = new[:cut]
            state(old, partial)
            # A prefix can already equal the complete header when its trailing
            # bytes were erased in the committed image as well.
            run('read', 34 if partial[:48] == new[:48] else 17)

        # Invalidation changes only the marker before payload erasure begins.
        # Test both interrupted invalidation and an interrupted sector erase.
        for cut in range(5):
            partial = bytearray(new)
            partial[:cut] = bytes(cut)
            state(partial)
            run('read' if cut == 0 else 'empty', 34 if cut == 0 else 0)
            state(old, partial)
            run('read', 34 if cut == 0 else 17)
        for cut in (0, 1, 2, 3, 4, 48, 256, PAGE - 1, PAGE):
            partial = bytearray(old)
            partial[:4] = bytes(4)
            partial[:cut] = b'\xff' * cut
            state(partial, new)
            run('read', 34)
            state(partial)
            run('empty', 0)
            partial = bytearray(old)
            partial[:4] = bytes(4)
            partial[max(4, cut):PAGE] = b'\xff' * (PAGE - max(4, cut))
            state(partial)
            run('empty', 0)

        def metadata(copy, value):
            result = bytearray(copy)
            result[24:29] = value
            struct.pack_into('<I', result, 4, zlib.crc32(result[8:48], MARKER))
            return result

        legacy = metadata(old, bytes([255]) * 5)
        state(legacy)
        run('read', 17)
        run('write', 34)
        migrated, = allocations(flash)
        assert migrated[24:29] == b'\x01\x01\x00\x00\x00'
        for copies in ((legacy, migrated), (migrated, legacy)):
            state(*copies)
            run('read', 34)
            assert len(allocations(flash)) == 1
        state(metadata(old, b'\x01' + struct.pack('<I', 0xffffffff)))
        run('write', 34)
        wrapped, = allocations(flash)
        assert wrapped[24:29] == b'\x01\x00\x00\x00\x00'
        previous = metadata(old, b'\x01' + struct.pack('<I', 0xffffffff))
        for copies in ((previous, wrapped), (wrapped, previous), (legacy, wrapped)):
            state(*copies)
            run('read', 34)
        state(wrapped)
        run('write', 51)
        run('read', 51)
        run('remove', 0)
        run('empty', 0)
        assert not allocations(flash)

        for copies in ((legacy, metadata(new, bytes([255]) * 5)),
                       (old, metadata(new, old[24:29])),
                       (old, metadata(new, b'\x01' + struct.pack('<I', 0x80000001)))):
            state(*copies)
            run('read', 34, failure='Ambiguous bucket generations')
            assert len(allocations(flash)) == 2, 'Ambiguous data must be preserved'
        state(metadata(old, b'\x02\x00\x00\x00\x00'))
        run('read', 17, failure='Unsupported bucket metadata')
        assert len(allocations(flash)) == 1
        print(f'PASS: {checks} real bucket operations; interrupted page/header writes, invalidation/erase, '
              'physical order, cleanup, legacy migration, wraparound and ambiguous metadata')


if __name__ == '__main__':
    main()
