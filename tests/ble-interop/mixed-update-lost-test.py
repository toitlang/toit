# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

import unittest

from accept_update_cancel import data, response
from mixed_update_lost import Sequence, validate_board, validate_peer


def fixture(boundary):
    return '\n'.join([
        'MIXED_UPDATE_CENTRAL BATCH index=0 reads=100 retained=4 full-gcs=10',
        f'MIXED_LOST ADVERTISING boundary={boundary}',
        'MIXED_UPDATE_CENTRAL BATCH index=1 reads=100 retained=4 full-gcs=10',
        f'MIXED_LOST DROPPED opcode={0x2037+boundary} status=0',
        f'MIXED_LOST EXIT boundary={boundary} pending=true full-gcs=2',
        'MIXED_LOST_CENTRAL FAILED pending-read=true error=HCI_COMMAND_ABORTED elapsed-us=3000000',
        'MIXED_LOST_CENTRAL COMPLETE reads=200 full-gcs=20',
        f'MIXED_LOST CLOSED boundary={boundary} opens=1 closes=1 pending-at-death=true reads=200 pending-reads=1 data=2 response={boundary+1} removes=0 commands-after-drop=0 elapsed-us=3000000',
        'MIXED_EXIT ADVERTISING stage=2',
        'MIXED_EXIT RECOVERED reads=20 retained=4 full-gcs=21',
        f'MIXED_LOST_PROVIDER COMPLETE boundary={boundary} opens=2 closes=2 recovery-data=1 recovery-response=1 recovery-removes=1 recovery-enables=3 recovery-terminations=3 full-gcs=5',
        'MIXED_LOST_SUPERVISOR COMPLETE child-groups=3 exits=0',
    ])


class LostTest(unittest.TestCase):
    def test_fault_and_recovery_oracle(self):
        for boundary in range(2):
            text = fixture(boundary)
            self.assertEqual(validate_board(text, boundary), 23)
            for before, after in [('commands-after-drop=0', 'commands-after-drop=1'),
                                  ('pending-reads=1', 'pending-reads=0'),
                                  ('pending-at-death=true', 'pending-at-death=false'),
                                  ('elapsed-us=3000000', 'elapsed-us=5000001'),
                                  ('error=HCI_COMMAND_ABORTED', 'error=ATT_ERROR'),
                                  ('closes=2', 'closes=1'), ('full-gcs=21', 'full-gcs=20'),
                                  ('recovery-terminations=3', 'recovery-terminations=2')]:
                with self.subTest(boundary=boundary, before=before), self.assertRaises(RuntimeError):
                    validate_board(text.replace(before, after), boundary)
            lines = text.splitlines()
            lines[7], lines[8] = lines[8], lines[7]
            with self.assertRaises(RuntimeError): validate_board('\n'.join(lines), boundary)
            with self.assertRaises(RuntimeError): validate_board(text, 1-boundary)
            with self.assertRaises(RuntimeError): validate_board(text+'\nEXCEPTION', boundary)

    def test_pending_peer_requires_disconnect_and_gc(self):
        text = ('MIXED_LOST_PEER PENDING reads=200\n'
                'MIXED_LOST_PEER COMPLETE reads=200 pending=1 retained=4 full-gcs=20\n'
                'CONNECTION_EVENT sequence=7 kind=5 status=0 handle=0 detail=8 us=3000000')
        validate_peer(text)
        for bad in (text.replace('detail=8', 'detail=62'), text.replace('full-gcs=20', 'full-gcs=19'),
                    text.replace('pending=1', 'pending=0'), text+'\nEXCEPTION'):
            with self.assertRaises(RuntimeError): validate_peer(bad)

    def test_both_payload_boundaries_and_cessation(self):
        for boundary in range(2):
            sequence = Sequence(boundary)
            for stage, phase, start, samples in ((boundary, 0, 0, 20), (boundary, 1, 2, 5), (2, 0, 9, 20)):
                for sample in range(samples):
                    sequence.observe(start+sample*0.1, data(stage, phase), connectable=True, scannable=True, scan_response=False)
                    response_phase = phase if boundary else 0
                    sequence.observe(start+sample*0.1, response(stage, response_phase), connectable=False, scannable=False, scan_response=True)
            self.assertEqual(sequence.finish()['boundary'], boundary)
            sequence.first[0][2] = sequence.last[0][1]+1
            with self.assertRaises(RuntimeError): sequence.finish()


if __name__ == '__main__':
    unittest.main()
