# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Optional radio-pipe regression checks; no hardware, privileges or Bumble host."""

import asyncio
from types import SimpleNamespace
import unittest

from radio_transport import Sink, packets


class PipeTest(unittest.IsolatedAsyncioTestCase):
    async def test_fragmented_and_coalesced_controller_packets(self):
        frames = [b"\x04\x0e\x04\x01\x03\x0c\x00", b"\x02\x01\x20\x01\x00\x07"]
        data = b"".join(frames)
        for split in range(len(data) + 1):
            reader = asyncio.StreamReader()
            seen, ended = [], []
            source = SimpleNamespace(sink=SimpleNamespace(on_packet=seen.append),
                                     on_transport_lost=lambda: ended.append(True))
            reader.feed_data(data[:split])
            pending = asyncio.create_task(packets(reader, source))
            await asyncio.sleep(0)
            reader.feed_data(data[split:])
            reader.feed_eof()
            self.assertEqual(await pending, 2)
            self.assertEqual(seen, frames)
            self.assertEqual(ended, [True])

    async def test_bad_framing_never_delivers_partial_packet(self):
        for data in (b"\x04", b"\x04\x0e\x01", b"\x02\x01", b"\x02\x01\x20\xfc\x07", b"\xff"):
            reader = asyncio.StreamReader()
            reader.feed_data(data)
            reader.feed_eof()
            seen, ended = [], []
            source = SimpleNamespace(sink=SimpleNamespace(on_packet=seen.append),
                                     on_transport_lost=lambda: ended.append(True))
            with self.assertRaises((RuntimeError, asyncio.IncompleteReadError)):
                await packets(reader, source)
            self.assertEqual(seen, [])
            self.assertEqual(ended, [True])

    def test_outgoing_queue_boundary_before_write(self):
        queued = 65533
        seen = []
        writer = SimpleNamespace(transport=SimpleNamespace(get_write_buffer_size=lambda: queued),
                                 write=seen.append)
        sink = Sink(writer)
        with self.assertRaises(RuntimeError):
            sink.on_packet(b"\x01\x03\x0c\x00")
        self.assertEqual(seen, [])
        self.assertEqual(sink.count, 0)
        queued = 65532
        sink.on_packet(b"\x01\x03\x0c\x00")
        self.assertEqual(len(seen), 1)
        self.assertEqual(sink.count, 1)


if __name__ == "__main__":
    unittest.main()
