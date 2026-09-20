#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
"""Embed a 32-bit relocatable Toit image using linker-resolved pointers."""
import pathlib
import struct
import sys

def read_image(path):
    data = bytearray(pathlib.Path(path).read_bytes())
    if not data or len(data) % 132:
        raise SystemExit("Expected 32-bit relocatable image (132-byte blocks)")
    size = len(data) // 132 * 128
    program_size = struct.unpack_from('<H', data, 4 + 30)[0] * 4096
    if not program_size or program_size > size:
        raise SystemExit("Invalid program size in Toit image")
    if size > program_size:
        # Embedded images bypass the normal asset writer's header update.
        asset_length_offset = (program_size // 128) * 132 + 4
        asset_length = struct.unpack_from('<I', data, asset_length_offset)[0]
        if asset_length > size - program_size - 4:
            raise SystemExit("Toit assets exceed the image")
        data[4 + 24] |= 0x80
    return data, size


# Keep the original INPUT OUTPUT invocation; additional inputs become bundled
# boot containers. Each has its own relocation base and process lifetime.
images = [read_image(path) for path in [sys.argv[1]] + sys.argv[3:]]
if len(images) > (4096 - 20) // 8:
    raise SystemExit("Too many bundled images")
used = 4096 + sum((size + 4095) // 4096 * 4096 for _, size in images)
checksum = 0x98DFC301 ^ used ^ len(images) ^ 0xB3147EE9
lines = [
    '.section .rodata.toit_program,"a",%progbits',
    '.balign 4096',
    '.global toit_embedded_extension',
    'toit_embedded_extension:',
    f'.long 0x98dfc301, {used}, 0, {len(images)}, {checksum}',
]
for index, (_, size) in enumerate(images):
    lines.append(f'.long toit_program_{index}, {size}')
lines += [
    '.global toit_program',
    '.set toit_program, toit_program_0',
    '.global toit_program_uuid',
    '.set toit_program_uuid, toit_program_0 + 32',
]
for index, (data, _) in enumerate(images):
    if index != 0:
        # Auto-start application containers without marking them critical.
        data[4 + 24] |= 1
    symbol = f'toit_program_{index}'
    lines += ['.balign 4096', f'{symbol}:']
    for offset in range(0, len(data), 132):
        mask, *words = struct.unpack_from('<33I', data, offset)
        for bit, word in enumerate(words):
            lines.append(f'.long {symbol} + {word}' if mask & (1 << bit)
                         else f'.long {word}')
lines.append('.balign 4096')
pathlib.Path(sys.argv[2]).write_text('\n'.join(lines) + '\n')
