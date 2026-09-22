# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Client-process death during held live-update replies, with provider reuse."""

import re
import sys
from accept_update_cancel import Sequence as CancelSequence
from connectable_updates import exercise as observe_and_connect

NAME = 'accept-update-exit'
READY = 'ACCEPT_EXIT ADVERTISING stage=0'


class Sequence(CancelSequence):
    def finish(self):
        verdict = super().finish()
        verdict['terminated_clients'] = verdict.pop('cancelled_accepts')
        return verdict


def validate_board(text):
    patterns = []
    for stage in range(2):
        patterns += [rf'ACCEPT_EXIT ADVERTISING stage={stage}',
                     rf'ACCEPT_CANCEL HELD stage={stage} opcode={0x2008 + stage} status=0',
                     rf'ACCEPT_EXIT EXIT stage={stage} pending=true full-gcs=(\d+)',
                     rf'ACCEPT_EXIT STOPPED stage={stage} closes=1 enables=1 disables=0 data=2 response={stage + 1}']
    patterns += [r'ACCEPT_EXIT ADVERTISING stage=2',
                 r'ACCEPT_EXIT RECOVERED reads=20 retained=4 full-gcs=(\d+)',
                 r'ACCEPT_EXIT STOPPED stage=2 closes=1 enables=1 disables=1 data=1 response=1',
                 r'ACCEPT_EXIT_PROVIDER COMPLETE opens=3 closes=3 interrupted=2 recovered=1',
                 r'ACCEPT_EXIT_SUPERVISOR COMPLETE groups=4 exits=0']
    positions, gcs = [], []
    for pattern in patterns:
        matches = list(re.finditer('^' + pattern + '$', text, re.M))
        if len(matches) != 1:
            raise RuntimeError('Missing unique process-exit, cleanup or recovery verdict')
        match = matches[0]
        positions.append(match.start())
        if match.groups():
            gcs.append(int(match[1]))
    if positions != sorted(positions) or len(gcs) != 3 or min(gcs[:2]) < 2 or gcs[2] < 21:
        raise RuntimeError('Incorrect exit/reuse order or missing full GC')
    if any(error in text for error in ('EXCEPTION', 'UNEXPECTED', 'Controller disable failed', 'Controller deinit failed')):
        raise RuntimeError('Board or client failed')
    return sum(gcs)


async def exercise(args, device, board_marker, board_text, emit):
    return await observe_and_connect(args, device, board_marker, board_text, emit, scenario=sys.modules[__name__])
