# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

from types import SimpleNamespace
import unittest

from bumble import hci, smp
from private_advertising_updates import TEST_IRK
from private_rotation_exit import DATA, PrivateRotationExit, select_rotation, validate_rotation_board

FLAGS = dict(connectable=False, scannable=False, scan_response=False)


def complete(*, rotate=True, gap=7):
    sequence = PrivateRotationExit()
    for stage in range(4):
        for sample in range(9 if stage == 3 else 21):
            sequence.observe_private(stage * gap + sample * 0.2, DATA[stage], str(stage), **FLAGS)
        if stage == 2 and rotate:
            for sample in range(2):
                sequence.observe_private(stage * gap + 4.8 + sample * 0.1, DATA[stage], 'rotated', **FLAGS)
    return sequence


def board():
    lines, counts = [], []
    for stage in range(4):
        lines.append(f'PRIVATE_ROTATION_EXIT ACTIVE stage={stage}')
        if stage < 3:
            lines.extend([f'PRIVATE_ROTATION_EXIT HELD stage={stage} status=0',
                          f'PRIVATE_ROTATION_EXIT EXIT stage={stage} pending=true'])
        else:
            lines.append('PRIVATE_ROTATION_EXIT RECOVERED stage=3 stopped=true')
        count = (f'PRIVATE_ROTATION_EXIT COUNTS stage={stage} enables={2 if stage == 2 else 1} '
                 f'disables=1 addresses={2 if stage in (1, 2) else 1} closes=1')
        counts.append(count)
        lines.extend([count, f'PRIVATE_ROTATION_EXIT STOPPED stage={stage} released=true'])
    return '\n'.join(lines + counts + ['PRIVATE_ROTATION_EXIT COMPLETE interrupted=3 recovered=1 opens=4 closes=4'])


class RotationExitTest(unittest.TestCase):
    def test_complete_and_board(self):
        result = complete().finish(26)
        self.assertEqual([len(v) for v in result['visits']], [1, 1, 2, 1])
        validate_rotation_board(board())

    def test_missing_rotation_repetition_gap_and_silence(self):
        with self.assertRaisesRegex(RuntimeError, 'Missing'):
            complete(rotate=False).finish(26)
        with self.assertRaisesRegex(RuntimeError, 'stop gap'):
            complete(gap=5.5).finish(26)
        with self.assertRaisesRegex(RuntimeError, 'cease'):
            complete().finish(23)
        sequence = complete()
        sequence.visits[1][0]['count'] = 1
        with self.assertRaisesRegex(RuntimeError, 'repetition'):
            sequence.finish(26)

    def test_wrong_payload_flags_and_stage(self):
        for payload in (b'', DATA[0] + b'\x00', DATA[1]):
            with self.assertRaises(RuntimeError):
                PrivateRotationExit().observe_private(0, payload, 'a', **FLAGS)
        for flag in FLAGS:
            with self.assertRaises(RuntimeError):
                PrivateRotationExit().observe_private(0, DATA[0], 'a', **(FLAGS | {flag: True}))
        with self.assertRaisesRegex(RuntimeError, 'reappeared'):
            complete().observe_private(24, DATA[0], '0', **FLAGS)

    def test_address_reuse_extra_rotation_and_report_bound(self):
        sequence = PrivateRotationExit()
        sequence.observe_private(0, DATA[0], 'a', **FLAGS)
        with self.assertRaisesRegex(RuntimeError, 'additional'):
            sequence.observe_private(1, DATA[0], 'b', **FLAGS)
        with self.assertRaisesRegex(RuntimeError, 'reappeared'):
            sequence.observe_private(1, DATA[1], 'a', **FLAGS)
        sequence = PrivateRotationExit()
        for sample in range(512):
            sequence.observe_private(sample / 100, DATA[0], 'a', **FLAGS)
        with self.assertRaisesRegex(RuntimeError, 'bound'):
            sequence.observe_private(6, DATA[0], 'a', **FLAGS)

    def test_board_failure_missing_counts_order_and_duplicates(self):
        text = board()
        for bad in (text.replace('enables=2', 'enables=1'),
                    text.replace('HELD stage=1', 'HELD stage=4'),
                    text + '\nPRIVATE_ROTATION_EXIT ACTIVE stage=0',
                    text + '\nEXCEPTION', text + '\nUNEXPECTED_FINALLY',
                    '\n'.join(reversed(text.splitlines()))):
            with self.assertRaises(RuntimeError):
                validate_rotation_board(bad)

    def test_identity_filter(self):
        peer = hci.Address('98:CD:AC:60:E0:AE', hci.Address.PUBLIC_DEVICE_ADDRESS)
        other = hci.Address('98:CD:AC:60:E0:AF', hci.Address.PUBLIC_DEVICE_ADDRESS)
        resolver = smp.AddressResolver([(TEST_IRK[::-1], peer)])
        private = hci.Address.generate_private_address(TEST_IRK[::-1])
        self.assertTrue(select_rotation(SimpleNamespace(address=private, data_bytes=DATA[0]), peer, resolver))
        self.assertFalse(select_rotation(SimpleNamespace(address=other, data_bytes=b'other'), peer, resolver))
        for address in (peer, other, hci.Address.generate_private_address(bytes(16))):
            with self.assertRaisesRegex(RuntimeError, 'resolve'):
                select_rotation(SimpleNamespace(address=address, data_bytes=DATA[0]), peer, resolver)


if __name__ == '__main__':
    unittest.main()
