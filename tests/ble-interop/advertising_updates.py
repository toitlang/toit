# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Bounded independent verdict for live advertising payload updates."""

import re

DATA = tuple(tuple((bytes([2, 1, 6, 27, 0xff, 0xff, 0xff]) + b'upd' +
                    bytes([mode, phase]) + bytes([0x30 + phase]) * 19)
                   if phase < 3 else b'' for phase in range(4)) for mode in range(2))
RESPONSE = tuple(bytes([30, 9, ord('1'), ord('0') + phase]) + bytes([0x41 + phase]) * 27
                 if phase < 3 else b'' for phase in range(4))


class UpdateSequence:
    def __init__(self, *, pending_exit=False):
        self.pending_exit = pending_exit
        self.highest = [-1] * 3
        self.count = [[0] * 4 for _ in range(3)]
        self.first = [[None] * 4 for _ in range(3)]
        self.last = [[None] * 4 for _ in range(3)]

    def observe(self, now, payload, *, connectable, scannable, scan_response):
        if connectable:
            raise RuntimeError('Unexpected connectable report')
        stream = 2 if scan_response else int(scannable)
        expected = RESPONSE if scan_response else DATA[stream]
        if payload not in expected:
            raise RuntimeError('Updated advertising bytes changed')
        phase = expected.index(payload)
        if phase < self.highest[stream] or phase > self.highest[stream] + 1:
            raise RuntimeError('Missing or regressing advertising update')
        if stream == 0 and self.highest[1] >= 0:
            raise RuntimeError('Stopped advertising mode reappeared')
        self.highest[stream] = phase
        if not self.count[stream][phase]:
            self.first[stream][phase] = now
        self.last[stream][phase] = now
        self.count[stream][phase] += 1

    def finish(self, now):
        for stream in range(3):
            for phase in range(4):
                minimum_seconds = 1 if self.pending_exit and phase == 3 else 2
                if (self.count[stream][phase] < 10 or
                        self.last[stream][phase] - self.first[stream][phase] < minimum_seconds):
                    raise RuntimeError('Insufficient repeated update reports')
                if phase and self.first[stream][phase] - self.last[stream][phase - 1] > 2:
                    raise RuntimeError('Advertising update interrupted repetition')
            if now - self.last[stream][-1] < 5:
                raise RuntimeError('Updated advertising did not cease')
        gap = self.first[1][0] - self.last[0][-1]
        if gap < 2:
            raise RuntimeError('Missing mode stop/restart gap')
        return {'reports': self.count, 'mode_gap_seconds': gap,
                'quiet_seconds': [now - row[-1] for row in self.last], 'updates': 6,
                'pending_exit_updates': 2 if self.pending_exit else 0}


def validate_board(text, *, private=False):
    markers = []
    for mode in range(2):
        markers.extend(f'ADVERTISING_UPDATE APPLIED mode={mode} phase={phase} gc=true'
                       for phase in range(4))
        markers.append(f'ADVERTISING_UPDATE STOPPED mode={mode}')
    markers.append('ADVERTISING_UPDATE COMPLETE')
    positions = [text.find(marker) for marker in markers]
    counts = 'ADVERTISING_UPDATE_PROVIDER COMPLETE opens=2 closes=2 enables=2 disables=2 data=8 response=8'
    if private:
        matches = re.findall(r'^ADVERTISING_UPDATE_PRIVATE_PROVIDER COMPLETE opens=2 closes=2 '
                             r'addresses=(\d+) enables=(\d+) disables=(\d+) data=8 response=8$',
                             text, re.MULTILINE)
        valid_counts = False
        if len(matches) == 1:
            addresses, enables, disables = map(int, matches[0])
            valid_counts = (6 <= enables <= addresses <= enables + 2 and enables == disables)
    else:
        valid_counts = text.count(counts) == 1
    if (any(text.count(marker) != 1 for marker in markers) or positions != sorted(positions) or
            not valid_counts):
        raise RuntimeError('Missing ordered updates, GC or controller lifetime verdict')


def validate_exit_board(text):
    markers = []
    for mode in range(2):
        markers.extend(f'ADVERTISING_UPDATE APPLIED mode={mode} phase={phase} gc=true'
                       for phase in range(3))
        markers.extend([f'ADVERTISING_UPDATE HELD mode={mode} opcode=8201 status=0',
                        f'ADVERTISING_UPDATE PENDING mode={mode} phase=3 gc=true',
                        f'ADVERTISING_UPDATE EXIT mode={mode} pending=true'])
    markers.append('ADVERTISING_UPDATE_EXIT_PROVIDER COMPLETE opens=2 closes=2 enables=2 disables=0 data=8 response=8')
    positions = [text.find(marker) for marker in markers]
    if (any(text.count(marker) != 1 for marker in markers) or positions != sorted(positions) or
            'UNEXPECTED_' in text or 'ADVERTISING_UPDATE STOPPED' in text or
            'ADVERTISING_UPDATE COMPLETE' in text):
        raise RuntimeError('Missing pending-update process-exit or cleanup verdict')
