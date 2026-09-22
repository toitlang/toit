# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Bounded binary pipes for the optional independent radio host; no packet logs."""

import asyncio

class Sink:
    def __init__(self, writer):
        self.writer = writer
        self.count = 0

    def on_packet(self, packet):
        packet = bytes(packet)
        if len(packet) > 2048 or self.writer.transport.get_write_buffer_size() + len(packet) > 65536:
            raise RuntimeError("Bounded HCI pipe exceeded")
        self.writer.write(packet)
        self.count += 1

async def packets(reader, source):
    count = 0
    try:
        while True:
            kind = await reader.read(1)
            if not kind:
                return count
            if kind == b"\x04":
                header = await reader.readexactly(2)
                length = header[1]
            elif kind == b"\x02":
                header = await reader.readexactly(4)
                length = int.from_bytes(header[2:], "little")
            else:
                raise RuntimeError("Unexpected controller packet type")
            if 1 + len(header) + length > 2048:
                raise RuntimeError("Oversized controller packet")
            packet = kind + header + await reader.readexactly(length)
            source.sink.on_packet(packet)
            count += 1
    finally:
        source.on_transport_lost()
