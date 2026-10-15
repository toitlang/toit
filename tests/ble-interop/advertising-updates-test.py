# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

import unittest
from advertising_updates import DATA, RESPONSE, UpdateSequence, validate_board, validate_exit_board


def feed(sequence):
    for mode in range(2):
        for phase in range(4):
            for sample in range(20):
                now = mode * 24 + phase * 5 + sample * 0.2
                sequence.observe(now, DATA[mode][phase], connectable=False,
                                 scannable=bool(mode), scan_response=False)
                if mode:
                    sequence.observe(now + 0.01, RESPONSE[phase], connectable=False,
                                     scannable=True, scan_response=True)


class UpdateTest(unittest.TestCase):
    def test_complete_sequence(self):
        sequence = UpdateSequence()
        feed(sequence)
        self.assertEqual(sequence.finish(55)['reports'], [[20] * 4] * 3)

    def test_missing_wrong_regressing_and_connectable(self):
        for payload, connectable in ((DATA[0][1], False), (b'wrong', False), (DATA[0][0], True)):
            with self.assertRaises(RuntimeError):
                UpdateSequence().observe(0, payload, connectable=connectable, scannable=False, scan_response=False)
        sequence = UpdateSequence()
        feed(sequence)
        with self.assertRaises(RuntimeError):
            sequence.observe(53, DATA[1][0], connectable=False, scannable=True, scan_response=False)

    def test_counts_continuity_and_cessation(self):
        for failure in ('count', 'gap', 'quiet'):
            sequence = UpdateSequence()
            feed(sequence)
            if failure == 'count': sequence.count[2][3] = 9
            if failure == 'gap': sequence.last[0][1] -= 2
            with self.assertRaises(RuntimeError):
                sequence.finish(44 if failure == 'quiet' else 55)

    def test_board_requires_updates_gc_and_single_lifetimes(self):
        lines = []
        for mode in range(2):
            lines.extend(f'ADVERTISING_UPDATE APPLIED mode={mode} phase={phase} gc=true' for phase in range(4))
            lines.append(f'ADVERTISING_UPDATE STOPPED mode={mode}')
        lines += ['ADVERTISING_UPDATE COMPLETE',
                  'ADVERTISING_UPDATE_PROVIDER COMPLETE opens=2 closes=2 enables=2 disables=2 data=8 response=8']
        text = '\n'.join(lines)
        validate_board(text)
        for bad in (text.replace('phase=1', 'phase=2'), text.replace('gc=true', 'gc=false'),
                    text.replace('enables=2', 'enables=8'), text + '\n' + lines[-1]):
            with self.assertRaises(RuntimeError): validate_board(bad)

    def test_pending_exit_uses_only_a_shorter_final_phase(self):
        sequence = UpdateSequence(pending_exit=True)
        feed(sequence)
        for stream in range(3):
            sequence.last[stream][3] = sequence.first[stream][3] + 1.2
        self.assertEqual(sequence.finish(55)['pending_exit_updates'], 2)
        sequence.pending_exit = False
        with self.assertRaises(RuntimeError): sequence.finish(55)
        sequence.pending_exit = True
        sequence.last[1][2] = sequence.first[1][2] + 1.2
        with self.assertRaises(RuntimeError): sequence.finish(55)

    def test_pending_exit_requires_both_deaths_and_held_successful_replies(self):
        lines = []
        for mode in range(2):
            lines.extend(f'ADVERTISING_UPDATE APPLIED mode={mode} phase={phase} gc=true' for phase in range(3))
            lines.extend([f'ADVERTISING_UPDATE HELD mode={mode} opcode=8201 status=0',
                          f'ADVERTISING_UPDATE PENDING mode={mode} phase=3 gc=true',
                          f'ADVERTISING_UPDATE EXIT mode={mode} pending=true'])
        lines.append('ADVERTISING_UPDATE_EXIT_PROVIDER COMPLETE opens=2 closes=2 enables=2 disables=0 data=8 response=8')
        text = '\n'.join(lines)
        validate_exit_board(text)
        for bad in (text.replace('status=0', 'status=12'), text.replace('pending=true', 'pending=false'),
                    text.replace('disables=0', 'disables=2'), text + '\n' + lines[4],
                    text + '\nADVERTISING_UPDATE_EXIT_UNEXPECTED_FINALLY',
                    text + '\nADVERTISING_UPDATE STOPPED mode=0'):
            with self.assertRaises(RuntimeError): validate_exit_board(bad)


if __name__ == '__main__':
    unittest.main()
