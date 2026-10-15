# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

import unittest
from accept_update_cancel import Sequence, data, response, validate_board


def feed(sequence):
    for stage in range(3):
        for sample in range(30):
            now = stage * 9 + sample * 0.1
            sequence.observe(now, data(stage, 0), connectable=True, scannable=True, scan_response=False)
            sequence.observe(now + 0.01, response(stage, 0), connectable=False, scannable=False, scan_response=True)
        if stage < 2:
            for sample in range(14):
                now = stage * 9 + 4 + sample * 0.1
                sequence.observe(now, data(stage, 1), connectable=True, scannable=True, scan_response=False)
                sequence.observe(now + 0.01, response(stage, int(stage == 1)),
                                 connectable=False, scannable=False, scan_response=True)


class CancelTest(unittest.TestCase):
    def test_complete_and_owned_verdict(self):
        sequence = Sequence()
        feed(sequence)
        verdict = sequence.finish()
        self.assertEqual(verdict['reports'], [[30, 14, 30, 14, 30], [44, 30, 14, 30]])
        sequence.observe(25, data(2, 0), connectable=True, scannable=True, scan_response=False)
        self.assertEqual(verdict['reports'][0][-1], 30)

    def test_reject_command_after_cancellation(self):
        with self.assertRaises(RuntimeError):
            Sequence().observe(0, response(0, 1), connectable=False, scannable=False, scan_response=True)

    def test_missing_corrupt_and_regressing(self):
        for payload in (b'bad', data(0, 1)):
            with self.assertRaises(RuntimeError):
                Sequence().observe(0, payload, connectable=True, scannable=True, scan_response=False)
        sequence = Sequence()
        feed(sequence)
        with self.assertRaises(RuntimeError):
            sequence.observe(30, data(0, 0), connectable=True, scannable=True, scan_response=False)

    def test_require_repetition_and_cessation(self):
        for failure in ('count', 'duration', 'gap'):
            sequence = Sequence()
            feed(sequence)
            if failure == 'count': sequence.count[0][1] = 4
            if failure == 'duration': sequence.last[0][1] = sequence.first[0][1] + 0.5
            if failure == 'gap':
                sequence.first[0][2] -= 3
                sequence.last[0][2] -= 3
            with self.assertRaises(RuntimeError): sequence.finish()

    def test_controller_and_gc_verdict(self):
        lines = []
        for stage in range(2):
            lines += [f'ACCEPT_CANCEL ADVERTISING stage={stage}',
                      f'ACCEPT_CANCEL HELD stage={stage} opcode={0x2008+stage} status=0',
                      f'ACCEPT_CANCEL STOPPED stage={stage} closes=1 enables=1 disables=0 data=2 response={stage+1}']
        lines += ['ACCEPT_CANCEL RECOVERY',
                  'ACCEPT_CANCEL RECOVERED reads=20 closes=1 enables=1 disables=1 data=1 response=1',
                  'ACCEPT_CANCEL COMPLETE stages=2 recovery-reads=20 retained=4 full-gcs=24']
        text = '\n'.join(lines)
        self.assertEqual(validate_board(text), 24)
        for bad in (text.replace('response=1', 'response=2'), text.replace('status=0', 'status=12'),
                    text.replace('reads=20', 'reads=19'), text.replace('full-gcs=24', 'full-gcs=2'),
                    text + '\n' + lines[-1]):
            with self.assertRaises(RuntimeError): validate_board(bad)


if __name__ == '__main__':
    unittest.main()
