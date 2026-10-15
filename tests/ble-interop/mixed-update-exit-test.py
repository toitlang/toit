# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

import unittest
from accept_update_cancel import data, response
from mixed_update_exit import Sequence, validate_board


def fixture():
    def batch(index):
        return f'MIXED_UPDATE_CENTRAL BATCH index={index} reads=100 retained=4 full-gcs=10'
    lines = [batch(0)]
    for stage in range(2):
        lines += [f'MIXED_EXIT ADVERTISING stage={stage}', batch(stage * 2 + 1),
                  f'MIXED_EXIT HELD stage={stage} opcode={0x2037 + stage} status=0',
                  f'MIXED_EXIT EXIT stage={stage} pending=true full-gcs=2',
                  f'MIXED_EXIT CLEANUP stage={stage} pending-at-death=true closes=0 data={(stage+1)*2} response={stage*2+1} removes={stage+1}',
                  batch(stage * 2 + 2)]
    lines += ['MIXED_EXIT ADVERTISING stage=2',
              'MIXED_EXIT RECOVERED reads=20 retained=4 full-gcs=21',
              'MIXED_EXIT CLEANUP stage=2 pending-at-death=false closes=0 data=5 response=4 removes=3', batch(5),
              'MIXED_EXIT_CENTRAL COMPLETE reads=600 batches=6 full-gcs=60',
              'MIXED_EXIT_PROVIDER COMPLETE opens=1 closes=1 data=5 response=4 parameters=3 removes=3 disables=0 enables=30 terminations=30 phase-reads=100,100,100,100,100,100 full-gcs=30',
              'MIXED_EXIT_SUPERVISOR COMPLETE child-groups=4 exits=0']
    return '\n'.join(lines)


class MixedExitTest(unittest.TestCase):
    def test_board_and_negative_controls(self):
        text = fixture()
        self.assertEqual(validate_board(text), 25)
        for before, after in [('pending-at-death=true', 'pending-at-death=false'),
                              ('closes=0', 'closes=1'), ('response=1', 'response=2'),
                              ('phase-reads=100', 'phase-reads=99'), ('removes=3', 'removes=2'),
                              ('terminations=30', 'terminations=29'), ('full-gcs=21', 'full-gcs=20'),
                              ('full-gcs=10', 'full-gcs=9'), ('exits=0', 'exits=1')]:
            with self.subTest(before=before), self.assertRaises(RuntimeError):
                validate_board(text.replace(before, after))
        lines = text.splitlines()
        swapped = lines.copy()
        swapped[4], swapped[5] = swapped[5], swapped[4]
        for bad in ('\n'.join(lines[1:]), '\n'.join(swapped), text+'\n'+lines[-1], text+'\nUNEXPECTED_FINALLY'):
            with self.assertRaises(RuntimeError): validate_board(bad)

    def test_finite_window_repetition_and_stop(self):
        sequence = Sequence()
        for stage in range(3):
            for sample in range(20):
                now = stage * 12 + sample * 0.1
                sequence.observe(now, data(stage, 0), connectable=True, scannable=True, scan_response=False)
                sequence.observe(now, response(stage, 0), connectable=False, scannable=False, scan_response=True)
            if stage < 2:
                for sample in range(5):
                    now = stage * 12 + 2 + sample * 0.1
                    sequence.observe(now, data(stage, 1), connectable=True, scannable=True, scan_response=False)
                    sequence.observe(now, response(stage, int(stage == 1)), connectable=False, scannable=False, scan_response=True)
        self.assertEqual(sequence.finish()['terminated_clients'], 2)
        with self.assertRaises(RuntimeError):
            sequence.observe(40, response(0, 1), connectable=False, scannable=False, scan_response=True)
        sequence.last[0][1] = sequence.first[0][1] + 0.2
        with self.assertRaises(RuntimeError): sequence.finish()


if __name__ == '__main__':
    unittest.main()
