# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

import unittest
from connectable_updates import DATA, RESPONSE, Sequence, validate_board


def feed(sequence):
    for phase in range(4):
        for sample in range(30):
            now = phase * 4 + sample * 0.1
            sequence.observe(now, DATA[phase], connectable=True, scannable=True, scan_response=False)
            sequence.observe(now + 0.01, RESPONSE[phase], connectable=False, scannable=False, scan_response=True)


class ConnectableUpdatesTest(unittest.TestCase):
    def test_complete(self):
        sequence = Sequence()
        feed(sequence)
        self.assertEqual(sequence.finish()['reports'], [[30] * 4] * 2)
        verdict = sequence.finish()
        sequence.observe(20, DATA[3], connectable=True, scannable=True, scan_response=False)
        self.assertEqual(verdict['reports'], [[30] * 4] * 2)
        self.assertEqual([len(x) for x in DATA], [31, 31, 31, 0])
        self.assertEqual([len(x) for x in RESPONSE], [31, 31, 31, 0])

    def test_corrupt_missing_or_wrong_mode(self):
        for payload, connectable, scannable in ((b'bad', True, True), (DATA[1], True, True),
                                               (DATA[0], False, True), (DATA[0], True, False)):
            with self.assertRaises(RuntimeError):
                Sequence().observe(0, payload, connectable=connectable, scannable=scannable, scan_response=False)
        sequence = Sequence()
        feed(sequence)
        with self.assertRaises(RuntimeError):
            sequence.observe(20, DATA[0], connectable=True, scannable=True, scan_response=False)

    def test_repetition_duration_and_gaps(self):
        for failure in ('count', 'duration', 'gap'):
            sequence = Sequence()
            feed(sequence)
            if failure == 'count': sequence.count[1][3] = 9
            if failure == 'duration': sequence.last[0][3] = sequence.first[0][3] + 1
            if failure == 'gap':
                sequence.first[0][2] += 1
                sequence.last[0][2] += 1
            with self.assertRaises(RuntimeError): sequence.finish()

    def test_board_counts_gc_and_order(self):
        lines = [f'CONNECTABLE_UPDATE APPLIED phase={p} gc=true' for p in range(4)]
        lines += ['CONNECTABLE_UPDATE_PROVIDER COMPLETE opens=1 closes=1 enables=1 disables=1 data=4 response=4',
                  'CONNECTABLE_UPDATE_SUPERVISOR COMPLETE groups=2 exits=0',
                  'CONNECTABLE_UPDATE_APP COMPLETE writes=100 retained=4 full-gcs=105']
        text = '\n'.join(lines)
        self.assertEqual(validate_board(text), 105)
        for bad in (text.replace('phase=1', 'phase=2'), text.replace('enables=1', 'enables=4'),
                    text.replace('writes=100', 'writes=99'), text.replace('full-gcs=105', 'full-gcs=3'),
                    text + '\n' + lines[-1], text + '\nEXCEPTION'):
            with self.assertRaises(RuntimeError): validate_board(bad)


if __name__ == '__main__':
    unittest.main()
