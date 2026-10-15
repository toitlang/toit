# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

from types import SimpleNamespace
import unittest

from bumble import hci, smp
from advertising_updates import DATA, RESPONSE, validate_board
from private_advertising_updates import TEST_IRK, PrivateUpdates, select_private


def feed(sequence, *, rotate=True):
    for mode in range(2):
        for phase in range(4):
            for sample in range(20):
                offset = phase * 5 + sample * 0.2
                now = mode * 24 + offset
                address = f'{mode}-{int(offset) if rotate else 0}'
                sequence.observe_private(now, DATA[mode][phase], address,
                                         connectable=False, scannable=bool(mode), scan_response=False)
                if mode:
                    sequence.observe_private(now + 0.01, RESPONSE[phase], address,
                                             connectable=False, scannable=True, scan_response=True)


class PrivateUpdateTest(unittest.TestCase):
    def test_updates_and_rotation(self):
        sequence = PrivateUpdates()
        feed(sequence)
        verdict = sequence.finish(55)
        self.assertEqual(verdict['reports'], [[20] * 4] * 3)
        self.assertEqual(verdict['addresses_per_phase'], [[4] * 4] * 3)
        self.assertEqual(verdict['rotations'], [15] * 3)
        self.assertTrue(verdict['private'])

    def test_updates_do_not_substitute_for_rotation(self):
        sequence = PrivateUpdates()
        feed(sequence, rotate=False)
        with self.assertRaisesRegex(RuntimeError, 'Insufficient rotation'):
            sequence.finish(55)

    def test_rotation_gaps_and_reappearing_addresses(self):
        flags = dict(connectable=False, scannable=False, scan_response=False)
        for gap in (0.1, 2.6):
            sequence = PrivateUpdates()
            sequence.observe_private(0, DATA[0][0], 'first', **flags)
            with self.assertRaisesRegex(RuntimeError, 'interval'):
                sequence.observe_private(gap, DATA[0][0], 'next', **flags)
        sequence = PrivateUpdates()
        sequence.observe_private(0, DATA[0][0], 'first', **flags)
        sequence.observe_private(1, DATA[0][0], 'next', **flags)
        with self.assertRaisesRegex(RuntimeError, 'reappeared'):
            sequence.observe_private(2, DATA[0][0], 'first', **flags)

    def test_private_identity_selection_including_empty_phase(self):
        peer = hci.Address('98:CD:AC:60:E0:AE', hci.Address.PUBLIC_DEVICE_ADDRESS)
        other = hci.Address('98:CD:AC:60:E0:AF', hci.Address.PUBLIC_DEVICE_ADDRESS)
        resolver = smp.AddressResolver([(TEST_IRK[::-1], peer)])
        private = hci.Address.generate_private_address(TEST_IRK[::-1])
        for payload in (b'', DATA[0][0], RESPONSE[1]):
            self.assertTrue(select_private(SimpleNamespace(address=private, data_bytes=payload), peer, resolver))
        self.assertFalse(select_private(SimpleNamespace(address=other, data_bytes=b''), peer, resolver))
        for address, payload in ((peer, b''), (other, DATA[0][0]),
                                 (hci.Address.generate_private_address(bytes(16)), RESPONSE[1])):
            with self.assertRaisesRegex(RuntimeError, 'did not resolve'):
                select_private(SimpleNamespace(address=address, data_bytes=payload), peer, resolver)

    def test_scan_response_address_must_also_advertise(self):
        sequence = PrivateUpdates()
        feed(sequence)
        sequence.addresses[2][0].add('unseen')
        with self.assertRaisesRegex(RuntimeError, 'unobserved advertising address'):
            sequence.finish(55)

    def test_private_controller_counts(self):
        lines = []
        for mode in range(2):
            lines.extend(f'ADVERTISING_UPDATE APPLIED mode={mode} phase={phase} gc=true' for phase in range(4))
            lines.append(f'ADVERTISING_UPDATE STOPPED mode={mode}')
        lines.extend(['ADVERTISING_UPDATE COMPLETE',
                      'ADVERTISING_UPDATE_PRIVATE_PROVIDER COMPLETE opens=2 closes=2 addresses=40 enables=40 disables=40 data=8 response=8'])
        text = '\n'.join(lines)
        validate_board(text, private=True)
        # Each of the two stops may land after setting the next address but
        # before enabling it. The provider checks that bound per lifetime.
        validate_board(text.replace('addresses=40', 'addresses=42'), private=True)
        for bad in (text.replace('disables=40', 'disables=39'), text.replace('data=8', 'data=40'),
                    text.replace('=40', '=2'), text.replace('addresses=40', 'addresses=43'),
                    text + '\n' + lines[-1]):
            with self.assertRaises(RuntimeError):
                validate_board(bad, private=True)
        with self.assertRaises(RuntimeError):
            validate_board(text)


if __name__ == '__main__':
    unittest.main()
