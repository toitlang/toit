# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Lost real update reply, pending survivor read failure, and fresh-controller GATT."""

from types import SimpleNamespace

from accept_update_cancel import data, response
from connectable_updates import exercise as observe_and_connect
from mixed_connectable_updates import unique


class Sequence:
    def __init__(self, boundary):
        self.boundary = boundary
        self.values = [(data(boundary, 0), data(boundary, 1), data(2, 0)),
                       ((response(boundary, 0), response(boundary, 1), response(2, 0))
                        if boundary else (response(0, 0), response(2, 0)))]
        self.highest = [-1, -1]
        self.count = [[0] * len(row) for row in self.values]
        self.first = [[None] * len(row) for row in self.values]
        self.last = [[None] * len(row) for row in self.values]

    def observe(self, now, payload, *, connectable, scannable, scan_response):
        stream = int(scan_response)
        if not scan_response and not (connectable and scannable):
            raise RuntimeError('Expected connectable scannable lost-reply fixture')
        if payload not in self.values[stream]:
            raise RuntimeError('Unexpected payload after lost update reply')
        phase = self.values[stream].index(payload)
        if not self.highest[stream] <= phase <= self.highest[stream] + 1:
            raise RuntimeError('Missing or regressing lost-reply phase')
        self.highest[stream] = phase
        if self.count[stream][phase] == 0:
            self.first[stream][phase] = now
        self.last[stream][phase] = now
        self.count[stream][phase] += 1

    def ready(self):
        for stream, row in enumerate(self.count):
            for phase, count in enumerate(row):
                changed = phase == 1 and (stream == 0 or self.boundary == 1)
                minimum, seconds = (3, 0.3) if changed else (10, 1.5)
                if count < minimum or self.last[stream][phase] - self.first[stream][phase] < seconds:
                    return False
        return True

    def finish(self):
        if not self.ready():
            raise RuntimeError('Insufficient lost-reply payload observations')
        gaps = [[self.first[s][p] - self.last[s][p-1] for p in range(1, len(row))]
                for s, row in enumerate(self.count)]
        for row in gaps:
            if row[-1] < 2 or any(gap > 2 for gap in row[:-1]):
                raise RuntimeError('Missing controller-close gap or interrupted live update')
        return {'reports': self.count, 'gaps_seconds': gaps, 'lost_replies': 1,
                'boundary': self.boundary}


def validate_board(text, boundary):
    first = unique(text, r'MIXED_UPDATE_CENTRAL BATCH index=0 reads=100 retained=4 full-gcs=(\d+)')
    advertising = unique(text, rf'MIXED_LOST ADVERTISING boundary={boundary}')
    second = unique(text, r'MIXED_UPDATE_CENTRAL BATCH index=1 reads=100 retained=4 full-gcs=(\d+)')
    dropped = unique(text, rf'MIXED_LOST DROPPED opcode={0x2037+boundary} status=0')
    exited = unique(text, rf'MIXED_LOST EXIT boundary={boundary} pending=true full-gcs=(\d+)')
    failed = unique(text, r'MIXED_LOST_CENTRAL FAILED pending-read=true error=(HCI_CLOSED|HCI_COMMAND_ABORTED|DEADLINE_EXCEEDED|ATT_CLOSED) elapsed-us=(\d+)')
    central = unique(text, r'MIXED_LOST_CENTRAL COMPLETE reads=200 full-gcs=(\d+)')
    closed = unique(text, rf'MIXED_LOST CLOSED boundary={boundary} opens=1 closes=1 pending-at-death=true reads=200 pending-reads=1 data=2 response={boundary+1} removes=0 commands-after-drop=0 elapsed-us=(\d+)')
    recovery = unique(text, r'MIXED_EXIT ADVERTISING stage=2')
    recovered = unique(text, r'MIXED_EXIT RECOVERED reads=20 retained=4 full-gcs=(\d+)')
    provider = unique(text, rf'MIXED_LOST_PROVIDER COMPLETE boundary={boundary} opens=2 closes=2 recovery-data=1 recovery-response=1 recovery-removes=1 recovery-enables=(\d+) recovery-terminations=(\d+) full-gcs=(\d+)')
    supervisor = unique(text, r'MIXED_LOST_SUPERVISOR COMPLETE child-groups=3 exits=0')
    positions = [m.start() for m in (first, advertising, second, dropped, exited, failed,
                                     central, closed, recovery, recovered, provider, supervisor)]
    if positions != sorted(positions):
        raise RuntimeError('Missing ordered lost-reply failure and recovery')
    if not 0 < int(failed[2]) <= 5_000_000 or not 0 < int(closed[1]) <= 5_000_000:
        raise RuntimeError('Lost reply did not terminate within its bound')
    if any(int(m[1]) < 10 for m in (first, second)) or int(central[1]) < 20 or int(exited[1]) < 2 or int(recovered[1]) < 21 or int(provider[3]) < 5:
        raise RuntimeError('Missing lost-reply GC evidence')
    if int(provider[1]) < 1 or provider[1] != provider[2]:
        raise RuntimeError('Recovery advertising windows did not balance')
    if any(marker in text for marker in ('EXCEPTION', 'UNEXPECTED', 'Controller disable failed', 'Controller deinit failed')):
        raise RuntimeError('Lost-reply board failed')
    return int(exited[1]) + int(recovered[1])


def validate_peer(text):
    pending = unique(text, r'MIXED_LOST_PEER PENDING reads=200')
    complete = unique(text, r'MIXED_LOST_PEER COMPLETE reads=200 pending=1 retained=4 full-gcs=(\d+)')
    ended = unique(text, r'CONNECTION_EVENT sequence=\d+ kind=5 status=0 handle=0 detail=(8|19) us=\d+')
    if pending.start() >= complete.start() or int(complete[1]) < 20 or ended.start() <= complete.start() or 'EXCEPTION' in text:
        raise RuntimeError('Missing pending peer read or terminal cleanup')


async def exercise(args, device, board_marker, board_text, emit):
    boundary = int(args.mixed_update_lost == 'response')
    scenario = SimpleNamespace(NAME='mixed-update-lost', READY='MIXED_LOST ADVERTISING',
                               SCAN_SECONDS=65, Sequence=lambda: Sequence(boundary),
                               validate_board=lambda text: validate_board(text, boundary),
                               validate_peer=validate_peer)
    return await observe_and_connect(args, device, board_marker, board_text, emit, scenario=scenario)
