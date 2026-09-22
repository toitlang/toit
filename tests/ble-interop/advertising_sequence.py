# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Bounded verdict for service-advertising-fixture's two radio phases."""

DATA = tuple(bytes([2, 1, 6, 10, 0xff, 0xff, 0xff]) + b'toitad' + bytes([mode])
             for mode in (0, 1))
RESPONSE = bytes([8, 9]) + b'ToitAdv'


def board_session(text):
    # Serial drivers can deliver buffered output from before the monitor reset.
    # Preserve it in the raw artifact, but require one fresh runtime boot.
    marker = '[toit] INFO: starting '
    count = text.count(marker)
    if count == 0:
        return ''
    if count != 1:
        raise RuntimeError('Unexpected additional board boot')
    return text[text.index(marker):]


class Sequence:
    def __init__(self):
        self.count = [0, 0, 0]
        self.first = [None, None, None]
        self.last = [None, None, None]

    def observe(self, now, payload, *, connectable, scannable, scan_response):
        if connectable:
            raise RuntimeError('Unexpected connectable report')
        if scan_response:
            if payload != RESPONSE or not self.count[1]:
                raise RuntimeError('Unexpected scan response')
            mode = 2
        else:
            if payload not in DATA:
                raise RuntimeError('Advertising bytes changed')
            mode = DATA.index(payload)
            if scannable != bool(mode):
                raise RuntimeError('Wrong advertising mode')
            if mode == 0 and self.count[1]:
                raise RuntimeError('First advertising phase reappeared')
        if self.count[mode] == 0:
            self.first[mode] = now
        self.last[mode] = now
        self.count[mode] += 1

    def finish(self, now):
        for mode in range(3):
            if self.count[mode] < 20 or self.last[mode] - self.first[mode] < 5:
                raise RuntimeError('Insufficient repeated reports or duration')
            if now - self.last[mode] < 5:
                raise RuntimeError('Advertising did not cease')
        gap = self.first[1] - self.last[0]
        if gap < 2:
            raise RuntimeError('Missing advertising stop gap')
        return {'reports': self.count, 'stop_gap_seconds': gap,
                'spans_seconds': [end - start for start, end in zip(self.first, self.last)],
                'quiet_seconds': [now - end for end in self.last]}
