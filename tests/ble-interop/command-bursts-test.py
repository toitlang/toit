# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Offline negative controls for independent controlled-command evidence."""

from types import SimpleNamespace
import unittest
from bumble.core import UUID
from att_command_bursts import command_bursts


class Client:
    def __init__(self, corrupt=False, properties=6):
        self.value = b'\x07'
        self.writes = 0
        self.reads = 0
        self.corrupt = corrupt
        self.properties = properties

    async def discover_services(self):
        return [SimpleNamespace(uuid=UUID('9f6c6200-8e2a-4b13-9e97-94f353eeb001'))]

    async def discover_characteristics(self, uuids, service):
        return [SimpleNamespace(uuid=UUID('9f6c6201-8e2a-4b13-9e97-94f353eeb001'),
                                handle=3, properties=self.properties)]

    async def read_value(self, handle):
        self.reads += 1
        return b'corrupt' if self.corrupt and self.writes else self.value

    async def write_value(self, handle, value, with_response):
        if handle != 3 or with_response:
            raise RuntimeError('Harness used acknowledged write or wrong handle')
        self.writes += 1
        self.value = value


class BurstsTest(unittest.IsolatedAsyncioTestCase):
    async def test_commands_and_barriers(self):
        client = Client()
        await command_bursts(client)
        self.assertEqual((client.writes, client.reads), (512, 65))
        self.assertEqual(client.value, b'\xff\x01\x00\x00ToitHCI')

    async def test_bad_readback_and_wrong_properties_fail(self):
        client = Client(corrupt=True)
        with self.assertRaisesRegex(RuntimeError, 'readback mismatch'):
            await command_bursts(client)
        self.assertEqual(client.writes, 8)
        with self.assertRaisesRegex(RuntimeError, 'command-only'):
            await command_bursts(Client(properties=14))


if __name__ == '__main__':
    unittest.main()
