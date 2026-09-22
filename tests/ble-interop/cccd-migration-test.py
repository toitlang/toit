# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Exercises the migration oracle against Bumble's real ATT dispatch/confirmation."""

import logging
from types import SimpleNamespace
import unittest

from bumble import att, gatt_client
from cccd_migration import Guard

logging.disable(logging.CRITICAL)


class GuardTest(unittest.TestCase):
    def client(self, *, cycle=0, withhold=False, changed=True):
        sent = []
        bearer = SimpleNamespace(handle=1, EVENT_DISCONNECTION="disconnection",
                                 on=lambda *_: None,
                                 send_l2cap_pdu=lambda cid, pdu: sent.append((cid, bytes(pdu))))
        client = gatt_client.Client(bearer)
        return client, Guard(client, cycle, withhold=withhold, changed=changed), sent

    def incoming(self, client, handle, value, *, indication=True):
        pdu = bytes((0x1d if indication else 0x1b, handle, 0)) + bytes(value)
        client.on_gatt_pdu(att.ATT_PDU.from_bytes(pdu))

    def test_real_bumble_confirmation_is_withheld_at_send_boundary(self):
        client, guard, sent = self.client(withhold=True)
        self.incoming(client, 8, b"\x01\x00\xff\xff")
        self.assertEqual(sent, [])
        self.assertEqual(guard.withheld, 1)
        client.send_gatt_pdu(b"\x12\x15\x00\x00")
        guard.verify()
        self.assertEqual(sent, [(att.ATT_CID, b"\x12\x15\x00\x00")])

    def test_exact_delivery_and_confirmations_on_both_resume_cycles(self):
        for cycle in (0, 1):
            client, guard, sent = self.client(cycle=cycle, changed=cycle == 0)
            if cycle == 0:
                self.incoming(client, 8, b"\x01\x00\xff\xff")
            client.send_gatt_pdu(b"\x12\x15\x00\x01")
            for index in range(20):
                self.incoming(client, 15, (cycle, index, 42), indication=False)
                self.incoming(client, 18, (cycle, index, 43))
            guard.verify()
            self.assertTrue(guard.ready.is_set())
            self.assertEqual(sum(pdu == b"\x1e" for _, pdu in sent), 21 - cycle)

    def test_rewrites_prepared_writes_and_repeated_control_are_rejected(self):
        for pdu in (b"\x12\x09\x00\x02\x00", b"\x52\x10\x00\x01\x00",
                    b"\x16\x13\x00\x00\x00\x02\x00", b"\x18\x01"):
            client, guard, sent = self.client()
            with self.assertRaisesRegex(RuntimeError, "CCCD rewrites are forbidden"):
                client.send_gatt_pdu(pdu)
            self.assertEqual(sent, [])
        client, guard, sent = self.client()
        client.send_gatt_pdu(b"\x12\x15\x00\x01")
        with self.assertRaises(RuntimeError):
            client.send_gatt_pdu(b"\x12\x15\x00\x01")
        self.assertEqual(len(sent), 1)

    def test_decoy_early_wrong_kind_and_corrupt_updates_fail(self):
        for handle, value, indication in ((12, b"\x63", False),
                                          (15, b"\x00\x00\x2a", False),
                                          (8, b"\x01\x00\xff\xff", False),
                                          (8, b"\x02\x00\xff\xff", True)):
            client, guard, _ = self.client()
            self.incoming(client, handle, value, indication=indication)
            with self.assertRaises(RuntimeError):
                guard.check_error()

    def test_unexpected_repeated_or_missing_service_changed_fails(self):
        client, guard, _ = self.client(changed=False)
        self.incoming(client, 8, b"\x01\x00\xff\xff")
        with self.assertRaises(RuntimeError):
            guard.check_error()
        client, guard, _ = self.client(withhold=True)
        client.send_gatt_pdu(b"\x12\x15\x00\x00")
        with self.assertRaises(RuntimeError):
            guard.verify()
        self.incoming(client, 8, b"\x01\x00\xff\xff")
        self.incoming(client, 8, b"\x01\x00\xff\xff")
        with self.assertRaises(RuntimeError):
            guard.verify()

    def test_unassociated_confirmation_fails(self):
        client, _, sent = self.client()
        with self.assertRaisesRegex(RuntimeError, "Unassociated"):
            client.send_confirmation(att.ATT_Handle_Value_Confirmation())
        self.assertEqual(sent, [])


if __name__ == "__main__":
    unittest.main()
