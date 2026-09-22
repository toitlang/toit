# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Offline negative controls for the optional advertising radio verdict."""

import unittest
from advertising_sequence import DATA, RESPONSE, Sequence, board_session


def report(sequence, now, mode, payload=None):
    sequence.observe(now, (RESPONSE if mode == 2 else DATA[mode]) if payload is None else payload,
                     connectable=False, scannable=mode != 0, scan_response=mode == 2)


def complete(gap=3):
    sequence = Sequence()
    for i in range(21):
        report(sequence, i / 2, 0)
    for i in range(21):
        report(sequence, 10 + gap + i / 2, 1)
        report(sequence, 10 + gap + i / 2 + 0.01, 2)
    return sequence


class VerdictTest(unittest.TestCase):
    def test_buffered_previous_boot(self):
        stale = 'ADVERTISING_APP COMPLETE\nentering deep sleep without wakeup time\n'
        fresh = '[toit] INFO: starting <fixture>\nADVERTISING_APP READY mode=0\n'
        self.assertEqual(board_session(stale), '')
        self.assertEqual(board_session(stale + fresh), fresh)
        with self.assertRaisesRegex(RuntimeError, 'additional board boot'):
            board_session(stale + fresh + fresh)

    def test_complete(self):
        self.assertEqual(complete().finish(30)['reports'], [21, 21, 21])

    def test_deduplicated(self):
        sequence = Sequence()
        for mode, now in enumerate((0, 10, 11)):
            report(sequence, now, mode)
        with self.assertRaisesRegex(RuntimeError, 'Insufficient'):
            sequence.finish(30)

    def test_gap_and_cessation(self):
        with self.assertRaisesRegex(RuntimeError, 'stop gap'):
            complete(gap=1).finish(30)
        with self.assertRaisesRegex(RuntimeError, 'cease'):
            complete().finish(27)

    def test_mutation_reordering_and_flags(self):
        for payload in (bytes(14), DATA[0] + b'\x00'):
            with self.assertRaisesRegex(RuntimeError, 'bytes changed'):
                report(Sequence(), 0, 0, payload)
        with self.assertRaisesRegex(RuntimeError, 'reappeared'):
            report(complete(), 25, 0)
        with self.assertRaisesRegex(RuntimeError, 'scan response'):
            report(Sequence(), 0, 2)
        for connectable, scannable in ((True, False), (False, True)):
            with self.assertRaises(RuntimeError):
                Sequence().observe(0, DATA[0], connectable=connectable,
                                   scannable=scannable, scan_response=False)


if __name__ == '__main__':
    unittest.main()
