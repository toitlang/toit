# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Independent observation of held-reply accept cancellation and later recovery."""

import re
import sys
from connectable_updates import exercise as observe_and_connect

NAME = 'accept-update-cancel'
READY = 'ACCEPT_CANCEL ADVERTISING stage=0'


def data(stage, phase):
    return bytes([2, 1, 6, 27, 0xff, 0xff, 0xff]) + b'acc' + bytes([stage, phase]) + bytes([0x30 + phase]) * 19


def response(stage, phase):
    return bytes([30, 9]) + b'acc' + bytes([ord('0') + stage, ord('0') + phase]) + bytes([0x41 + phase]) * 24


DATA = tuple(data(stage, phase) for stage, phase in ((0, 0), (0, 1), (1, 0), (1, 1), (2, 0)))
RESPONSE = tuple(response(stage, phase) for stage, phase in ((0, 0), (1, 0), (1, 1), (2, 0)))


class Sequence:
    def __init__(self):
        self.highest = [-1, -1]
        self.count = [[0] * 5, [0] * 4]
        self.first = [[None] * 5, [None] * 4]
        self.last = [[None] * 5, [None] * 4]

    def observe(self, now, payload, *, connectable, scannable, scan_response):
        stream = int(scan_response)
        if not scan_response and not (connectable and scannable):
            raise RuntimeError('Expected connectable scannable cancellation fixture')
        values = RESPONSE if scan_response else DATA
        if payload not in values:
            raise RuntimeError('Unexpected payload or command after cancellation')
        phase = values.index(payload)
        if not self.highest[stream] <= phase <= self.highest[stream] + 1:
            raise RuntimeError('Missing or regressing cancellation phase')
        self.highest[stream] = phase
        if self.count[stream][phase] == 0:
            self.first[stream][phase] = now
        self.last[stream][phase] = now
        self.count[stream][phase] += 1

    def ready(self):
        for stream, values in enumerate((DATA, RESPONSE)):
            for phase in range(len(values)):
                held = phase in ((1, 3) if stream == 0 else (2,))
                count, seconds = (5, 0.8) if held else (10, 1.5)
                if self.count[stream][phase] < count or self.last[stream][phase] - self.first[stream][phase] < seconds:
                    return False
        return True

    def finish(self):
        if not self.ready():
            raise RuntimeError('Insufficient repeated cancellation phases')
        gaps = [[self.first[s][p] - self.last[s][p - 1] for p in range(1, len(self.count[s]))]
                for s in range(2)]
        for stream, row in enumerate(gaps):
            for index, gap in enumerate(row):
                restart = index in ((1, 3) if stream == 0 else (0, 2))
                if (restart and gap < 2) or (not restart and gap > 2):
                    raise RuntimeError('Missing cessation or interrupted live update')
        return {'reports': [row.copy() for row in self.count], 'gaps_seconds': gaps, 'cancelled_accepts': 2}


def validate_board(text):
    markers = []
    for stage in range(2):
        markers += [f'ACCEPT_CANCEL ADVERTISING stage={stage}',
                    f'ACCEPT_CANCEL HELD stage={stage} opcode={0x2008 + stage} status=0',
                    f'ACCEPT_CANCEL STOPPED stage={stage} closes=1 enables=1 disables=0 data=2 response={stage + 1}']
    markers += ['ACCEPT_CANCEL RECOVERY',
                'ACCEPT_CANCEL RECOVERED reads=20 closes=1 enables=1 disables=1 data=1 response=1']
    positions = [text.find(marker) for marker in markers]
    if any(text.splitlines().count(marker) != 1 for marker in markers) or positions != sorted(positions):
        raise RuntimeError('Missing ordered cancellation, command-count or recovery verdict')
    complete = re.findall(r'^ACCEPT_CANCEL COMPLETE stages=2 recovery-reads=20 retained=4 full-gcs=(\d+)$', text, re.M)
    if len(complete) != 1 or int(complete[0]) < 24:
        raise RuntimeError('Missing recovery or retained GC verdict')
    if any(error in text for error in ('EXCEPTION', 'Controller disable failed', 'Controller deinit failed')):
        raise RuntimeError('Board failed')
    return int(complete[0])


async def exercise(args, device, board_marker, board_text, emit):
    return await observe_and_connect(args, device, board_marker, board_text, emit, scenario=sys.modules[__name__])
