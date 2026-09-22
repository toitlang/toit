# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Live extended-command updates with a concurrent outgoing radio connection."""

import re
import sys
from connectable_updates import Sequence, exercise as observe_and_connect

NAME = 'mixed-connectable-updates'
READY = 'CONNECTABLE_UPDATE ADVERTISING'
WRITES = 100
READS = 0


def unique(text, pattern):
    matches = list(re.finditer('^' + pattern + '$', text, re.M))
    if len(matches) != 1:
        raise RuntimeError('Missing unique mixed update verdict')
    return matches[0]


def validate_board(text):
    batches = [unique(text, rf'MIXED_UPDATE_CENTRAL BATCH index={index} reads=100 retained=4 full-gcs=(\d+)')
               for index in range(6)]
    phases = [unique(text, rf'CONNECTABLE_UPDATE APPLIED phase={index} gc=true') for index in range(4)]
    for index, batch in enumerate(batches):
        if int(batch[1]) < 10:
            raise RuntimeError('Missing survivor GC')
        if index > 0 and batches[index - 1].start() >= batch.start():
            raise RuntimeError('Out-of-order survivor batches')
    for phase in range(4):
        if not batches[phase].start() < phases[phase].start() < batches[phase + 1].start():
            raise RuntimeError('Read batch did not span the selected update phase')
    central = unique(text, r'MIXED_UPDATE_CENTRAL COMPLETE reads=600 batches=6 full-gcs=(\d+)')
    cleanup = unique(text, r'MIXED_UPDATE CLEANUP peripheral-released=true survivor-open=true')
    app = unique(text, r'CONNECTABLE_UPDATE_APP COMPLETE writes=100 retained=4 full-gcs=(\d+)')
    provider = unique(text, r'MIXED_UPDATE_PROVIDER COMPLETE opens=1 closes=1 data=4 response=4 parameters=1 removes=1 disables=0 enables=(\d+) terminations=(\d+) phase-reads=100,100,100,100,100,100 full-gcs=(\d+)')
    supervisor = unique(text, r'MIXED_UPDATE_SUPERVISOR COMPLETE child-groups=2 exits=0')
    if int(central[1]) < 60 or int(app[1]) < 104 or int(provider[3]) < 20:
        raise RuntimeError('Missing mixed process GC')
    if int(provider[1]) != int(provider[2]) or int(provider[1]) < 3:
        raise RuntimeError('Unbalanced finite windows')
    if not batches[-1].start() < central.start() < provider.start() < supervisor.start() or app.start() >= provider.start():
        raise RuntimeError('Missing ordered survivor and provider completion')
    if not batches[4].start() < cleanup.start() < batches[5].start():
        raise RuntimeError('Missing reads after peripheral cleanup')
    if any(error in text for error in ('EXCEPTION', 'Controller disable failed', 'Controller deinit failed')):
        raise RuntimeError('Mixed owner failed')
    return int(app[1])


def validate_peer(text):
    match = unique(text, r'MIXED_UPDATE_PEER COMPLETE reads=600 retained=4 full-gcs=(\d+)')
    if int(match[1]) < 60 or 'EXCEPTION' in text:
        raise RuntimeError('Survivor peer failed')


async def exercise(args, device, board_marker, board_text, emit):
    return await observe_and_connect(args, device, board_marker, board_text, emit, scenario=sys.modules[__name__])
