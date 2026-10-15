# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Pending-update client death on a shared controller with a surviving link."""

import sys
from accept_update_cancel import Sequence as CancelSequence
from connectable_updates import exercise as observe_and_connect
from mixed_connectable_updates import unique, validate_peer

NAME = 'mixed-update-exit'
READY = 'MIXED_EXIT ADVERTISING stage=0'
SCAN_SECONDS = 80


class Sequence(CancelSequence):
    def ready(self):
        # Held replies block renewal of a one-second controller window.
        # Require repeated observations within that window, not a legacy
        # indefinitely enabled advertising lifetime.
        for stream, row in enumerate(self.count):
            for phase, count in enumerate(row):
                held = phase in ((1, 3) if stream == 0 else (2,))
                minimum, seconds = (3, 0.3) if held else (10, 1.5)
                if count < minimum or self.last[stream][phase] - self.first[stream][phase] < seconds:
                    return False
        return True

    def finish(self):
        result = super().finish()
        result['terminated_clients'] = result.pop('cancelled_accepts')
        return result


def validate_board(text):
    ordered = []
    total_gcs = 0

    def batch(index):
        match = unique(text, rf'MIXED_UPDATE_CENTRAL BATCH index={index} reads=100 retained=4 full-gcs=(\d+)')
        if int(match[1]) < 10:
            raise RuntimeError('Missing survivor GC')
        ordered.append(match.start())

    batch(0)
    for stage in range(2):
        ordered.append(unique(text, rf'MIXED_EXIT ADVERTISING stage={stage}').start())
        batch(stage * 2 + 1)
        ordered.append(unique(text, rf'MIXED_EXIT HELD stage={stage} opcode={0x2037 + stage} status=0').start())
        exited = unique(text, rf'MIXED_EXIT EXIT stage={stage} pending=true full-gcs=(\d+)')
        if int(exited[1]) < 2:
            raise RuntimeError('Missing exiting-client GC')
        total_gcs += int(exited[1])
        ordered.append(exited.start())
        ordered.append(unique(text, rf'MIXED_EXIT CLEANUP stage={stage} pending-at-death=true closes=0 data={(stage+1)*2} response={stage*2+1} removes={stage+1}').start())
        batch(stage * 2 + 2)
    ordered.append(unique(text, r'MIXED_EXIT ADVERTISING stage=2').start())
    recovered = unique(text, r'MIXED_EXIT RECOVERED reads=20 retained=4 full-gcs=(\d+)')
    if int(recovered[1]) < 21:
        raise RuntimeError('Missing recovery GC')
    total_gcs += int(recovered[1])
    ordered.append(recovered.start())
    ordered.append(unique(text, r'MIXED_EXIT CLEANUP stage=2 pending-at-death=false closes=0 data=5 response=4 removes=3').start())
    batch(5)
    central = unique(text, r'MIXED_EXIT_CENTRAL COMPLETE reads=600 batches=6 full-gcs=(\d+)')
    provider = unique(text, r'MIXED_EXIT_PROVIDER COMPLETE opens=1 closes=1 data=5 response=4 parameters=3 removes=3 disables=0 enables=(\d+) terminations=(\d+) phase-reads=100,100,100,100,100,100 full-gcs=(\d+)')
    if int(central[1]) < 60 or int(provider[3]) < 20:
        raise RuntimeError('Missing central/provider GC')
    if int(provider[1]) != int(provider[2]) or int(provider[1]) < 5:
        raise RuntimeError('Unbalanced advertising windows')
    ordered += [central.start(), provider.start(), unique(text, r'MIXED_EXIT_SUPERVISOR COMPLETE child-groups=4 exits=0').start()]
    if ordered != sorted(ordered):
        raise RuntimeError('Incorrect process-exit and survivor ordering')
    if any(error in text for error in ('EXCEPTION', 'UNEXPECTED', 'Controller disable failed', 'Controller deinit failed')):
        raise RuntimeError('Mixed-exit board failed')
    return total_gcs


async def exercise(args, device, board_marker, board_text, emit):
    return await observe_and_connect(args, device, board_marker, board_text, emit, scenario=sys.modules[__name__])
