# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest

from accept_update_cancel import data, response
from mixed_update_win import Sequence, before_recovery, check_pending, validate_board

spec = importlib.util.spec_from_file_location('exit_test', Path(__file__).with_name('mixed-update-exit-test.py'))
exit_test = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exit_test)


def fixture():
    text = exit_test.fixture()
    for stage in range(2):
        text = text.replace(f'MIXED_EXIT CLEANUP stage={stage} ',
                            'MIXED_EXIT CONNECTION status=0 role=1 handle=2\n'
                            'MIXED_EXIT DISCONNECTION status=0 handle=2 reason=22\n'
                            f'MIXED_EXIT CLEANUP stage={stage} ')
    return text.replace('MIXED_EXIT RECOVERED ',
                        'MIXED_EXIT CONNECTION status=0 role=1 handle=2\nMIXED_EXIT RECOVERED ')


class WinnerTest(unittest.TestCase):
    def test_board_rejects_missing_or_wrong_cleanup(self):
        text = fixture()
        self.assertEqual(validate_board(text), 25)
        for bad in (exit_test.fixture(), text.replace('reason=22', 'reason=19'),
                    text.replace('DISCONNECTION status=0 handle=2', 'DISCONNECTION status=0 handle=3'),
                    text.replace('role=1', 'role=0'),
                    text + '\nMIXED_EXIT CONNECTION status=0 role=1 handle=3'):
            with self.assertRaises(RuntimeError):
                validate_board(bad)

    def test_pending_witness(self):
        check_pending('MIXED_EXIT HELD stage=0 opcode=8247 status=0', 0)
        for bad in ('', 'MIXED_EXIT HELD stage=1 ',
                    'MIXED_EXIT HELD stage=0 \nMIXED_EXIT EXIT stage=0 pending=true'):
            with self.assertRaises(RuntimeError):
                check_pending(bad, 0)

    def test_payloads_and_winners_are_both_required(self):
        sequence = Sequence()
        for stage in range(3):
            for sample in range(20):
                now = stage * 12 + sample * 0.1
                sequence.observe(now, data(stage, 0), connectable=True, scannable=True, scan_response=False)
                sequence.observe(now, response(stage, 0), connectable=False, scannable=False, scan_response=True)
            if stage < 2:
                sequence.observe(stage * 12 + 2, data(stage, 1), connectable=True, scannable=True, scan_response=False)
                sequence.observe(stage * 12 + 2, response(stage, int(stage == 1)), connectable=False, scannable=False, scan_response=True)
                self.assertTrue(sequence.can_connect(stage))
        with self.assertRaises(RuntimeError): sequence.finish()
        sequence.winners = [0, 1]
        self.assertEqual(sequence.finish()['winning_connections'], 2)
        sequence.count[1][2] = 0
        with self.assertRaises(RuntimeError): sequence.finish()


class WinnerAsyncTest(unittest.IsolatedAsyncioTestCase):
    async def run_case(self, reason):
        class Link:
            peer_address = 'peer'
            handle = 16
            EVENT_DISCONNECTION = 'disconnection'

            def on(self, event, callback):
                self.callback = callback

        class Device:
            stage = 0
            scans = 0
            callback = None

            def on(self, event, callback): self.callback = callback
            def remove_listener(self, event, callback): self.callback = None
            async def stop_scanning(self, *, legacy):
                assert legacy is False
                self.scans -= 1
            async def start_scanning(self, **kwargs):
                assert kwargs['legacy'] is False and kwargs['scanning_phys'] == (1,)
                self.scans += 1

            async def connect(self, *args, **kwargs):
                link = Link()
                self.callback(link)
                # Deliver the event before connect() returns: late listener
                # registration would hang or miss this cleanup evidence.
                link.callback(reason)
                return link

        device = Device()
        sequence = SimpleNamespace(can_connect=lambda stage: True, winners=[])
        events = []

        async def marker(path, text):
            if 'CLEANUP' in text: device.stage += 1

        await before_recovery(SimpleNamespace(board_log=None), device, 'peer', sequence, [],
                              marker, lambda path: f'MIXED_EXIT HELD stage={device.stage} ',
                              lambda **fields: events.append(fields))
        self.assertEqual(sequence.winners, [0, 1])
        self.assertEqual(device.scans, 0)
        self.assertIsNone(device.callback)
        self.assertEqual([row['event'] for row in events],
                         ['update-winner-connected', 'update-winner-disconnected'] * 2)

    async def test_early_disconnect_is_retained(self):
        await self.run_case(0x13)

    async def test_link_failure_is_not_winner_cleanup(self):
        with self.assertRaisesRegex(RuntimeError, 'not disconnected by cleanup'):
            await self.run_case(0x3e)


if __name__ == '__main__':
    unittest.main()
