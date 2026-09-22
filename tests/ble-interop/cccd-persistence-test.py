# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Optional CCCD radio-oracle checks; no controller or capability required."""

from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock

from cccd_persistence import Updates, WriteGuard, attach_local, private_log


class UpdatesTest(unittest.TestCase):
    def test_private_address_match_requires_one_exact_resolved_connection(self):
        local = "412345678901"
        peer = "523456789012"
        good = f"CCCD_PRIVATE CONNECTED cycle=1 local={local} peer={peer} resolved=true\r\n".encode()
        private_log(good, 1, local, peer)
        for bad in (b"", good + good, good.replace(b"cycle=1", b"cycle=0"),
                    good.replace(b"resolved=true", b"resolved=false"),
                    good.replace(local.encode(), peer.encode()),
                    good.replace(b"true\r", b"true-extra\r")):
            with self.subTest(bad=bad), self.assertRaisesRegex(RuntimeError, "addresses differ"):
                private_log(bad, 1, local, peer)

    def test_exact_sequences(self):
        updates = Updates(1)
        for name, values in updates.expected.items():
            for value in values:
                updates.record(name, value)
        self.assertTrue(updates.ready.is_set())
        updates.verify()

    def test_missing_corrupt_duplicate_and_wrong_cycle_fail(self):
        for defect in ("missing", "corrupt", "duplicate", "cycle"):
            with self.subTest(defect=defect):
                updates = Updates(1)
                for name, values in updates.expected.items():
                    for index, value in enumerate(values):
                        if name == "changed" and defect == "missing":
                            continue
                        if name == "notification" and index == 0:
                            if defect == "corrupt":
                                value = value[:-1] + b"\x00"
                            elif defect == "cycle":
                                value = b"\x00" + value[1:]
                        updates.record(name, value)
                if defect == "duplicate":
                    updates.record("indication", b"\x01\x13\x2b")
                with self.assertRaisesRegex(RuntimeError, "sequence mismatch"):
                    updates.verify()


class WriteGuardTest(unittest.IsolatedAsyncioTestCase):
    async def test_resumption_rejects_both_handle_and_proxy_writes(self):
        client = SimpleNamespace(write_value=AsyncMock())
        guard = WriteGuard(client, [4], allow=False)
        for target in (4, SimpleNamespace(handle=4)):
            with self.assertRaisesRegex(RuntimeError, "rewrite forbidden"):
                await guard.write(target, b"\x01\x00", True)
        client.write_value.assert_not_awaited()
        await guard.write(9, b"\x01", True)
        client.write_value.assert_awaited_once_with(9, b"\x01", True)
        self.assertEqual(guard.count, 0)

    async def test_initial_writes_are_counted(self):
        client = SimpleNamespace(write_value=AsyncMock())
        guard = WriteGuard(client, [4], allow=True)
        await guard.write(4, b"\x01\x00", True)
        self.assertEqual(guard.count, 1)
        client.write_value.assert_awaited_once()

    async def test_local_listeners_never_write_configuration(self):
        client = SimpleNamespace(write_value=AsyncMock(), notification_subscribers={},
                                 indication_subscribers={})
        characteristic = SimpleNamespace(handle=3, client=client)
        observed = []
        for indication in (False, True):
            attach_local(characteristic, observed.append, indication=indication)
            table = client.indication_subscribers if indication else client.notification_subscribers
            for subscriber in table[3]:
                subscriber(b"\x2a")
        self.assertEqual(observed, [b"\x2a", b"\x2a"])
        client.write_value.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()
